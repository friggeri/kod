import Foundation

public enum GitRepositoryLocatorError: Error, Equatable, Sendable {
    case notARepository(URL)
    case processFailed(exitCode: Int32, message: String)
    case malformedOutput(String)
}

/// Where `HEAD` currently points: a named branch, or a detached commit.
public enum GitHeadState: Equatable, Sendable {
    case branch(name: String)
    case detached(commitID: String)

    public var isDetached: Bool {
        if case .detached = self {
            return true
        }
        return false
    }
}

/// A resolved repository/worktree location plus current `HEAD` state.
/// SPEC 9.1: "Repository root, current branch or detached HEAD, and
/// worktree status."
public struct GitRepositoryLocation: Equatable, Sendable {
    /// The working tree root (`--show-toplevel`) — what a window/finder
    /// folder actually corresponds to.
    public let workingTreeRoot: URL
    /// This worktree's own `.git` entry: a full directory for the main
    /// worktree, or `<common>/worktrees/<name>` for a linked worktree.
    public let gitDirectory: URL
    /// The shared repository directory every linked worktree points
    /// back to. Equal to `gitDirectory` for the main worktree.
    public let commonDirectory: URL
    public let isBareRepository: Bool
    public let head: GitHeadState

    public init(
        workingTreeRoot: URL,
        gitDirectory: URL,
        commonDirectory: URL,
        isBareRepository: Bool,
        head: GitHeadState
    ) {
        self.workingTreeRoot = workingTreeRoot
        self.gitDirectory = gitDirectory
        self.commonDirectory = commonDirectory
        self.isBareRepository = isBareRepository
        self.head = head
    }

    /// `true` when this is a linked worktree (its own `gitDirectory`
    /// differs from the shared `commonDirectory`), as opposed to the
    /// single worktree of a normal (non-worktree) repository.
    public var isLinkedWorktree: Bool {
        gitDirectory != commonDirectory
    }
}

/// Detects a repository/worktree root and its current `HEAD` state using
/// only `git rev-parse` and `git symbolic-ref` — both fully read-only —
/// combining every `rev-parse` query into a single invocation.
public struct GitRepositoryLocator: Sendable {
    private let executableURL: URL
    private let environment: @Sendable (String?) -> [String: String]
    private let runner: GitProcessRunner

    public init(
        executableURL: URL,
        environment: @escaping @Sendable (String?) -> [String: String] = GitInvocationHardening.environment,
        runner: GitProcessRunner = GitProcessRunner()
    ) {
        self.executableURL = executableURL
        self.environment = environment
        self.runner = runner
    }

    /// Locates the repository/worktree containing `path`, or throws
    /// `.notARepository` if `path` is not inside one.
    public func locate(startingAt path: URL) async throws -> GitRepositoryLocation {
        let home = ProcessInfo.processInfo.environment["HOME"]
        let env = environment(home)

        let revParseArguments = GitInvocationHardening.arguments(
            for: .revParse,
            arguments: [
                "--path-format=absolute",
                "--show-toplevel",
                "--absolute-git-dir",
                "--git-common-dir",
                "--is-bare-repository"
            ]
        )
        let revParseInvocation = GitInvocation(
            executableURL: executableURL,
            arguments: revParseArguments,
            currentDirectoryURL: path,
            environment: env,
            timeout: 10
        )
        let revParseResult = try await runner.run(revParseInvocation)
        guard revParseResult.exitCode == 0 else {
            throw GitRepositoryLocatorError.notARepository(path)
        }
        let output = String(decoding: revParseResult.standardOutput, as: UTF8.self)
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count == 4 else {
            throw GitRepositoryLocatorError.malformedOutput(output)
        }
        let workingTreeRoot = URL(fileURLWithPath: lines[0], isDirectory: true)
        let gitDirectory = URL(fileURLWithPath: lines[1], isDirectory: true)
        let commonDirectory = URL(fileURLWithPath: lines[2], isDirectory: true)
        let isBareRepository = lines[3] == "true"

        let head = try await resolveHead(repositoryRoot: workingTreeRoot, environment: env)

        return GitRepositoryLocation(
            workingTreeRoot: workingTreeRoot,
            gitDirectory: gitDirectory,
            commonDirectory: commonDirectory,
            isBareRepository: isBareRepository,
            head: head
        )
    }

    private func resolveHead(repositoryRoot: URL, environment env: [String: String]) async throws -> GitHeadState {
        let symbolicRefArguments = GitInvocationHardening.arguments(
            for: .symbolicRef,
            arguments: ["-q", "--short", "HEAD"]
        )
        let symbolicRefInvocation = GitInvocation(
            executableURL: executableURL,
            arguments: symbolicRefArguments,
            currentDirectoryURL: repositoryRoot,
            environment: env,
            timeout: 10
        )
        let symbolicRefResult = try await runner.run(symbolicRefInvocation)
        if symbolicRefResult.exitCode == 0 {
            let name = String(decoding: symbolicRefResult.standardOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw GitRepositoryLocatorError.malformedOutput("empty symbolic-ref output")
            }
            return .branch(name: name)
        }

        // Not on a branch (`symbolic-ref` exits non-zero for a detached
        // `HEAD` or an unborn branch with no commits yet): resolve the
        // commit id directly. `rev-parse HEAD` itself fails (no commits
        // yet) only for a brand-new, empty repository, which is treated
        // the same as detached-with-no-commit rather than as an error,
        // since there is nothing further to attribute.
        let revParseHeadArguments = GitInvocationHardening.arguments(for: .revParse, arguments: ["--verify", "-q", "HEAD"])
        let revParseHeadInvocation = GitInvocation(
            executableURL: executableURL,
            arguments: revParseHeadArguments,
            currentDirectoryURL: repositoryRoot,
            environment: env,
            timeout: 10
        )
        let revParseHeadResult = try await runner.run(revParseHeadInvocation)
        guard revParseHeadResult.exitCode == 0 else {
            return .detached(commitID: "")
        }
        let commitID = String(decoding: revParseHeadResult.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .detached(commitID: commitID)
    }
}
