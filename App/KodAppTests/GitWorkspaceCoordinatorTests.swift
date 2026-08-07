import DiagnosticsCore
import Foundation
import GitCore
import WorkspaceCore
import XCTest
@testable import Kod

/// Headless coverage for `GitWorkspaceCoordinator` (SPEC 9): repository
/// detection is optional per workspace, status refresh flows through the
/// same FSEvents batch signal Explorer already uses, and Explorer badge
/// classification matches SPEC 9.1's staged/unstaged/untracked/ignored/
/// conflicted/renamed groups. Uses a real, disposable fixture repository
/// (never `KodAppUITests`/`XCUIApplication`) so this exercises real Git
/// process invocation end to end, exactly like `GitCoreTests`.
@MainActor
final class GitWorkspaceCoordinatorTests: XCTestCase {
    private func makeFixtureRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitWorkspaceCoordinatorFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let gitExecutableURL = try GitExecutableLocator.resolve()
        func run(_ arguments: [String], extraEnvironment: [String: String] = [:]) throws {
            var environment: [String: String] = [
                "PATH": "/usr/bin:/bin",
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_CONFIG_SYSTEM": "/dev/null",
                "HOME": FileManager.default.temporaryDirectory.path
            ]
            for (key, value) in extraEnvironment {
                environment[key] = value
            }
            let process = Process()
            process.executableURL = gitExecutableURL
            process.arguments = arguments
            process.currentDirectoryURL = root
            process.environment = environment
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
        }

        try run(["init", "-q", "-b", "main"])
        try Data("hi\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        try run(["add", "-A"])
        try run(["commit", "-q", "-m", "c1"], extraEnvironment: [
            "GIT_AUTHOR_NAME": "Ada", "GIT_AUTHOR_EMAIL": "ada@example.com",
            "GIT_AUTHOR_DATE": "2024-01-01T10:00:00 -0500",
            "GIT_COMMITTER_NAME": "Ada", "GIT_COMMITTER_EMAIL": "ada@example.com",
            "GIT_COMMITTER_DATE": "2024-01-01T10:00:00 -0500"
        ])
        return root
    }

    func testStartOnANonGitFolderLeavesContextNilWithoutThrowing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotAGitRepo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var observedSnapshots: [GitStatusSnapshot?] = []
        let coordinator = GitWorkspaceCoordinator(root: root) { snapshot in
            observedSnapshots.append(snapshot)
        }
        await coordinator.start()

        XCTAssertTrue(coordinator.hasStarted)
        XCTAssertNil(coordinator.context)
        XCTAssertNil(coordinator.latestStatus)
        XCTAssertEqual(observedSnapshots, [nil])
    }

    /// SPEC 15's "genuine, real, working" diagnostic-event wiring for the
    /// Git subsystem: opening a non-Git folder is the same real,
    /// already-existing (non-fatal) failure path exercised above,
    /// recorded into the shared `BoundedEventLog` rather than only ever
    /// swallowed by `try?`.
    func testStartOnANonGitFolderRecordsAGitDiagnosticEvent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotAGitRepo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let log = BoundedEventLog()
        let coordinator = GitWorkspaceCoordinator(root: root, diagnosticsLog: log)
        await coordinator.start()

        let events = await log.redactedSnapshot()
        let gitEvents = events.filter { $0.subsystem == .git }
        XCTAssertFalse(gitEvents.isEmpty, "Opening a non-Git folder should record a .git diagnostic event")
        XCTAssertTrue(gitEvents.allSatisfy { event in
            event.context.first { $0.name == "workspaceRoot" }?.value == "<path redacted>"
        }, "The workspace root must be tagged .fullPath so it is fully redacted in the event's context, never left as a raw path")
    }

    func testStartOnAGitFolderLoadsAnInitialStatusAndBadgesReflectIt() async throws {
        let root = try makeFixtureRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("hi\nchanged\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("untracked\n".utf8).write(to: root.appendingPathComponent("b.txt"))

        var observedSnapshots: [GitStatusSnapshot?] = []
        let coordinator = GitWorkspaceCoordinator(root: root) { snapshot in
            observedSnapshots.append(snapshot)
        }
        await coordinator.start()

        XCTAssertNotNil(coordinator.context)
        XCTAssertEqual(coordinator.badge(forRelativePath: "a.txt"), .modified)
        XCTAssertEqual(coordinator.badge(forRelativePath: "b.txt"), .untracked)
        XCTAssertNil(coordinator.badge(forRelativePath: "does-not-exist.txt"))
        XCTAssertFalse(observedSnapshots.isEmpty)
    }

    func testHandleBatchInvalidatesCacheAndRefreshesStatus() async throws {
        let root = try makeFixtureRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        let coordinator = GitWorkspaceCoordinator(root: root)
        await coordinator.start()
        XCTAssertNil(coordinator.badge(forRelativePath: "a.txt"))

        try Data("hi\nchanged\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        // Without a signal, the coordinator would still serve the cached
        // (clean) snapshot from `GitContext`'s identity-keyed cache.
        await coordinator.refresh()
        XCTAssertNil(coordinator.badge(forRelativePath: "a.txt"), "expected the cached snapshot before invalidation")

        await coordinator.handle(
            WorkspaceChangeBatch(paths: [WorkspaceChangePath(path: root.appendingPathComponent("a.txt").path, flags: .modified)])
        )
        XCTAssertEqual(coordinator.badge(forRelativePath: "a.txt"), .modified)
    }

    func testBadgeClassificationCoversEveryGitExplorerBadgeCase() {
        func snapshot(with entry: GitStatusEntry) -> GitStatusSnapshot {
            GitStatusSnapshot(entries: [entry])
        }
        let coordinator = GitWorkspaceCoordinator(root: FileManager.default.temporaryDirectory)

        let added = GitStatusEntry(path: "a.txt", shape: .ordinary(indexStatus: .added, worktreeStatus: .unmodified))
        coordinator.applyTestSnapshot(snapshot(with: added))
        XCTAssertEqual(coordinator.badge(forRelativePath: "a.txt"), .added)

        let deleted = GitStatusEntry(path: "d.txt", shape: .ordinary(indexStatus: .unmodified, worktreeStatus: .deleted))
        coordinator.applyTestSnapshot(snapshot(with: deleted))
        XCTAssertEqual(coordinator.badge(forRelativePath: "d.txt"), .deleted)

        let renamed = GitStatusEntry(
            path: "new.txt",
            shape: .renameOrCopy(indexStatus: .renamed, worktreeStatus: .unmodified, similarityPercentage: 100, originalPath: "old.txt")
        )
        coordinator.applyTestSnapshot(snapshot(with: renamed))
        XCTAssertEqual(coordinator.badge(forRelativePath: "new.txt"), .renamed)

        let ignored = GitStatusEntry(path: "debug.log", shape: .ignored)
        coordinator.applyTestSnapshot(snapshot(with: ignored))
        XCTAssertNil(coordinator.badge(forRelativePath: "debug.log"))

        let conflicted = GitStatusEntry(
            path: "shared.txt",
            shape: .unmerged(
                code: "UU",
                base: nil,
                ours: GitUnmergedStage(mode: "100644", objectID: String(repeating: "a", count: 40)),
                theirs: GitUnmergedStage(mode: "100644", objectID: String(repeating: "b", count: 40))
            )
        )
        coordinator.applyTestSnapshot(snapshot(with: conflicted))
        XCTAssertEqual(coordinator.badge(forRelativePath: "shared.txt"), .conflicted)
    }
}
