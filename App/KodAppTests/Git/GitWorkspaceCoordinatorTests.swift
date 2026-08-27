import DiagnosticsCore
import Foundation
import GitCore
import GitUI
import WorkspaceCore
import XCTest
@testable import Kod

/// Headless coverage for `GitWorkspaceCoordinator` (SPEC 9): repository
/// detection is optional per workspace, status refresh flows through the
/// same FSEvents batch signal Explorer already uses, and publishes the
/// GitUI presentation index consumed by Explorer and Source Control.
/// The index's pure precedence/propagation coverage lives in
/// `GitStatusPresentationTests`. Uses a real, disposable fixture repository
/// (never `KodAppUITests`/`XCUIApplication`) so this exercises real Git
/// process invocation end to end, exactly like `GitCoreTests`.
@MainActor
final class GitWorkspaceCoordinatorTests: XCTestCase {
    @discardableResult
    private func runGit(
        _ arguments: [String],
        at root: URL,
        extraEnvironment: [String: String] = [:]
    ) throws -> String {
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
        process.executableURL = try GitExecutableLocator.resolve()
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")) failed")
        return String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeFixtureRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitWorkspaceCoordinatorFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try runGit(["init", "-q", "-b", "main"], at: root)
        try Data("hi\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        try runGit(["add", "-A"], at: root)
        try runGit(["commit", "-q", "-m", "c1"], at: root, extraEnvironment: [
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
        let coordinator = GitWorkspaceCoordinator(
            root: root,
            diagnosticsLog: BoundedEventLog()
        ) { snapshot in
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

    func testMalformedRepositoryStartsUnavailableRatherThanNoRepository() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MalformedGitWorkspace-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data("invalid gitfile\n".utf8).write(
            to: root.appendingPathComponent(".git")
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let coordinator = GitWorkspaceCoordinator(
            root: root,
            diagnosticsLog: BoundedEventLog()
        )
        await coordinator.start()

        guard case .unavailable(nil, let reason) =
                coordinator.repositoryState else {
            return XCTFail("Expected unavailable repository state")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertNil(coordinator.latestStatus)
    }

    func testStartOnAGitFolderLoadsAnInitialStatusAndDecorationsReflectIt() async throws {
        let root = try makeFixtureRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("hi\nchanged\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("untracked\n".utf8).write(to: root.appendingPathComponent("b.txt"))

        var observedSnapshots: [GitStatusSnapshot?] = []
        let coordinator = GitWorkspaceCoordinator(
            root: root,
            diagnosticsLog: BoundedEventLog()
        ) { snapshot in
            observedSnapshots.append(snapshot)
        }
        await coordinator.start()

        XCTAssertNotNil(coordinator.context)
        XCTAssertEqual(
            coordinator.explorerDecoration(forRelativePath: "a.txt", isDirectory: false),
            GitExplorerDecoration(
                presentation: GitStatusPresentation(status: .modified, colorRole: .modified),
                indicator: .statusLetter
            )
        )
        XCTAssertEqual(
            coordinator.explorerDecoration(forRelativePath: "b.txt", isDirectory: false),
            GitExplorerDecoration(
                presentation: GitStatusPresentation(status: .untracked, colorRole: .untracked),
                indicator: .statusLetter
            )
        )
        XCTAssertNil(
            coordinator.explorerDecoration(
                forRelativePath: "does-not-exist.txt",
                isDirectory: false
            )
        )
        XCTAssertFalse(observedSnapshots.isEmpty)
    }

    func testRefreshPublishesLiveBranchAndDetachedHeadWithStatusAtomically() async throws {
        let root = try makeFixtureRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = GitWorkspaceCoordinator(
            root: root,
            diagnosticsLog: BoundedEventLog()
        )
        await coordinator.start()

        guard case .available(let initialLocation, _) = coordinator.repositoryState else {
            return XCTFail("Expected available repository state")
        }
        XCTAssertEqual(initialLocation.head, .branch(name: "main"))

        try runGit(["checkout", "-q", "-b", "feature/status"], at: root)
        await coordinator.refresh()
        guard case .available(let branchLocation, let branchStatus) =
                coordinator.repositoryState else {
            return XCTFail("Expected branch repository state")
        }
        XCTAssertEqual(branchLocation.head, .branch(name: "feature/status"))
        XCTAssertEqual(coordinator.latestStatus, branchStatus)

        let commitID = try runGit(["rev-parse", "HEAD"], at: root)
        try runGit(["checkout", "-q", "--detach", "HEAD"], at: root)
        await coordinator.refresh()
        guard case .available(let detachedLocation, let detachedStatus) =
                coordinator.repositoryState else {
            return XCTFail("Expected detached repository state")
        }
        XCTAssertEqual(detachedLocation.head, .detached(commitID: commitID))
        XCTAssertEqual(coordinator.latestStatus, detachedStatus)
    }

    func testRefreshFailureIsUnavailableRatherThanFalseClean() async throws {
        let root = try makeFixtureRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = GitWorkspaceCoordinator(
            root: root,
            diagnosticsLog: BoundedEventLog()
        )
        await coordinator.start()

        try FileManager.default.removeItem(
            at: root.appendingPathComponent(".git", isDirectory: true)
        )
        await coordinator.refresh()

        guard case .unavailable(let location, let reason) =
                coordinator.repositoryState else {
            return XCTFail("Expected unavailable repository state")
        }
        XCTAssertNotNil(location)
        XCTAssertFalse(reason.isEmpty)
        XCTAssertNil(coordinator.latestStatus)
    }

    func testHandleBatchInvalidatesCacheAndRefreshesStatus() async throws {
        let root = try makeFixtureRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        let coordinator = GitWorkspaceCoordinator(
            root: root,
            diagnosticsLog: BoundedEventLog()
        )
        await coordinator.start()
        XCTAssertNil(coordinator.explorerDecoration(forRelativePath: "a.txt", isDirectory: false))

        try Data("hi\nchanged\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        // Without a signal, the coordinator would still serve the cached
        // (clean) snapshot from `GitContext`'s identity-keyed cache.
        await coordinator.refresh()
        XCTAssertNil(
            coordinator.explorerDecoration(forRelativePath: "a.txt", isDirectory: false),
            "expected the cached snapshot before invalidation"
        )

        await coordinator.handle(
            WorkspaceChangeBatch(paths: [WorkspaceChangePath(path: root.appendingPathComponent("a.txt").path, flags: .modified)])
        )
        XCTAssertEqual(
            coordinator.explorerDecoration(
                forRelativePath: "a.txt",
                isDirectory: false
            )?.presentation.status,
            .modified
        )
    }

    func testWorkspaceBatchTranslatesToGitRepositoryInvalidation() {
        let firstPath = "/workspace/a.swift"
        let secondPath = "/workspace/b.swift"
        let batch = WorkspaceChangeBatch(paths: [
            WorkspaceChangePath(path: firstPath, flags: .modified),
            WorkspaceChangePath(path: secondPath, flags: .created),
            WorkspaceChangePath(path: firstPath, flags: .removed)
        ])

        let invalidation = GitWorkspaceCoordinator.gitInvalidation(for: batch)

        XCTAssertEqual(invalidation.changedPaths, Set([firstPath, secondPath]))
    }

    func testRescanBatchInvalidatesTheWorkspaceRoot() {
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let batch = WorkspaceChangeBatch(
            paths: [],
            scope: .rescanRequired(reasons: [.kernelDropped])
        )

        let invalidation = GitWorkspaceCoordinator.gitInvalidation(
            for: batch,
            rescanRoot: root
        )

        XCTAssertEqual(invalidation.changedPaths, [root.path])
    }

}
