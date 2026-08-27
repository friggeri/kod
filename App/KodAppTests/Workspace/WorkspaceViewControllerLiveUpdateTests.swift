import AppKit
import CryptoKit
import LanguageClient
import SearchCore
import SourceIO
import SourceModel
import WorkspaceCore
import XCTest
@testable import Kod

/// Headless (no window shown, no UI automation) coverage for the FSEvents-
/// driven live-update pipeline `WorkspaceViewController` wires together:
/// incremental Explorer/index updates, automatic reload of externally
/// modified open files, and tombstone tabs for files that disappear.
@MainActor
final class WorkspaceViewControllerLiveUpdateTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let controller: WorkspaceViewController
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let appFixture = try KodAppTestEnvironment.make(in: self)
        let identity = try WorkspaceIdentity(root: root)
        let controller = WorkspaceViewController(
            identity: identity,
            dependencies: appFixture.environment.makeWorkspaceDependencies()
        )
        _ = controller.view // triggers loadView(), building splitContainer etc.
        return Fixture(root: root, controller: controller)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw XCTSkip("condition not observed within \(timeout)s")
    }

    private func findView(identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier {
            return view
        }
        for subview in view.subviews {
            if let match = findView(identifier: identifier, in: subview) {
                return match
            }
        }
        return nil
    }

    private func awaitFilenameMatches(
        _ controller: WorkspaceViewController,
        _ query: String
    ) async throws -> [FilenameMatch] {
        // Filename-index appends happen on a detached Task from
        // handleChangedPath; give it a moment to land.
        for _ in 0..<50 {
            let matches = await controller.filenameIndex.search(query)
            if !matches.isEmpty {
                return matches
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return await controller.filenameIndex.search(query)
    }

    // MARK: - Direct dispatch (deterministic, no FSEvents timing dependency)

    func testRescanRequiredBatchRebuildsWorkspaceDiscovery() async throws {
        let fixture = try makeFixture()
        let fileURL = fixture.root.appendingPathComponent("rescanned.swift")
        try Data("let value = 1\n".utf8).write(to: fileURL)
        let group = try XCTUnwrap(
            fixture.controller.splitContainer.controller(
                for: fixture.controller.layoutState.activeGroupID
            )
        )
        group.openTab(
            relativePath: "rescanned.swift",
            pinned: true,
            snapshot: SourceSnapshot(
                text: "let value = 1\n",
                url: fileURL,
                version: 1
            )
        )
        try Data("let value = 2\n".utf8).write(to: fileURL)

        fixture.controller.handleWorkspaceChangeBatch(
            WorkspaceChangeBatch(
                paths: [],
                scope: .rescanRequired(
                    reasons: [.pendingPathLimitExceeded(limit: 8_192)]
                )
            )
        )

        try await waitUntil {
            (fixture.controller.entriesByParent[""] ?? []).contains {
                $0.relativePath == "rescanned.swift"
            }
        }
        try await waitUntil {
            group.currentDocumentController?.snapshot.text
                == "let value = 2\n"
        }
    }

    func testMissingInvalidatedRootSurfacesUnavailableDiscovery() throws {
        let fixture = try makeFixture()
        let fileURL = fixture.root.appendingPathComponent("removed.swift")
        try Data("let value = 1\n".utf8).write(to: fileURL)
        let group = try XCTUnwrap(
            fixture.controller.splitContainer.controller(
                for: fixture.controller.layoutState.activeGroupID
            )
        )
        group.openTab(
            relativePath: "removed.swift",
            pinned: true,
            snapshot: SourceSnapshot(
                text: "let value = 1\n",
                url: fileURL,
                version: 1
            )
        )
        try FileManager.default.removeItem(at: fixture.root)

        fixture.controller.handleWorkspaceChangeBatch(
            WorkspaceChangeBatch(paths: [], scope: .rootInvalidated)
        )

        XCTAssertEqual(
            fixture.controller.session.health.issue(for: .discovery)?.severity,
            .unavailable
        )
        XCTAssertTrue(
            fixture.controller.layoutState.groups[group.groupID]?
                .tabs.first?.isTombstoned ?? false
        )
    }

    func testHandleChangedPathTombstonesOpenTabWhenFileIsDeleted() throws {
        let fixture = try makeFixture()
        let fileURL = fixture.root.appendingPathComponent("a.txt")
        try Data("hello".utf8).write(to: fileURL)

        let controller = fixture.controller
        let group = try XCTUnwrap(controller.splitContainer.controller(for: controller.layoutState.activeGroupID))
        group.openTab(relativePath: "a.txt", pinned: true, snapshot: SourceSnapshot(text: "hello"))

        try FileManager.default.removeItem(at: fileURL)
        controller.handleChangedPath(fileURL.path)

        XCTAssertTrue(controller.layoutState.groups[group.groupID]?.tabs.first?.isTombstoned ?? false)
        XCTAssertNil(group.currentDocumentController)
    }

    func testHandleChangedPathReloadsOpenTabWhenFileIsModified() async throws {
        let fixture = try makeFixture()
        let fileURL = fixture.root.appendingPathComponent("a.txt")
        try Data("hello\n".utf8).write(to: fileURL)

        let controller = fixture.controller
        let group = try XCTUnwrap(controller.splitContainer.controller(for: controller.layoutState.activeGroupID))
        group.openTab(relativePath: "a.txt", pinned: true, snapshot: SourceSnapshot(text: "hello\n", version: 1))

        try Data("hello\nworld\n".utf8).write(to: fileURL)
        controller.handleChangedPath(fileURL.path)

        // The reload itself reads the file asynchronously (a detached
        // Task inside `reloadOpenTabsIfNeeded`), so wait for it to land
        // rather than asserting immediately.
        try await waitUntil {
            group.currentDocumentController?.snapshot.text == "hello\nworld\n"
        }
        XCTAssertGreaterThan(group.currentDocumentController?.snapshot.version ?? 0, 1)
        XCTAssertFalse(controller.layoutState.groups[group.groupID]?.tabs.first?.isTombstoned ?? true)
    }

    /// The multi-file regression: one FSEvents batch that changes several
    /// open files must reload *all* of them. A single shared reload task
    /// made each path cancel the previous one, so every tab but the last
    /// in the batch silently kept stale contents.
    func testOneBatchReloadsEveryChangedOpenFile() async throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        let group = try XCTUnwrap(
            controller.splitContainer.controller(
                for: controller.layoutState.activeGroupID
            )
        )
        let names = ["alpha.txt", "beta.txt", "gamma.txt"]
        var urls: [String: URL] = [:]
        for name in names {
            let url = fixture.root.appendingPathComponent(name)
            try Data("v1 \(name)\n".utf8).write(to: url)
            urls[name] = url
            group.openTab(
                relativePath: name,
                pinned: true,
                snapshot: SourceSnapshot(
                    text: "v1 \(name)\n",
                    url: url,
                    version: 1
                )
            )
        }
        for name in names {
            try Data("v2 \(name)\n".utf8)
                .write(to: try XCTUnwrap(urls[name]))
        }

        controller.handleWorkspaceChangeBatch(
            WorkspaceChangeBatch(
                paths: try names.map {
                    WorkspaceChangePath(
                        path: try XCTUnwrap(urls[$0]).path,
                        flags: .modified
                    )
                }
            )
        )
        await controller.session.waitForPendingWork()

        for name in names {
            // Re-selecting an already open tab keeps its live source
            // document, so this observes what the reload actually did.
            group.openTab(
                relativePath: name,
                pinned: true,
                snapshot: SourceSnapshot(
                    text: "v1 \(name)\n",
                    url: try XCTUnwrap(urls[name]),
                    version: 1
                )
            )
            let document = try XCTUnwrap(group.currentDocumentController)
            XCTAssertEqual(document.snapshot.text, "v2 \(name)\n")
            XCTAssertGreaterThan(document.snapshot.version, 1)
            XCTAssertFalse(
                controller.layoutState.groups[group.groupID]?.tabs
                    .first { $0.relativePath == name }?
                    .isTombstoned ?? true
            )
        }
    }

    /// A batch that changes one open file and deletes another must reload
    /// exactly one and tombstone exactly the other, in any order.
    func testOneBatchReloadsOneFileAndTombstonesAnother() async throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        let group = try XCTUnwrap(
            controller.splitContainer.controller(
                for: controller.layoutState.activeGroupID
            )
        )
        let keptURL = fixture.root.appendingPathComponent("kept.txt")
        let deletedURL = fixture.root.appendingPathComponent("deleted.txt")
        try Data("kept v1\n".utf8).write(to: keptURL)
        try Data("deleted v1\n".utf8).write(to: deletedURL)
        group.openTab(
            relativePath: "deleted.txt",
            pinned: true,
            snapshot: SourceSnapshot(
                text: "deleted v1\n",
                url: deletedURL,
                version: 1
            )
        )
        group.openTab(
            relativePath: "kept.txt",
            pinned: true,
            snapshot: SourceSnapshot(
                text: "kept v1\n",
                url: keptURL,
                version: 1
            )
        )

        try Data("kept v2\n".utf8).write(to: keptURL)
        try FileManager.default.removeItem(at: deletedURL)
        controller.handleWorkspaceChangeBatch(
            WorkspaceChangeBatch(
                paths: [
                    WorkspaceChangePath(path: deletedURL.path, flags: .removed),
                    WorkspaceChangePath(path: keptURL.path, flags: .modified)
                ]
            )
        )
        await controller.session.waitForPendingWork()

        let keptDocument = try XCTUnwrap(group.currentDocumentController)
        XCTAssertEqual(keptDocument.snapshot.text, "kept v2\n")
        XCTAssertGreaterThan(keptDocument.snapshot.version, 1)

        let tabs = try XCTUnwrap(
            controller.layoutState.groups[group.groupID]?.tabs
        )
        XCTAssertTrue(
            tabs.first { $0.relativePath == "deleted.txt" }?
                .isTombstoned ?? false
        )
        XCTAssertFalse(
            tabs.first { $0.relativePath == "kept.txt" }?
                .isTombstoned ?? true
        )
        XCTAssertTrue(
            controller.session.pathsWithExternalReloadInFlight.isEmpty
        )
    }

    /// A file deleted while its own reload is still in flight stays
    /// tombstoned: the in-flight read must not resurrect it.
    func testDeletionCancelsAnInFlightReloadForThatPath() async throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        let group = try XCTUnwrap(
            controller.splitContainer.controller(
                for: controller.layoutState.activeGroupID
            )
        )
        let fileURL = fixture.root.appendingPathComponent("racing.txt")
        try Data("racing v1\n".utf8).write(to: fileURL)
        group.openTab(
            relativePath: "racing.txt",
            pinned: true,
            snapshot: SourceSnapshot(
                text: "racing v1\n",
                url: fileURL,
                version: 1
            )
        )

        try Data("racing v2\n".utf8).write(to: fileURL)
        controller.handleChangedPath(fileURL.path)
        XCTAssertEqual(
            controller.session.pathsWithExternalReloadInFlight,
            ["racing.txt"]
        )
        try FileManager.default.removeItem(at: fileURL)
        controller.handleChangedPath(fileURL.path)
        await controller.session.waitForPendingWork()

        XCTAssertTrue(
            controller.layoutState.groups[group.groupID]?.tabs.first?
                .isTombstoned ?? false
        )
        XCTAssertTrue(
            controller.session.pathsWithExternalReloadInFlight.isEmpty
        )
    }

    /// Cancellation must reach the read itself, not just the awaiting
    /// caller. The unrestricted retry (the only read allowed above the
    /// safety limit) used to run in a detached task with no parent, so a
    /// closed tab kept paying for every remaining byte.
    func testCancellingAnApprovedOversizedLoadStopsTheUnrestrictedRead() async throws {
        let fixture = try makeFixture()
        let fileURL = fixture.root.appendingPathComponent("approved.log")
        try Data(repeating: 0x61, count: 11 * 1_024 * 1_024).write(to: fileURL)

        let controller = fixture.controller
        let group = try XCTUnwrap(
            controller.splitContainer.controller(
                for: controller.layoutState.activeGroupID
            )
        )
        let promptCount = PromptCounter()
        controller.oversizedFileLoadConfirmation = { _, _, _ in
            promptCount.increment()
            return true
        }

        let load = try XCTUnwrap(group.loadSnapshot)
        _ = try await load("approved.log")
        XCTAssertEqual(promptCount.value, 1)

        // Approval is already granted, so this goes straight to the
        // unrestricted read — with nothing left to ask the user.
        let cancelled = Task { @MainActor in try await load("approved.log") }
        cancelled.cancel()

        do {
            _ = try await cancelled.value
            XCTFail("a cancelled unrestricted read must not produce a snapshot")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(promptCount.value, 1)
    }

    func testExternalOversizedGrowthDoesNotPresentConsentUI() async throws {
        let fixture = try makeFixture()
        let fileURL = fixture.root.appendingPathComponent("growing.log")
        try Data("small\n".utf8).write(to: fileURL)

        let controller = fixture.controller
        let group = try XCTUnwrap(
            controller.splitContainer.controller(
                for: controller.layoutState.activeGroupID
            )
        )
        group.openTab(
            relativePath: "growing.log",
            pinned: true,
            snapshot: SourceSnapshot(
                text: "small\n",
                url: fileURL,
                version: 1
            )
        )
        var promptCount = 0
        controller.oversizedFileLoadConfirmation = { _, _, _ in
            promptCount += 1
            return true
        }
        try Data(
            repeating: 0x61,
            count: 11 * 1_024 * 1_024
        ).write(to: fileURL)

        controller.handleChangedPath(fileURL.path)
        await controller.session.waitForPendingWork()

        XCTAssertEqual(promptCount, 0)
        XCTAssertEqual(
            group.currentDocumentController?.snapshot.text,
            "small\n"
        )
        XCTAssertEqual(
            controller.session.health.issue(for: .discovery)?.severity,
            .degraded
        )
    }

    /// The user-initiated half of the oversized-file contract: opening a
    /// file above the safety limit asks once, and loads it only after the
    /// user says yes.
    func testUserInitiatedOversizedOpenAsksOnceThenLoads() async throws {
        let fixture = try makeFixture()
        let fileURL = fixture.root.appendingPathComponent("huge.log")
        let byteCount = 11 * 1_024 * 1_024
        try Data(repeating: 0x61, count: byteCount).write(to: fileURL)

        let controller = fixture.controller
        let group = try XCTUnwrap(
            controller.splitContainer.controller(
                for: controller.layoutState.activeGroupID
            )
        )
        var prompts: [(URL, Int, Int)] = []
        controller.oversizedFileLoadConfirmation = { url, size, limit in
            prompts.append((url, size, limit))
            return true
        }

        let load = try XCTUnwrap(group.loadSnapshot)
        let snapshot = try await load("huge.log")

        XCTAssertEqual(snapshot.originalData.count, byteCount)
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(prompts.first?.0.lastPathComponent, "huge.log")
        XCTAssertEqual(prompts.first?.1, byteCount)
        XCTAssertEqual(prompts.first?.2, 10 * 1_024 * 1_024)

        // The approval is remembered for that file, so an external change
        // to it reloads without asking again.
        _ = try await load("huge.log")
        XCTAssertEqual(prompts.count, 1)
    }

    func testDecliningAnOversizedOpenLoadsNothing() async throws {
        let fixture = try makeFixture()
        let fileURL = fixture.root.appendingPathComponent("declined.log")
        try Data(repeating: 0x61, count: 11 * 1_024 * 1_024).write(to: fileURL)

        let controller = fixture.controller
        let group = try XCTUnwrap(
            controller.splitContainer.controller(
                for: controller.layoutState.activeGroupID
            )
        )
        var promptCount = 0
        controller.oversizedFileLoadConfirmation = { _, _, _ in
            promptCount += 1
            return false
        }

        let load = try XCTUnwrap(group.loadSnapshot)
        do {
            _ = try await load("declined.log")
            XCTFail("declining must not produce a snapshot")
        } catch is CancellationError {
            // Expected: the open is abandoned, not reported as a failure.
        }

        XCTAssertEqual(promptCount, 1)
        XCTAssertTrue(controller.layoutState.groups.values.allSatisfy { $0.tabs.isEmpty })

        // Declining is not remembered as an approval: asking again asks
        // the user again.
        _ = try? await load("declined.log")
        XCTAssertEqual(promptCount, 2)
    }

    /// A superseded load (the user opened something else, or closed the
    /// tab) must never leave a modal question on screen for a file
    /// nobody is waiting for any more.
    func testCancelledOversizedLoadNeverAsksTheUser() async throws {
        let fixture = try makeFixture()
        let fileURL = fixture.root.appendingPathComponent("superseded.log")
        try Data(repeating: 0x61, count: 11 * 1_024 * 1_024).write(to: fileURL)

        let controller = fixture.controller
        let group = try XCTUnwrap(
            controller.splitContainer.controller(
                for: controller.layoutState.activeGroupID
            )
        )
        let promptCount = PromptCounter()
        controller.oversizedFileLoadConfirmation = { _, _, _ in
            promptCount.increment()
            return true
        }

        let load = try XCTUnwrap(group.loadSnapshot)
        let task = Task { @MainActor in
            try await load("superseded.log")
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("a cancelled load must not produce a snapshot")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(promptCount.value, 0)
    }

    /// Consent is for a *file*, not for a path. Deleting the approved file
    /// and writing a new one at the same path (a `git checkout`, a
    /// generator, a download) must ask again rather than silently loading
    /// something the user never saw a size for.
    func testReplacingAnApprovedOversizedFileAsksForConsentAgain() async throws {
        let fixture = try makeFixture()
        let fileURL = fixture.root.appendingPathComponent("replaced.log")
        let byteCount = 11 * 1_024 * 1_024
        try Data(repeating: 0x61, count: byteCount).write(to: fileURL)

        let controller = fixture.controller
        let group = try XCTUnwrap(
            controller.splitContainer.controller(
                for: controller.layoutState.activeGroupID
            )
        )
        let prompts = PromptCounter()
        controller.oversizedFileLoadConfirmation = { _, _, _ in
            prompts.increment()
            return true
        }

        let load = try XCTUnwrap(group.loadSnapshot)
        _ = try await load("replaced.log")
        XCTAssertEqual(prompts.value, 1)
        // The same file at the same size is still covered.
        _ = try await load("replaced.log")
        XCTAssertEqual(prompts.value, 1)

        // Same path, same size, different file.
        try FileManager.default.removeItem(at: fileURL)
        try Data(repeating: 0x62, count: byteCount).write(to: fileURL)

        let snapshot = try await load("replaced.log")

        XCTAssertEqual(
            prompts.value,
            2,
            "a replacement file must be approved on its own terms"
        )
        XCTAssertEqual(snapshot.originalData.first, 0x62)
    }

    /// The non-modal half of the same contract: a file that grew past the
    /// approved size is *not* reloaded behind the user's back, no sheet
    /// appears for a change they did not initiate, and the tab keeps the
    /// snapshot it already has with the reason stated in health.
    func testApprovedOversizedFileThatGrowsIsNotReloadedWithoutNewConsent() async throws {
        let fixture = try makeFixture()
        let fileURL = fixture.root.appendingPathComponent("appending.log")
        let approvedByteCount = 11 * 1_024 * 1_024
        try Data(repeating: 0x61, count: approvedByteCount).write(to: fileURL)

        let controller = fixture.controller
        let group = try XCTUnwrap(
            controller.splitContainer.controller(
                for: controller.layoutState.activeGroupID
            )
        )
        let prompts = PromptCounter()
        controller.oversizedFileLoadConfirmation = { _, _, _ in
            prompts.increment()
            return true
        }

        let load = try XCTUnwrap(group.loadSnapshot)
        let approved = try await load("appending.log")
        XCTAssertEqual(prompts.value, 1)
        group.openTab(
            relativePath: "appending.log",
            pinned: true,
            snapshot: approved
        )

        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0x62, count: 1_024))
        try handle.close()

        controller.handleChangedPath(fileURL.path)
        await controller.session.waitForPendingWork()

        XCTAssertEqual(
            prompts.value,
            1,
            "an external change must never raise a modal consent sheet"
        )
        XCTAssertEqual(
            group.currentDocumentController?.snapshot.originalData.count,
            approvedByteCount,
            "the tab must keep the snapshot the user approved"
        )
        let issue = try XCTUnwrap(
            controller.session.health.issue(for: .discovery)
        )
        XCTAssertEqual(issue.severity, .degraded)
        XCTAssertTrue(
            issue.reason.contains("no longer"),
            "health must say the approval stopped applying, not just that a reload was skipped: \(issue.reason)"
        )

        // Reopening is user-initiated, so it may ask again — and does.
        _ = try await load("appending.log")
        XCTAssertEqual(prompts.value, 2)
    }

    /// Deleting an approved file drops its approval outright, so a file
    /// later created at the same path starts from no consent at all.
    func testTombstoningAnApprovedPathDropsItsApproval() async throws {
        let fixture = try makeFixture()
        let fileURL = fixture.root.appendingPathComponent("recreated.log")
        let byteCount = 11 * 1_024 * 1_024
        try Data(repeating: 0x61, count: byteCount).write(to: fileURL)

        let controller = fixture.controller
        let group = try XCTUnwrap(
            controller.splitContainer.controller(
                for: controller.layoutState.activeGroupID
            )
        )
        let prompts = PromptCounter()
        controller.oversizedFileLoadConfirmation = { _, _, _ in
            prompts.increment()
            return true
        }

        let load = try XCTUnwrap(group.loadSnapshot)
        let snapshot = try await load("recreated.log")
        group.openTab(
            relativePath: "recreated.log",
            pinned: true,
            snapshot: snapshot
        )
        XCTAssertEqual(prompts.value, 1)

        try FileManager.default.removeItem(at: fileURL)
        controller.handleChangedPath(fileURL.path)
        await controller.session.waitForPendingWork()
        XCTAssertTrue(
            controller.layoutState.groups[group.groupID]?.tabs.first?
                .isTombstoned ?? false
        )

        try Data(repeating: 0x61, count: byteCount).write(to: fileURL)
        _ = try await load("recreated.log")

        XCTAssertEqual(prompts.value, 2)
    }

    // MARK: - Reads stop when the window does

    /// Closing the window has to reach the file handle, and shutdown has
    /// to *await* the read rather than orphan it — otherwise a multi-
    /// second load keeps running against a workspace that is gone and
    /// then opens a tab in it.
    func testClosingTheWindowCancelsAndAwaitsTheInFlightSourceLoad() async throws {
        let fixture = try makeFixture()
        let fileURL = fixture.root.appendingPathComponent("parked.txt")
        try Data("parked\n".utf8).write(to: fileURL)

        let controller = fixture.controller
        let group = try XCTUnwrap(
            controller.splitContainer.controller(
                for: controller.layoutState.activeGroupID
            )
        )
        let fileSystem = ParkedFileSystem()
        controller.readOnlyFileSystem = fileSystem

        let open = try XCTUnwrap(group.onOpenLocalRelativePath)
        open("parked.txt")
        await fileSystem.waitUntilReading()

        controller.prepareForWindowClose()
        await controller.session.shutdown()

        XCTAssertTrue(
            fileSystem.observedCancellation,
            "closing the window must cancel the read itself, not just its caller"
        )
        XCTAssertTrue(
            controller.layoutState.groups.values.allSatisfy { $0.tabs.isEmpty },
            "a cancelled load must not resurrect a tab after the window closed"
        )
        XCTAssertNil(group.currentDocumentController)
    }

    /// The preview-only fallback reads raw bytes through its own bounded,
    /// cancellation-chained loader; an abandoned preview read must stop
    /// too, and must not put a tab on screen afterwards.
    func testClosingTheWindowCancelsTheRawPreviewRead() async throws {
        let fixture = try makeFixture()
        let fileURL = fixture.root.appendingPathComponent("preview.png")
        // Not decodable as text, so opening falls through to the raw
        // preview path.
        try Data([0x89, 0x50, 0x4E, 0x47, 0xFF, 0xFE, 0xFD, 0xFC]).write(to: fileURL)

        let controller = fixture.controller
        let group = try XCTUnwrap(
            controller.splitContainer.controller(
                for: controller.layoutState.activeGroupID
            )
        )
        let fileSystem = ParkedFileSystem(failsTextDecoding: true)
        controller.readOnlyFileSystem = fileSystem

        controller.explorer.onIntent?(
            .openFile(
                WorkspaceFileEntry(
                    url: fileURL,
                    relativePath: "preview.png",
                    kind: .file,
                    isHidden: false,
                    isIgnored: false
                )
            )
        )
        await fileSystem.waitUntilReading()
        // The first read completes with undecodable bytes; the second is
        // the raw preview read, which is the one that parks.
        await fileSystem.waitUntilReading(callCount: 2)

        controller.prepareForWindowClose()
        await controller.session.shutdown()

        XCTAssertTrue(fileSystem.observedCancellation)
        XCTAssertTrue(
            controller.layoutState.groups.values.allSatisfy { $0.tabs.isEmpty }
        )
        XCTAssertNil(group.currentDocumentController)
    }

    // MARK: - Watcher survives a root that changes

    func testRootInvalidationRebuildsTheWatcherWhenTheRootStillExists() async throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        controller.session.startFileWatcherIfNeeded()
        XCTAssertTrue(controller.session.isWatchingFileSystem)

        controller.handleWorkspaceChangeBatch(
            WorkspaceChangeBatch(paths: [], scope: .rootInvalidated)
        )

        XCTAssertTrue(
            controller.session.isWatchingFileSystem,
            "a root that is still there must keep receiving live updates"
        )
        XCTAssertNil(controller.session.health.issue(for: .watcher))
        XCTAssertNil(controller.session.health.issue(for: .discovery))
    }

    func testMissingInvalidatedRootStopsTheWatcherExplicitly() throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        controller.session.startFileWatcherIfNeeded()
        XCTAssertTrue(controller.session.isWatchingFileSystem)

        try FileManager.default.removeItem(at: fixture.root)
        controller.handleWorkspaceChangeBatch(
            WorkspaceChangeBatch(paths: [], scope: .rootInvalidated)
        )

        XCTAssertFalse(controller.session.isWatchingFileSystem)
        XCTAssertEqual(
            controller.session.health.issue(for: .watcher)?.severity,
            .unavailable
        )
        XCTAssertEqual(
            controller.session.health.issue(for: .discovery)?.severity,
            .unavailable
        )
    }

    func testOpeningAFileUnderTheLimitNeverAsks() async throws {        let fixture = try makeFixture()
        let fileURL = fixture.root.appendingPathComponent("small.swift")
        try Data("let value = 1\n".utf8).write(to: fileURL)

        let controller = fixture.controller
        let group = try XCTUnwrap(
            controller.splitContainer.controller(
                for: controller.layoutState.activeGroupID
            )
        )
        var promptCount = 0
        controller.oversizedFileLoadConfirmation = { _, _, _ in
            promptCount += 1
            return true
        }

        let load = try XCTUnwrap(group.loadSnapshot)
        let snapshot = try await load("small.swift")

        XCTAssertEqual(snapshot.text, "let value = 1\n")
        XCTAssertEqual(promptCount, 0)
    }

    func testOpenedTypeScriptDocumentGetsHoverAndDefinitionHooks() throws {        let fixture = try makeFixture()
        let fileURL = fixture.root.appendingPathComponent("client.ts")
        let snapshot = SourceSnapshot(
            text: "export const client = api;\n",
            url: fileURL
        )
        let group = try XCTUnwrap(
            fixture.controller.splitContainer.controller(
                for: fixture.controller.layoutState.activeGroupID
            )
        )

        group.openTab(relativePath: "client.ts", pinned: true, snapshot: snapshot)
        let viewport = try XCTUnwrap(group.currentDocumentController?.viewport)
        XCTAssertNotNil(viewport.onCommandClick)
        XCTAssertNotNil(viewport.onHover)
        XCTAssertNotNil(viewport.onHoverExit)
    }

    func testOpeningFileRevealsAndSelectsItInExplorer() async throws {
        let fixture = try makeFixture()
        let directory = fixture.root.appendingPathComponent(
            "Sources/Feature",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileURL = directory.appendingPathComponent("Client.swift")
        try Data("let client = 1\n".utf8).write(to: fileURL)
        await fixture.controller.session.start()
        await fixture.controller.session.waitForPendingWork()
        let group = try XCTUnwrap(
            fixture.controller.splitContainer.controller(
                for: fixture.controller.layoutState.activeGroupID
            )
        )

        group.openTab(
            relativePath: "Sources/Feature/Client.swift",
            pinned: true,
            snapshot: SourceSnapshot(
                text: "let client = 1\n",
                url: fileURL
            )
        )
        await fixture.controller.session.waitForPendingWork()

        XCTAssertTrue(
            (fixture.controller.entriesByParent[""] ?? []).contains {
                $0.relativePath == "Sources"
            }
        )
        XCTAssertTrue(
            (fixture.controller.entriesByParent["Sources"] ?? []).contains {
                $0.relativePath == "Sources/Feature"
            }
        )
        XCTAssertTrue(
            (fixture.controller.entriesByParent["Sources/Feature"] ?? []).contains {
                $0.relativePath == "Sources/Feature/Client.swift"
            }
        )
        XCTAssertEqual(
            group.currentTabRelativePath,
            "Sources/Feature/Client.swift"
        )
        let selectedNode = fixture.controller.explorer.outlineView.item(
            atRow: fixture.controller.explorer.outlineView.selectedRow
        ) as? WorkspaceTreeNode
        XCTAssertEqual(
            selectedNode?.entry.relativePath,
            "Sources/Feature/Client.swift"
        )
    }

    func testLanguageServerControlsLiveInFullWidthBottomStatusBar() throws {
        let fixture = try makeFixture()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = fixture.controller
        window.layoutIfNeeded()

        let statusBar = try XCTUnwrap(
            findView(identifier: "workspace.statusBar", in: fixture.controller.view)
        )
        let languageServerButton = try XCTUnwrap(
            findView(
                identifier: "workspace.languageServerStatus",
                in: fixture.controller.view
            )
        )

        XCTAssertEqual(statusBar.frame.minX, fixture.controller.view.bounds.minX, accuracy: 0.5)
        XCTAssertEqual(statusBar.frame.width, fixture.controller.view.bounds.width, accuracy: 0.5)
        XCTAssertEqual(statusBar.frame.minY, fixture.controller.view.bounds.minY, accuracy: 0.5)
        XCTAssertTrue(languageServerButton.isDescendant(of: statusBar))
    }

    func testHandleChangedPathUpdatesExplorerIndexForNonOpenFiles() async throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        let newFile = fixture.root.appendingPathComponent("new.txt")
        try Data("content".utf8).write(to: newFile)

        controller.handleChangedPath(newFile.path)

        let entries = controller.entriesByParent[""] ?? []
        XCTAssertTrue(entries.contains { $0.relativePath == "new.txt" })

        let matches = try await awaitFilenameMatches(controller, "new.txt")
        XCTAssertTrue(matches.contains { $0.entry.relativePath == "new.txt" })
    }

    func testHandleChangedPathRemovesDeletedFileFromExplorerIndex() throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        let fileURL = fixture.root.appendingPathComponent("gone.txt")
        try Data("content".utf8).write(to: fileURL)
        controller.handleChangedPath(fileURL.path)
        XCTAssertTrue((controller.entriesByParent[""] ?? []).contains { $0.relativePath == "gone.txt" })
        let diagnostic = Diagnostic(
            range: LSPRange(
                start: LSPPosition(line: 0, character: 0),
                end: LSPPosition(line: 0, character: 1)
            ),
            severity: .warning,
            code: nil,
            source: nil,
            message: "Gone"
        )
        controller.multiLanguageServicesCoordinator.diagnosticsStore.replace(
            owner: "swift",
            resource: fileURL,
            diagnostics: [diagnostic]
        )
        controller.multiLanguageServicesCoordinator.diagnosticsStore.replace(
            owner: "typescript",
            resource: fileURL,
            diagnostics: [diagnostic]
        )

        try FileManager.default.removeItem(at: fileURL)
        controller.handleChangedPath(fileURL.path)

        XCTAssertFalse((controller.entriesByParent[""] ?? []).contains { $0.relativePath == "gone.txt" })
        XCTAssertNil(
            controller.multiLanguageServicesCoordinator.diagnosticsStore
                .snapshot.presentationDiagnosticsByFile[fileURL.standardizedFileURL]
        )
    }

    /// Problems stays bound to the raw workspace diagnostics store — it
    /// shows files that were never opened — while the coordinator's
    /// normalized callback only decorates open editors and never mutates
    /// that store.
    func testUnopenedDiagnosticsStayInTheStoreWhileNormalizedMarkersFeedEditorsOnly() throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        controller.viewDidAppear() // wires the language-services callbacks
        let diagnosticsStore = controller.multiLanguageServicesCoordinator.diagnosticsStore
        let unopenedURL = fixture.root.appendingPathComponent("Unopened.swift")
        let diagnostic = Diagnostic(
            range: LSPRange(
                start: LSPPosition(line: 0, character: 0),
                end: LSPPosition(line: 0, character: 3)
            ),
            severity: .error,
            code: nil,
            source: nil,
            message: "Unopened"
        )
        diagnosticsStore.replace(
            owner: "swift",
            resource: unopenedURL,
            diagnostics: [diagnostic]
        )
        XCTAssertEqual(
            diagnosticsStore.snapshot
                .presentationDiagnosticsByFile[unopenedURL.standardizedFileURL],
            [diagnostic]
        )

        let openedURL = fixture.root.appendingPathComponent("Open.swift")
        try Data("let value = 1\n".utf8).write(to: openedURL)
        let group = try XCTUnwrap(
            controller.splitContainer.controller(for: controller.layoutState.activeGroupID)
        )
        group.openTab(
            relativePath: "Open.swift",
            pinned: true,
            snapshot: SourceSnapshot(text: "let value = 1\n", url: openedURL, version: 1)
        )

        let normalizedCallback = try XCTUnwrap(
            controller.multiLanguageServicesCoordinator.onNormalizedDiagnostics,
            "Editor markers must be wired to the normalized callback"
        )
        normalizedCallback(openedURL, [
            NormalizedDiagnostic(
                snapshotVersion: 1,
                utf8Range: 0..<3,
                startLine: 0,
                severity: .warning,
                code: nil,
                source: nil,
                message: "Marker"
            )
        ])

        // Editor markers must never be mistaken for workspace problems.
        XCTAssertNil(
            diagnosticsStore.snapshot
                .presentationDiagnosticsByFile[openedURL.standardizedFileURL]
        )
        XCTAssertEqual(
            diagnosticsStore.snapshot
                .presentationDiagnosticsByFile[unopenedURL.standardizedFileURL],
            [diagnostic]
        )
    }

    func testIgnoredLiveUpdateDoesNotPopulateCollapsedDirectory() throws {
        let fixture = try makeFixture()
        try Data("data/\n".utf8).write(to: fixture.root.appendingPathComponent(".gitignore"))
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("data"),
            withIntermediateDirectories: true
        )
        let ignoredFile = fixture.root.appendingPathComponent("data/cache.json")
        try Data("{}".utf8).write(to: ignoredFile)

        fixture.controller.handleChangedPath(ignoredFile.path)
        XCTAssertFalse(
            (fixture.controller.entriesByParent["data"] ?? []).contains {
                $0.relativePath == "data/cache.json"
            }
        )
        XCTAssertTrue(fixture.controller.session.discoveryOptions.includeIgnored)
    }

    // MARK: - Real FSEvents end to end

    func testExternalWriteToOpenFileRefreshesWithinBudgetViaRealFSEvents() async throws {
        let fixture = try makeFixture()
        let fileURL = fixture.root.appendingPathComponent("live.txt")
        try Data("before\n".utf8).write(to: fileURL)

        let controller = fixture.controller
        controller.viewDidAppear() // starts discovery, then the real FSEvents watcher

        try await waitUntil {
            !(controller.entriesByParent[""] ?? []).isEmpty
        }

        let group = try XCTUnwrap(controller.splitContainer.controller(for: controller.layoutState.activeGroupID))
        group.openTab(relativePath: "live.txt", pinned: true, snapshot: SourceSnapshot(text: "before\n", version: 1))

        let start = ContinuousClock.now
        try Data("before\nafter\n".utf8).write(to: fileURL)

        try await waitUntil(timeout: 5) {
            group.currentDocumentController?.snapshot.text == "before\nafter\n"
        }
        let elapsed = ContinuousClock.now - start
        // SPEC 12.2: "External file write to visible refreshed snapshot <=
        // 500 ms after write burst settles". The coalescing window itself
        // (default 0.3s) is part of that budget.
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    // MARK: - Read-only invariant

    /// Records a SHA-256 manifest of the fixture workspace, exercises the
    /// full live-update workflow (discovery, search, open, external
    /// modify/reload, external delete/tombstone) with exactly one
    /// deliberate external write standing in for "the user editing the
    /// file in another app", and asserts that write is the *only* change
    /// Kod's own code paths ever produced in the workspace tree.
    func testWorkspaceTreeIsUntouchedExceptByTheDeliberateExternalWriter() async throws {
        let fixture = try makeFixture()
        try Data("original a\n".utf8).write(to: fixture.root.appendingPathComponent("a.txt"))
        try Data("original b\n".utf8).write(to: fixture.root.appendingPathComponent("b.txt"))
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("sub"),
            withIntermediateDirectories: true
        )
        try Data("original c\n".utf8).write(to: fixture.root.appendingPathComponent("sub/c.txt"))

        let beforeManifest = try manifest(of: fixture.root)

        let controller = fixture.controller
        controller.viewDidAppear()
        try await waitUntil {
            (controller.entriesByParent[""] ?? []).count >= 2
        }

        let group = try XCTUnwrap(controller.splitContainer.controller(for: controller.layoutState.activeGroupID))
        group.openTab(relativePath: "a.txt", pinned: true, snapshot: SourceSnapshot(text: "original a\n", version: 1))
        _ = group.currentDocumentController?.captureNavigationAnchor()

        // The one deliberate external write standing in for "the user
        // edited this file in another app" — everything else in the tree
        // must remain exactly as it was.
        let externalWriteURL = fixture.root.appendingPathComponent("a.txt")
        try Data("original a\nedited externally\n".utf8).write(to: externalWriteURL)
        controller.handleChangedPath(externalWriteURL.path)
        try await waitUntil {
            group.currentDocumentController?.snapshot.text == "original a\nedited externally\n"
        }

        // Also exercise the delete/tombstone path and a workspace search,
        // neither of which may write anything either.
        group.openTab(relativePath: "b.txt", pinned: true, snapshot: SourceSnapshot(text: "original b\n", version: 1))
        let deletedURL = fixture.root.appendingPathComponent("b.txt")
        try FileManager.default.removeItem(at: deletedURL)
        controller.handleChangedPath(deletedURL.path)

        let searcher = try WorkspaceTextSearcher()
        _ = try? await collectSearchEvents(searcher, SearchQuery(pattern: "original", root: fixture.root))

        let afterManifest = try manifest(of: fixture.root)

        var expectedManifest = beforeManifest
        expectedManifest["a.txt"] = try sha256(of: externalWriteURL)
        expectedManifest.removeValue(forKey: "b.txt")

        XCTAssertEqual(
            afterManifest,
            expectedManifest,
            "Kod must never write into the workspace beyond the deliberate external test writer's own change"
        )
    }

    private func manifest(of root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let resolvedRootPath = root.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return result
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                continue
            }
            // Both `root` and the enumerated URL are resolved through any
            // symlinks (e.g. /tmp -> /private/tmp) before computing the
            // relative path, so the manifest keys are stable regardless of
            // which unresolved form happened to be used to construct
            // either URL.
            let resolvedPath = url.resolvingSymlinksInPath().path
            guard resolvedPath.hasPrefix(resolvedRootPath + "/") else {
                continue
            }
            let relativePath = String(resolvedPath.dropFirst(resolvedRootPath.count + 1))
            result[relativePath] = try sha256(of: url)
        }
        return result
    }

    private func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func collectSearchEvents(
        _ searcher: WorkspaceTextSearcher,
        _ query: SearchQuery
    ) async throws -> [SearchStreamEvent] {
        var events: [SearchStreamEvent] = []
        for try await event in await searcher.search(query) {
            events.append(event)
        }
        return events
    }
}

/// A counter the oversized-consent hook can bump from whichever isolation
/// domain the load happens to be on.
private final class PromptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// A file system whose reads park until they are cancelled, so "closing
/// the window stops the read" is an assertion about an observed
/// cancellation instead of a race against a file large enough to still be
/// loading when the test gets there.
///
/// The park is bounded by a deadline so a regression fails the test rather
/// than hanging it.
private final class ParkedFileSystem: ReadOnlyFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private let failsTextDecoding: Bool
    private var reads = 0
    private var cancelled = false
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(failsTextDecoding: Bool = false) {
        self.failsTextDecoding = failsTextDecoding
    }

    var observedCancellation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    func waitUntilReading(callCount: Int = 1) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if reads >= callCount {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append((callCount, continuation))
            lock.unlock()
        }
    }

    func metadata(at url: URL) throws -> ReadOnlyFileMetadata? {
        ReadOnlyFileMetadata(byteCount: 8, modificationDate: nil, identity: nil)
    }

    func readFile(at url: URL) throws -> ReadOnlyFilePayload {
        noteRead()
        // The first read of an undecodable file has to *finish* so the
        // open falls through to the raw preview path; the parked read is
        // the one after it.
        if failsTextDecoding, readCount == 1 {
            return ReadOnlyFilePayload(
                data: Data([0x89, 0x50, 0x4E, 0x47, 0xFF, 0xFE, 0xFD, 0xFC]),
                modificationDate: nil
            )
        }
        let deadline = Date().addingTimeInterval(10)
        while !Task.isCancelled, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        if Task.isCancelled {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
        try Task.checkCancellation()
        return ReadOnlyFilePayload(data: Data("parked\n".utf8), modificationDate: nil)
    }

    private func noteRead() {
        lock.lock()
        reads += 1
        let current = reads
        let ready = waiters.filter { $0.count <= current }
        waiters.removeAll { $0.count <= current }
        lock.unlock()
        ready.forEach { $0.continuation.resume() }
    }
}
