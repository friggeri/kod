import Foundation

public enum GitStatusServiceError: Error, Equatable, Sendable {
    case processFailed(exitCode: Int32, message: String)
}

/// Runs `git status --porcelain=v2 -z` and parses the result. Always
/// invoked with `--no-optional-locks` (both the global flag and the
/// `GIT_OPTIONAL_LOCKS=0` environment variable Kod sets for every
/// invocation), which prevents Git's normal opportunistic index-refresh
/// write-back — the one thing a plain `git status` would otherwise
/// write to `.git/index` even though it is conceptually a read-only
/// command. See `GitImmutabilityTests` for the empirical proof.
public struct GitStatusService: Sendable {
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

    public func status() async throws -> GitStatusSnapshot {
        let arguments = GitInvocationHardening.arguments(
            for: .status,
            arguments: [
                "--porcelain=v2",
                "-z",
                "--untracked-files=all",
                "--ignored=matching",
                "--find-renames",
                "--no-ahead-behind"
            ]
        )
        let invocation = GitInvocation(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectoryURL: repositoryRoot,
            environment: environment
        )
        let result = try await runner.run(invocation)
        guard result.exitCode == 0 else {
            throw GitStatusServiceError.processFailed(exitCode: result.exitCode, message: result.standardErrorMessage)
        }
        return try GitStatusParser.parse(result.standardOutput)
    }
}
