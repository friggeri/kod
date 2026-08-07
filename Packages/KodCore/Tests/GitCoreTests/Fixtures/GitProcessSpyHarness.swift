import Foundation
import GitCore

struct GitSpyInvocationRecord: Decodable, Equatable {
    let arguments: [String]
    let currentDirectory: String
    let environment: [String: String]
    let unexpectedEnvironmentKeys: [String]
}

/// Wires `GitProcessSpy` in as the "resolved Git executable" for a test,
/// so every invocation GitCore's services construct is transparently
/// logged (exact argv + a fixed observed-key subset of env) before the
/// spy re-execs the real Git binary with the same argv/env — meaning
/// functional behavior is unaffected but every invocation is now
/// independently inspectable.
struct GitProcessSpyHarness {
    let logURL: URL
    let spyExecutableURL: URL
    let realGitExecutableURL: URL

    static func make() throws -> GitProcessSpyHarness {
        let spyExecutableURL = try GitProcessSpyLocator.executableURL()
        let realGitExecutableURL = try GitExecutableLocator.resolve()
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-process-spy-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        return GitProcessSpyHarness(logURL: logURL, spyExecutableURL: spyExecutableURL, realGitExecutableURL: realGitExecutableURL)
    }

    /// The same environment `GitInvocationHardening.environment(home:)`
    /// builds, plus the two spy-only control variables the spy binary
    /// itself needs to find its log file and the real Git to delegate
    /// to. Pass this (instead of calling `GitInvocationHardening
    /// .environment` directly) as a service's `environment` argument,
    /// together with `executableURL: spyExecutableURL`, and every
    /// invocation transparently passes through the spy.
    func environment(home: String?) -> [String: String] {
        var environment = GitInvocationHardening.environment(home: home)
        environment["GIT_PROCESS_SPY_LOG_PATH"] = logURL.path
        environment["GIT_PROCESS_SPY_REAL_GIT"] = realGitExecutableURL.path
        return environment
    }

    func records() throws -> [GitSpyInvocationRecord] {
        guard let data = FileManager.default.contents(atPath: logURL.path), !data.isEmpty else {
            return []
        }
        let decoder = JSONDecoder()
        return try data.split(separator: 0x0A).map { line in
            try decoder.decode(GitSpyInvocationRecord.self, from: Data(line))
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: logURL)
    }
}
