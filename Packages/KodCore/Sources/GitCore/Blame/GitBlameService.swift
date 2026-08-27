import Foundation

public enum GitBlameServiceError: Error, Equatable, Sendable {
    case processFailed(exitCode: Int32, message: String)
    /// The caller-supplied revision could not be passed to Git as a
    /// revision without risking a change in how the invocation itself is
    /// parsed (see `GitRevisionArgument`). No process is launched.
    case invalidRevision(GitRevisionArgumentError)
}

/// Runs `git blame --porcelain` for one path and parses the result.
/// Blames the working-tree version by default (so local, uncommitted
/// edits appear as "Not Committed Yet" lines per SPEC 9.1's per-line
/// blame requirement); pass `revision` to blame a specific committed
/// version instead (e.g. `"HEAD"`, or a specific commit id from a
/// commit popover's history view).
public struct GitBlameService: Sendable {
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

    public func blame(path: String, revision: String? = nil) async throws -> GitBlameResult {
        var subcommandArguments = ["--porcelain"]
        if let revision {
            do {
                subcommandArguments.append(try GitRevisionArgument.validated(revision))
            } catch let error as GitRevisionArgumentError {
                throw GitBlameServiceError.invalidRevision(error)
            }
        }
        // The `--` separator stays unconditionally, so a path that looks
        // like an option or a revision is still unambiguously a path.
        subcommandArguments.append(contentsOf: ["--", path])

        let arguments = GitInvocationHardening.arguments(for: .blame, arguments: subcommandArguments)
        let invocation = GitInvocation(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectoryURL: repositoryRoot,
            environment: environment
        )
        let result = try await runner.run(invocation)
        guard result.exitCode == 0 else {
            throw GitBlameServiceError.processFailed(exitCode: result.exitCode, message: result.standardErrorMessage)
        }
        let text = String(decoding: result.standardOutput, as: UTF8.self)
        return try GitBlameParser.parse(text)
    }
}
