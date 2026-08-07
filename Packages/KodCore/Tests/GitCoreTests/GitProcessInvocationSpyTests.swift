import Foundation
import XCTest
@testable import GitCore

/// Proves Kod's Git process-launch discipline (SPEC 9.2) empirically:
/// `GitProcessSpy` stands in for the resolved Git executable, logging
/// the exact argv/env each service constructed before re-executing the
/// real Git binary — so these assertions inspect precisely what
/// `Process.executableURL`/`Process.arguments`/`Process.environment`
/// GitCore itself built, independent of what Git does with them.
final class GitProcessInvocationSpyTests: XCTestCase {
    private static let knownMutatingOrNetworkSubcommands: Set<String> = [
        "add", "commit", "checkout", "switch", "reset", "push", "pull", "fetch",
        "merge", "rebase", "cherry-pick", "revert", "stash", "clean", "gc",
        "remote", "submodule", "worktree", "tag", "branch", "mv", "rm",
        "apply", "am", "reflog", "filter-branch", "filter-repo", "clone",
        "init", "prune", "repack", "pack-refs", "update-ref", "notes",
        "replace", "credential", "credential-cache", "credential-store"
    ]

    func testStatusInvocationHasNoMutatingOrNetworkSubcommandAndSetsHardening() async throws {
        let harness = try GitProcessSpyHarness.make()
        defer { harness.cleanup() }
        let fixture = try GitFixtureBuilder.makeEmptyRepository()
        defer { try? fixture.removeAll() }
        try fixture.write("a.txt", text: "hi\n")
        try fixture.addAll()
        _ = try fixture.commit(message: "c1", date: "2024-01-01T10:00:00 -0500")
        try fixture.write("a.txt", text: "hi\nchanged\n")

        let service = GitStatusService(
            executableURL: harness.spyExecutableURL,
            repositoryRoot: fixture.rootURL,
            environment: harness.environment(home: ProcessInfo.processInfo.environment["HOME"])
        )
        _ = try await service.status()

        let records = try harness.records()
        XCTAssertEqual(records.count, 1)
        try assertHardened(records[0], expectedSubcommand: "status")
    }

    func testDiffInvocationsHaveNoMutatingOrNetworkSubcommandAndSetHardening() async throws {
        let harness = try GitProcessSpyHarness.make()
        defer { harness.cleanup() }
        let fixture = try GitFixtureBuilder.makeEmptyRepository()
        defer { try? fixture.removeAll() }
        try fixture.write("a.txt", text: "hi\n")
        try fixture.addAll()
        _ = try fixture.commit(message: "c1", date: "2024-01-01T10:00:00 -0500")
        try fixture.write("a.txt", text: "hi\nchanged\n")

        let service = GitDiffService(
            executableURL: harness.spyExecutableURL,
            repositoryRoot: fixture.rootURL,
            environment: harness.environment(home: ProcessInfo.processInfo.environment["HOME"])
        )
        _ = try await service.diff(path: "a.txt", target: .workingTreeVsIndex)

        let records = try harness.records()
        XCTAssertEqual(records.count, 2, "identity (--raw) then patch (-p) invocations")
        for record in records {
            try assertHardened(record, expectedSubcommand: "diff")
        }
    }

    func testBlameInvocationHasNoMutatingOrNetworkSubcommandAndSetsHardening() async throws {
        let harness = try GitProcessSpyHarness.make()
        defer { harness.cleanup() }
        let fixture = try GitFixtureBuilder.makeEmptyRepository()
        defer { try? fixture.removeAll() }
        try fixture.write("a.txt", text: "hi\n")
        try fixture.addAll()
        _ = try fixture.commit(message: "c1", date: "2024-01-01T10:00:00 -0500")

        let service = GitBlameService(
            executableURL: harness.spyExecutableURL,
            repositoryRoot: fixture.rootURL,
            environment: harness.environment(home: ProcessInfo.processInfo.environment["HOME"])
        )
        _ = try await service.blame(path: "a.txt")

        let records = try harness.records()
        XCTAssertEqual(records.count, 1)
        try assertHardened(records[0], expectedSubcommand: "blame")
    }

    func testRepositoryLocatorInvocationsUseOnlyRevParseAndSymbolicRef() async throws {
        let harness = try GitProcessSpyHarness.make()
        defer { harness.cleanup() }
        let fixture = try GitFixtureBuilder.makeEmptyRepository()
        defer { try? fixture.removeAll() }
        try fixture.write("a.txt", text: "hi\n")
        try fixture.addAll()
        _ = try fixture.commit(message: "c1", date: "2024-01-01T10:00:00 -0500")

        let locator = GitRepositoryLocator(
            executableURL: harness.spyExecutableURL,
            environment: { home in harness.environment(home: home) }
        )
        _ = try await locator.locate(startingAt: fixture.rootURL)

        let records = try harness.records()
        XCTAssertFalse(records.isEmpty)
        for record in records {
            let subcommand = try XCTUnwrap(record.arguments.first { !$0.hasPrefix("-") && !$0.contains("=") })
            XCTAssertTrue(
                ["rev-parse", "symbolic-ref"].contains(subcommand),
                "unexpected subcommand \(subcommand)"
            )
            XCTAssertFalse(Self.knownMutatingOrNetworkSubcommands.contains(subcommand))
        }
    }

    /// Hostile, shell-metacharacter-laden paths/arguments must round-trip
    /// byte-for-byte through `Process.arguments` — proof no shell ever
    /// evaluates them (mirrors `ProcessInvocationAssertionTests` in
    /// `LanguageClientTests`).
    func testHostileArgumentsRoundTripWithoutShellEvaluation() async throws {
        let harness = try GitProcessSpyHarness.make()
        defer { harness.cleanup() }
        let fixture = try GitFixtureBuilder.makeEmptyRepository()
        defer { try? fixture.removeAll() }

        let hostileName = "; rm -rf / #$(whoami)`id`'\".txt"
        try fixture.write(hostileName, text: "hi\n")
        try fixture.addAll()
        _ = try fixture.commit(message: "c1", date: "2024-01-01T10:00:00 -0500")
        try fixture.write(hostileName, text: "hi\nchanged\n")

        let service = GitDiffService(
            executableURL: harness.spyExecutableURL,
            repositoryRoot: fixture.rootURL,
            environment: harness.environment(home: ProcessInfo.processInfo.environment["HOME"])
        )
        let diff = try await service.diff(path: hostileName, target: .workingTreeVsIndex)
        XCTAssertEqual(diff.change.newPath, hostileName)

        let records = try harness.records()
        XCTAssertTrue(records.contains { $0.arguments.contains(hostileName) })
    }

    func testEnvironmentContainsNoUnexpectedAmbientKeys() async throws {
        let harness = try GitProcessSpyHarness.make()
        defer { harness.cleanup() }
        let fixture = try GitFixtureBuilder.makeEmptyRepository()
        defer { try? fixture.removeAll() }
        try fixture.write("a.txt", text: "hi\n")
        try fixture.addAll()
        _ = try fixture.commit(message: "c1", date: "2024-01-01T10:00:00 -0500")

        let service = GitStatusService(
            executableURL: harness.spyExecutableURL,
            repositoryRoot: fixture.rootURL,
            environment: harness.environment(home: ProcessInfo.processInfo.environment["HOME"])
        )
        _ = try await service.status()

        let record = try XCTUnwrap(harness.records().first)
        XCTAssertEqual(record.environment["GIT_OPTIONAL_LOCKS"], "0")
        XCTAssertEqual(record.environment["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertEqual(record.environment["GIT_SSH_COMMAND"], "/usr/bin/false")
        // Ignore the two harness-only control variables (test-fixture
        // plumbing that tells the spy where to log and which real Git to
        // delegate to — never set by production `GitCore` code) and a
        // benign CoreFoundation locale-encoding variable macOS itself
        // injects into every child process regardless of the explicit
        // environment dictionary a parent provides.
        let ignorable: Set<String> = ["GIT_PROCESS_SPY_LOG_PATH", "GIT_PROCESS_SPY_REAL_GIT", "__CF_USER_TEXT_ENCODING"]
        let unexpected = record.unexpectedEnvironmentKeys.filter { !ignorable.contains($0) }
        XCTAssertTrue(unexpected.isEmpty, "unexpected keys: \(unexpected)")
    }

    private func assertHardened(_ record: GitSpyInvocationRecord, expectedSubcommand: String) throws {
        XCTAssertEqual(record.arguments.first(where: { !$0.hasPrefix("-") && !$0.contains("=") }), expectedSubcommand)
        XCTAssertTrue(record.arguments.contains("--no-pager"))
        XCTAssertTrue(record.arguments.contains("--no-optional-locks"))
        XCTAssertTrue(record.arguments.contains("--no-replace-objects"))
        XCTAssertTrue(record.arguments.contains("core.hooksPath=/dev/null"))
        XCTAssertTrue(record.arguments.contains("core.fsmonitor=false"))
        XCTAssertTrue(record.arguments.contains("diff.external="))
        XCTAssertEqual(record.environment["GIT_OPTIONAL_LOCKS"], "0")
        XCTAssertEqual(record.environment["GIT_TERMINAL_PROMPT"], "0")

        for subcommand in Self.knownMutatingOrNetworkSubcommands {
            XCTAssertFalse(
                record.arguments.contains(subcommand),
                "found forbidden subcommand/token '\(subcommand)' in \(record.arguments)"
            )
        }
    }
}
