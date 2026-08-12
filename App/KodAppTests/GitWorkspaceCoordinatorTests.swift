import DiagnosticsCore
import Foundation
import GitCore
import WorkspaceCore
import XCTest
@testable import Kod

/// Headless coverage for `GitWorkspaceCoordinator` (SPEC 9): repository
/// detection is optional per workspace, status refresh flows through the
/// same FSEvents batch signal Explorer already uses, and the shared
/// presentation index matches VS Code's status precedence, colors, and
/// parent propagation. Uses a real, disposable fixture repository
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

    func testStartOnAGitFolderLoadsAnInitialStatusAndDecorationsReflectIt() async throws {
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

    func testHandleBatchInvalidatesCacheAndRefreshesStatus() async throws {
        let root = try makeFixtureRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        let coordinator = GitWorkspaceCoordinator(root: root)
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

    func testExplorerClassificationCoversEveryLetterAndColorRole() {
        let coordinator = GitWorkspaceCoordinator(root: FileManager.default.temporaryDirectory)

        let cases: [(GitStatusEntry, GitPresentedStatus, GitDecorationColorRole, String?)] = [
            (
                GitStatusEntry(
                    path: "modified.txt",
                    shape: .ordinary(indexStatus: .unmodified, worktreeStatus: .modified)
                ),
                .modified,
                .modified,
                "M"
            ),
            (
                GitStatusEntry(
                    path: "added.txt",
                    shape: .ordinary(indexStatus: .added, worktreeStatus: .unmodified)
                ),
                .added,
                .added,
                "A"
            ),
            (
                GitStatusEntry(
                    path: "deleted.txt",
                    shape: .ordinary(indexStatus: .unmodified, worktreeStatus: .deleted)
                ),
                .deleted,
                .deleted,
                "D"
            ),
            (
                GitStatusEntry(
                    path: "renamed.txt",
                    shape: .renameOrCopy(
                        indexStatus: .renamed,
                        worktreeStatus: .unmodified,
                        similarityPercentage: 100,
                        originalPath: "old.txt"
                    )
                ),
                .renamed,
                .renamed,
                "R"
            ),
            (
                GitStatusEntry(
                    path: "copied.txt",
                    shape: .renameOrCopy(
                        indexStatus: .copied,
                        worktreeStatus: .unmodified,
                        similarityPercentage: 100,
                        originalPath: "source.txt"
                    )
                ),
                .copied,
                .renamed,
                "C"
            ),
            (
                GitStatusEntry(
                    path: "type.txt",
                    shape: .ordinary(indexStatus: .unmodified, worktreeStatus: .typeChanged)
                ),
                .typeChanged,
                .modified,
                "T"
            ),
            (
                GitStatusEntry(path: "untracked.txt", shape: .untracked),
                .untracked,
                .untracked,
                "U"
            ),
            (
                GitStatusEntry(path: "ignored.log", shape: .ignored),
                .ignored,
                .ignored,
                nil
            ),
            (
                GitStatusEntry(
                    path: "conflicted.txt",
                    shape: .unmerged(
                        code: "UU",
                        base: nil,
                        ours: GitUnmergedStage(
                            mode: "100644",
                            objectID: String(repeating: "a", count: 40)
                        ),
                        theirs: GitUnmergedStage(
                            mode: "100644",
                            objectID: String(repeating: "b", count: 40)
                        )
                    )
                ),
                .conflicted,
                .conflict,
                "!"
            )
        ]

        coordinator.applyTestSnapshot(GitStatusSnapshot(entries: cases.map { $0.0 }))

        for (entry, status, colorRole, letter) in cases {
            let decoration = coordinator.explorerDecoration(
                forRelativePath: entry.path,
                isDirectory: false
            )
            XCTAssertEqual(decoration?.presentation.status, status, entry.path)
            XCTAssertEqual(decoration?.presentation.colorRole, colorRole, entry.path)
            XCTAssertEqual(decoration?.badgeText, letter, entry.path)
            XCTAssertEqual(
                decoration?.indicator,
                status == .ignored ? nil : .statusLetter,
                entry.path
            )
            XCTAssertFalse(
                decoration?.accessibilityDescription.isEmpty ?? true,
                "\(entry.path) must expose a full-word accessibility status"
            )
        }
    }

    func testExplorerStatusUsesVSCodePriorityAndWorktreeWinsTies() {
        let coordinator = GitWorkspaceCoordinator(root: FileManager.default.temporaryDirectory)
        let renamedThenModified = GitStatusEntry(
            path: "renamed.txt",
            shape: .renameOrCopy(
                indexStatus: .renamed,
                worktreeStatus: .modified,
                similarityPercentage: 90,
                originalPath: "old.txt"
            )
        )
        let addedThenTypeChanged = GitStatusEntry(
            path: "typed.txt",
            shape: .ordinary(indexStatus: .added, worktreeStatus: .typeChanged)
        )
        let deletedThenAdded = GitStatusEntry(
            path: "tie.txt",
            shape: .ordinary(indexStatus: .deleted, worktreeStatus: .added)
        )
        coordinator.applyTestSnapshot(
            GitStatusSnapshot(entries: [renamedThenModified, addedThenTypeChanged, deletedThenAdded])
        )

        XCTAssertEqual(
            coordinator.explorerDecoration(
                forRelativePath: "renamed.txt",
                isDirectory: false
            )?.presentation.status,
            .modified
        )
        XCTAssertEqual(
            coordinator.explorerDecoration(
                forRelativePath: "typed.txt",
                isDirectory: false
            )?.presentation.status,
            .typeChanged
        )
        XCTAssertEqual(
            coordinator.explorerDecoration(
                forRelativePath: "tie.txt",
                isDirectory: false
            )?.presentation.status,
            .added
        )
    }

    func testNonDeletedChangesPropagateToParentFoldersInConstantTimeIndex() {
        let coordinator = GitWorkspaceCoordinator(root: FileManager.default.temporaryDirectory)
        coordinator.applyTestSnapshot(
            GitStatusSnapshot(entries: [
                GitStatusEntry(
                    path: "Sources/Feature/File.swift",
                    shape: .ordinary(indexStatus: .unmodified, worktreeStatus: .modified)
                ),
                GitStatusEntry(path: "Sources/Other/New.swift", shape: .untracked)
            ])
        )

        let feature = coordinator.explorerDecoration(
            forRelativePath: "Sources/Feature",
            isDirectory: true
        )
        XCTAssertEqual(feature?.presentation.status, .modified)
        XCTAssertEqual(feature?.indicator, .descendant)
        XCTAssertEqual(feature?.badgeText, "\u{2022}")
        XCTAssertTrue(feature?.accessibilityDescription.contains("Modified") == true)

        let sources = coordinator.explorerDecoration(
            forRelativePath: "Sources",
            isDirectory: true
        )
        XCTAssertEqual(sources?.presentation.status, .modified)
        XCTAssertEqual(sources?.indicator, .descendant)
    }

    func testDeletedAndIgnoredEntriesDoNotPropagateToParents() {
        let coordinator = GitWorkspaceCoordinator(root: FileManager.default.temporaryDirectory)
        coordinator.applyTestSnapshot(
            GitStatusSnapshot(entries: [
                GitStatusEntry(
                    path: "Deleted/old.txt",
                    shape: .ordinary(indexStatus: .unmodified, worktreeStatus: .deleted)
                ),
                GitStatusEntry(
                    path: "Mixed/removed.txt",
                    shape: .ordinary(indexStatus: .modified, worktreeStatus: .deleted)
                ),
                GitStatusEntry(path: "Ignored/debug.log", shape: .ignored),
                GitStatusEntry(path: "Build/", shape: .ignored)
            ])
        )

        XCTAssertEqual(
            coordinator.explorerDecoration(
                forRelativePath: "Deleted/old.txt",
                isDirectory: false
            )?.presentation.status,
            .deleted
        )
        XCTAssertNil(
            coordinator.explorerDecoration(
                forRelativePath: "Deleted",
                isDirectory: true
            )
        )
        XCTAssertEqual(
            coordinator.explorerDecoration(
                forRelativePath: "Mixed/removed.txt",
                isDirectory: false
            )?.presentation,
            GitStatusPresentation(status: .modified, colorRole: .stagedModified)
        )
        XCTAssertNil(
            coordinator.explorerDecoration(
                forRelativePath: "Mixed",
                isDirectory: true
            ),
            "any entry with a deleted side must not create a ghost parent decoration"
        )

        let ignored = coordinator.explorerDecoration(
            forRelativePath: "Ignored/debug.log",
            isDirectory: false
        )
        XCTAssertEqual(ignored?.presentation.status, .ignored)
        XCTAssertNil(ignored?.badgeText)
        XCTAssertNil(
            coordinator.explorerDecoration(
                forRelativePath: "Ignored",
                isDirectory: true
            )
        )
        XCTAssertEqual(
            coordinator.explorerDecoration(
                forRelativePath: "Build",
                isDirectory: true
            ),
            .ignored
        )
    }

    func testSourceControlUsesGroupSpecificIndexAndWorktreeColors() {
        let changedOnBothSides = GitStatusEntry(
            path: "both.txt",
            shape: .ordinary(indexStatus: .modified, worktreeStatus: .deleted)
        )
        XCTAssertEqual(
            GitStatusPresentationIndex.sourceControlPresentation(
                for: changedOnBothSides,
                in: .stagedChanges
            ),
            GitStatusPresentation(status: .modified, colorRole: .stagedModified)
        )
        XCTAssertEqual(
            GitStatusPresentationIndex.sourceControlPresentation(
                for: changedOnBothSides,
                in: .changes
            ),
            GitStatusPresentation(status: .deleted, colorRole: .deleted)
        )

        let stagedDeletion = GitStatusEntry(
            path: "gone.txt",
            shape: .ordinary(indexStatus: .deleted, worktreeStatus: .unmodified)
        )
        XCTAssertEqual(
            GitStatusPresentationIndex.sourceControlPresentation(
                for: stagedDeletion,
                in: .stagedChanges
            )?.colorRole,
            .stagedDeleted
        )

        let coordinator = GitWorkspaceCoordinator(root: FileManager.default.temporaryDirectory)
        coordinator.applyTestSnapshot(
            GitStatusSnapshot(entries: [changedOnBothSides, stagedDeletion])
        )
        XCTAssertEqual(
            coordinator.explorerDecoration(
                forRelativePath: "gone.txt",
                isDirectory: false
            )?.presentation.colorRole,
            .stagedDeleted
        )

        let stagedOnlyModification = GitStatusEntry(
            path: "staged-modified.txt",
            shape: .ordinary(indexStatus: .modified, worktreeStatus: .unmodified)
        )
        coordinator.applyTestSnapshot(GitStatusSnapshot(entries: [stagedOnlyModification]))
        XCTAssertEqual(
            coordinator.explorerDecoration(
                forRelativePath: "staged-modified.txt",
                isDirectory: false
            )?.presentation.colorRole,
            .stagedModified
        )
    }

    func testRenameLookupIndexesBothCurrentAndOriginalPaths() throws {
        let coordinator = GitWorkspaceCoordinator(root: FileManager.default.temporaryDirectory)
        let renamed = GitStatusEntry(
            path: "new/name.swift",
            shape: .renameOrCopy(
                indexStatus: .renamed,
                worktreeStatus: .unmodified,
                similarityPercentage: 100,
                originalPath: "old/name.swift"
            )
        )
        coordinator.applyTestSnapshot(GitStatusSnapshot(entries: [renamed]))

        XCTAssertEqual(
            try XCTUnwrap(coordinator.statusEntry(forRelativePath: "new/name.swift")),
            renamed
        )
        XCTAssertEqual(
            try XCTUnwrap(coordinator.statusEntry(forRelativePath: "old/name.swift")),
            renamed
        )
    }
}
