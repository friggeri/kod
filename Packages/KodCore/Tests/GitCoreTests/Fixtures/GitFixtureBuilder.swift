import Foundation
import GitCore

enum GitFixtureError: Error {
    case commandFailed(arguments: [String], exitCode: Int32, stderr: String)
}

/// Builds small, deterministic Git repositories for `GitCoreTests` by
/// shelling out directly to the real, resolved `git` binary with
/// ordinary (mutating) commands — `init`, `add`, `commit`, `mv`, `rm`,
/// `merge`, `checkout`. This is test-fixture setup code, entirely
/// separate from `GitCore`'s own production invocation path (which
/// never issues any of these commands); nothing here is exercised by
/// `GitContext`, `GitStatusService`, `GitDiffService`, or
/// `GitBlameService` themselves.
///
/// Every commit uses fixed `GIT_AUTHOR_DATE`/`GIT_COMMITTER_DATE` and
/// identity environment variables so repeated fixture builds produce
/// byte-identical commit ids, timestamps, and blame output — the
/// "deterministic" fixtures SPEC 9's Phase 9 tests compare golden
/// parsed output against.
final class GitFixtureBuilder {
    let rootURL: URL
    private let gitExecutableURL: URL

    private static let baseEnvironment: [String: String] = [
        "PATH": "/usr/bin:/bin",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "HOME": FileManager.default.temporaryDirectory.path,
        "LC_ALL": "C",
        "LANG": "C"
    ]

    private init(rootURL: URL, gitExecutableURL: URL) {
        self.rootURL = rootURL
        self.gitExecutableURL = gitExecutableURL
    }

    /// Creates a fresh temporary directory, `git init -b main`s it, and
    /// returns a builder ready for `write`/`add`/`commit` calls.
    static func makeEmptyRepository(defaultBranch: String = "main") throws -> GitFixtureBuilder {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitCoreFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let gitExecutableURL = try GitExecutableLocator.resolve()
        let builder = GitFixtureBuilder(rootURL: root, gitExecutableURL: gitExecutableURL)
        try builder.run(["init", "-q", "-b", defaultBranch])
        return builder
    }

    func removeAll() throws {
        try FileManager.default.removeItem(at: rootURL)
    }

    // MARK: File contents

    func write(_ relativePath: String, text: String) throws {
        try write(relativePath, data: Data(text.utf8))
    }

    func write(_ relativePath: String, data: Data) throws {
        let url = rootURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    func makeExecutable(_ relativePath: String) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: rootURL.appendingPathComponent(relativePath).path
        )
    }

    func remove(_ relativePath: String) throws {
        try FileManager.default.removeItem(at: rootURL.appendingPathComponent(relativePath))
    }

    // MARK: Plumbing/porcelain used by fixture setup only

    @discardableResult
    func run(_ arguments: [String], extraEnvironment: [String: String] = [:]) throws -> String {
        var environment = Self.baseEnvironment
        for (key, value) in extraEnvironment {
            environment[key] = value
        }

        let process = Process()
        process.executableURL = gitExecutableURL
        process.arguments = arguments
        process.currentDirectoryURL = rootURL
        process.environment = environment
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        try process.run()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw GitFixtureError.commandFailed(
                arguments: arguments,
                exitCode: process.terminationStatus,
                stderr: String(decoding: stderrData, as: UTF8.self)
            )
        }
        return String(decoding: stdoutData, as: UTF8.self)
    }

    func add(_ paths: String...) throws {
        try run(["add", "--"] + paths)
    }

    func addAll() throws {
        try run(["add", "-A"])
    }

    /// Commits with a fixed author/committer identity and timestamp, so
    /// fixture repositories are byte-for-byte reproducible across runs
    /// and machines (no dependence on the ambient system clock, time
    /// zone, or any real user identity).
    @discardableResult
    func commit(
        message: String,
        authorName: String = "Ada Fixture",
        authorEmail: String = "ada@example.com",
        date: String,
        allowEmpty: Bool = false
    ) throws -> String {
        var arguments = ["commit", "-q", "-m", message]
        if allowEmpty {
            arguments.append("--allow-empty")
        }
        try run(arguments, extraEnvironment: [
            "GIT_AUTHOR_NAME": authorName,
            "GIT_AUTHOR_EMAIL": authorEmail,
            "GIT_AUTHOR_DATE": date,
            "GIT_COMMITTER_NAME": authorName,
            "GIT_COMMITTER_EMAIL": authorEmail,
            "GIT_COMMITTER_DATE": date
        ])
        return try revParseHEAD()
    }

    func revParseHEAD() throws -> String {
        try run(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func move(_ from: String, _ to: String) throws {
        try run(["mv", from, to])
    }

    func removeFromIndex(_ path: String, cached: Bool = false) throws {
        try run(cached ? ["rm", "-q", "--cached", path] : ["rm", "-q", path])
    }

    func checkout(_ arguments: String...) throws {
        try run(["checkout", "-q"] + arguments)
    }

    func createBranch(_ name: String) throws {
        try run(["branch", "-q", name])
    }

    /// Attempts a merge that is expected to conflict, leaving the
    /// repository's index/worktree in a genuinely unmerged state for
    /// `GitStatusService`/`GitStatusParser` conflict tests. Deliberately
    /// ignores the (expected non-zero) exit code merge itself reports.
    func mergeExpectingConflict(_ branch: String) throws {
        _ = try? run(["merge", "--no-commit", "--no-edit", branch])
    }
}
