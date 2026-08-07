import Foundation

public enum GitDiffServiceError: Error, Equatable, Sendable {
    case processFailed(exitCode: Int32, message: String)
    case fileNotFound(String)
}

/// Computes one file's Git diff for a given target (SPEC 9.1: "File diff
/// against HEAD, index, or working tree as applicable"), producing a
/// fully parsed `GitFileDiff` (hunks or binary marker, plus rename/mode
/// metadata) ready for the unified or side-by-side viewer.
///
/// Every request is a two-step, always-read-only invocation:
///
/// 1. `git diff --raw -z` resolves exact file identity (added/deleted/
///    modified/renamed/copied, old/new mode, old/new path) with no
///    path-quoting ambiguity, since `-z` NUL-separates raw path bytes.
/// 2. `git diff` (patch/unified mode), restricted with `--` to exactly
///    the old+new path pair step 1 resolved, produces the hunks. Passing
///    both paths together (not just the new one) is required for Git's
///    own rename pairing to kick in within a single, pathspec-restricted
///    invocation — see `GitDiffParser` and this type's tests for why a
///    single-path restriction silently defeats rename detection.
///
/// Untracked files (no tree-side entry at all, in any target) are
/// diffed with `git diff --no-index -- /dev/null <path>`, the only Git
/// invocation in this file allowed to exit `1` as a normal ("files
/// differ") outcome rather than an error.
public struct GitDiffService: Sendable {
    private let executableURL: URL
    private let repositoryRoot: URL
    private let environment: [String: String]
    private let runner: GitProcessRunner

    public init(
        executableURL: URL,
        repositoryRoot: URL,
        environment: [String: String],
        runner: GitProcessRunner = GitProcessRunner()
    ) {
        self.executableURL = executableURL
        self.repositoryRoot = repositoryRoot
        self.environment = environment
        self.runner = runner
    }

    /// Diffs `path` (its current/new-side name) for `target`. Pass
    /// `knownOldPath` when the caller already knows (e.g. from a prior
    /// `GitStatusEntry.originalPath`) that this path is a rename/copy —
    /// this both guarantees correct pairing and avoids an unrestricted,
    /// whole-repository identity scan.
    public func diff(
        path: String,
        target: GitDiffTarget,
        isUntracked: Bool = false,
        knownOldPath: String? = nil
    ) async throws -> GitFileDiff {
        if isUntracked {
            return try await diffUntrackedFile(path: path)
        }

        let pathspec = knownOldPath.map { [$0, path] } ?? [path]
        let change = try await resolveIdentity(target: target, pathspec: pathspec, fallbackPath: path)
        let effectivePathspec = [change.oldPath, change.newPath].compactMap { $0 }
        let content = try await resolveContent(target: target, pathspec: effectivePathspec)
        return GitFileDiff(change: change, content: content)
    }

    private func resolveIdentity(
        target: GitDiffTarget,
        pathspec: [String],
        fallbackPath: String
    ) async throws -> GitDiffFileChange {
        let arguments = diffTargetArguments(target) + ["--raw", "-z", "-M", "-C", "--"] + pathspec
        let result = try await runInvocation(arguments)
        guard result.exitCode == 0 else {
            throw GitDiffServiceError.processFailed(exitCode: result.exitCode, message: result.standardErrorMessage)
        }
        let changes = try GitDiffParser.parseRawIdentity(result.standardOutput)
        guard let change = changes.first(where: { $0.newPath == fallbackPath || $0.oldPath == fallbackPath }) ?? changes.first else {
            throw GitDiffServiceError.fileNotFound(fallbackPath)
        }
        return change
    }

    private func resolveContent(target: GitDiffTarget, pathspec: [String]) async throws -> GitDiffContent {
        let arguments = diffTargetArguments(target) + ["-p", "-M", "-C", "--no-ext-diff", "--no-textconv", "--"] + pathspec
        let result = try await runInvocation(arguments)
        guard result.exitCode == 0 else {
            throw GitDiffServiceError.processFailed(exitCode: result.exitCode, message: result.standardErrorMessage)
        }
        let text = String(decoding: result.standardOutput, as: UTF8.self)
        return try GitDiffParser.parseContent(text)
    }

    private func diffUntrackedFile(path: String) async throws -> GitFileDiff {
        let absolutePath = repositoryRoot.appendingPathComponent(path).path
        let subcommandArguments = ["--no-index", "-M", "--no-ext-diff", "--no-textconv", "--", "/dev/null", absolutePath]
        let result = try await runInvocation(subcommandArguments)
        // `--no-index` uses exit code 1 to mean "the two inputs differ"
        // (the normal, expected outcome here) rather than an error; any
        // other non-zero code is a genuine failure.
        guard result.exitCode == 0 || result.exitCode == 1 else {
            throw GitDiffServiceError.processFailed(exitCode: result.exitCode, message: result.standardErrorMessage)
        }
        let text = String(decoding: result.standardOutput, as: UTF8.self)
        let content = try GitDiffParser.parseContent(text)
        let change = GitDiffFileChange(kind: .added, oldPath: nil, newPath: path)
        return GitFileDiff(change: change, content: content)
    }

    private func diffTargetArguments(_ target: GitDiffTarget) -> [String] {
        switch target {
        case .workingTreeVsIndex:
            return []
        case .indexVsHead:
            return ["--cached"]
        case .workingTreeVsHead:
            return ["HEAD"]
        }
    }

    private func runInvocation(_ subcommandArguments: [String]) async throws -> GitProcessResult {
        let arguments = GitInvocationHardening.arguments(for: .diff, arguments: subcommandArguments)
        let invocation = GitInvocation(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectoryURL: repositoryRoot,
            environment: environment
        )
        return try await runner.run(invocation)
    }
}
