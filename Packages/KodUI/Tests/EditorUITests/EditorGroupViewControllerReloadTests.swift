import AppKit
import SourceModel
import WorkspaceCore
import XCTest
@testable import EditorUI

/// Headless coverage for Phase 5's external-reload and tombstone behavior
/// in `EditorGroupViewController`. These tests construct view controllers
/// and call their methods directly without ever creating a window or
/// driving real mouse/keyboard input — no UI automation is launched here,
/// consistent with `Scripts/verify-phase`'s permanent restriction to
/// headless package/AppKit unit tests.
@MainActor
final class EditorGroupViewControllerReloadTests: XCTestCase {
    /// Off-screen test windows must stay alive for the geometry (scroll
    /// offsets, visible rects) that navigation-anchor capture/restore
    /// depends on to be real — mirrors `CodeDocumentViewControllerTests`'
    /// established pattern. Never shown/made key; this is not UI automation.
    private var windows: [NSWindow] = []

    private func host(_ controller: EditorGroupViewController) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 800, height: 600))
        window.layoutIfNeeded()
        windows.append(window)
    }

    func testReloadTabPreservesReconciledSelectionAndBumpsVersion() throws {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)
        // Long enough that scrolling to the target line is a real,
        // measurable scroll (a handful of lines all fit within the test
        // window without scrolling at all, which would make the
        // `viewportAnchorLine` round trip trivially pass at 0 regardless
        // of what's requested).
        var lines = (0..<200).map { "line \($0)\n" }
        lines[100] = "beta\n"
        let originalSnapshot = SourceSnapshot(text: lines.joined(), version: 1)
        controller.openTab(relativePath: "a.txt", pinned: true, snapshot: originalSnapshot)
        controller.view.window?.layoutIfNeeded()
        controller.currentDocumentController?.view.layoutSubtreeIfNeeded()

        let betaRange = try XCTUnwrap(originalSnapshot.utf8RangeForLine(100))
        controller.currentDocumentController?.restoreNavigationAnchor(
            selection: betaRange,
            viewportAnchorLine: 100
        )
        // Sanity-check the round trip on the *original* controller before
        // reloading, to isolate whether a mismatch comes from the reload
        // path itself or from test-harness view layout timing.
        XCTAssertEqual(controller.currentDocumentController?.captureNavigationAnchor().viewportAnchorLine, 100)

        // A line was inserted before "beta" (at what was line 100) — the
        // reload must still land the selection on "beta" itself, not on
        // whatever now occupies line 100 by coincidence.
        var newLines = lines
        newLines.insert("NEW\n", at: 100)
        let newSnapshot = SourceSnapshot(text: newLines.joined(), version: 2)
        controller.reloadTab(relativePath: "a.txt", with: newSnapshot)
        controller.view.window?.layoutIfNeeded()

        let reloaded = try XCTUnwrap(controller.currentDocumentController)
        XCTAssertEqual(reloaded.snapshot.version, 2)
        let anchor = reloaded.captureNavigationAnchor()
        let selection = try XCTUnwrap(anchor.selection)
        XCTAssertEqual(try newSnapshot.text(inUTF8Range: selection), "beta")
        XCTAssertEqual(anchor.viewportAnchorLine, 101)
    }

    func testReloadTabIsNoOpWhenPathIsNotOpen() {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)
        controller.openTab(relativePath: "a.txt", pinned: true, snapshot: SourceSnapshot(text: "hello"))

        controller.reloadTab(relativePath: "unrelated.txt", with: SourceSnapshot(text: "goodbye", version: 2))

        XCTAssertEqual(controller.currentDocumentController?.snapshot.text, "hello")
    }

    func testMarkTombstonedReplacesShownContentAndClearRestoresIt() {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)
        controller.openTab(relativePath: "a.txt", pinned: true, snapshot: SourceSnapshot(text: "hello"))
        XCTAssertNotNil(controller.currentDocumentController)

        controller.markTombstoned(relativePath: "a.txt", reason: .missing)

        XCTAssertTrue(controller.state.tabs.first?.isTombstoned ?? false)
        XCTAssertEqual(controller.state.tabs.first?.tombstoneReason, .missing)
        XCTAssertNil(controller.currentDocumentController, "tombstoned content must not keep showing stale code")

        controller.clearTombstone(relativePath: "a.txt")

        XCTAssertFalse(controller.state.tabs.first?.isTombstoned ?? true)
    }

    func testOpenTabWithSelectionSelectsTheRequestedRange() throws {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)
        let snapshot = SourceSnapshot(text: "needle here\nsecond line\n")
        let range = try XCTUnwrap(snapshot.utf8RangeForLine(0))

        controller.openTab(
            relativePath: "a.txt",
            pinned: true,
            snapshot: snapshot,
            selectingUTF8Range: range
        )

        let anchor = controller.currentDocumentController?.captureNavigationAnchor()
        XCTAssertEqual(anchor?.selection, range)
        XCTAssertEqual(anchor?.viewportAnchorLine, 0)
    }

    // MARK: - Document lifecycle reporting

    /// Closing a tab permanently discards its source content, so the
    /// owning workspace must be told — that is what lets the language
    /// services coordinator close the document on the server.
    func testClosingATabReportsItsDocumentClosed() throws {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)
        controller.openTab(relativePath: "a.txt", pinned: true, snapshot: SourceSnapshot(text: "hello"))
        let document = try XCTUnwrap(controller.currentDocumentController)
        let tabID = try XCTUnwrap(controller.state.selectedTabID)
        var closed: [(path: String, id: ObjectIdentifier)] = []
        controller.onDocumentClosed = { path, documentController in
            closed.append((path: path, id: ObjectIdentifier(documentController)))
        }

        controller.closeTab(tabID)

        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed.first?.path, "a.txt")
        XCTAssertEqual(closed.first?.id, ObjectIdentifier(document))
    }

    /// Tombstoning replaces live content with a placeholder, which is a
    /// permanent discard of the source controller.
    func testTombstoningReportsItsDocumentClosed() throws {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)
        controller.openTab(relativePath: "a.txt", pinned: true, snapshot: SourceSnapshot(text: "hello"))
        let document = try XCTUnwrap(controller.currentDocumentController)
        var closed: [(path: String, id: ObjectIdentifier)] = []
        controller.onDocumentClosed = { path, documentController in
            closed.append((path: path, id: ObjectIdentifier(documentController)))
        }

        controller.markTombstoned(relativePath: "a.txt", reason: .missing)

        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed.first?.path, "a.txt")
        XCTAssertEqual(closed.first?.id, ObjectIdentifier(document))
    }

    /// Reusing the unpinned preview tab for another file discards the
    /// previous file's controller: the close must be reported under the
    /// path that controller was actually showing, not the new one.
    func testReusingThePreviewTabReportsThePreviousDocumentClosed() throws {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)
        controller.openTab(relativePath: "a.txt", pinned: false, snapshot: SourceSnapshot(text: "hello"))
        let document = try XCTUnwrap(controller.currentDocumentController)
        var closed: [(path: String, id: ObjectIdentifier)] = []
        controller.onDocumentClosed = { path, documentController in
            closed.append((path: path, id: ObjectIdentifier(documentController)))
        }

        controller.openTab(relativePath: "b.txt", pinned: false, snapshot: SourceSnapshot(text: "goodbye"))

        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed.first?.path, "a.txt")
        XCTAssertEqual(closed.first?.id, ObjectIdentifier(document))
    }

    /// A reload keeps the same file open with a new version. The
    /// replacement must be announced *before* the superseded controller is
    /// reported closed, so the language service never sees the document
    /// drop to zero live panes and churn through didClose/didOpen.
    func testReloadReportsTheReplacementBeforeTheSupersededDocument() throws {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)
        controller.openTab(relativePath: "a.txt", pinned: true, snapshot: SourceSnapshot(text: "hello"))
        let original = try XCTUnwrap(controller.currentDocumentController)
        var events: [(kind: String, id: ObjectIdentifier)] = []
        controller.onDocumentReady = { _, documentController in
            events.append((kind: "ready", id: ObjectIdentifier(documentController)))
        }
        controller.onDocumentClosed = { _, documentController in
            events.append((kind: "closed", id: ObjectIdentifier(documentController)))
        }

        controller.reloadTab(
            relativePath: "a.txt",
            with: SourceSnapshot(text: "hello there", version: 2)
        )

        let replacement = try XCTUnwrap(controller.currentDocumentController)
        XCTAssertEqual(events.map { $0.kind }, ["ready", "closed"])
        XCTAssertEqual(events.first?.id, ObjectIdentifier(replacement))
        XCTAssertEqual(events.last?.id, ObjectIdentifier(original))
    }

    /// Dragging a tab into another group moves the *same* live controller:
    /// nothing is discarded, so there must be no close and no re-open —
    /// the language service keeps the document open untouched.
    func testTransferringATabBetweenGroupsReportsNoCloseOrReopen() throws {
        let source = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        let target = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(source)
        host(target)
        source.openTab(relativePath: "a.txt", pinned: true, snapshot: SourceSnapshot(text: "hello"))
        let document = try XCTUnwrap(source.currentDocumentController)
        let tabID = try XCTUnwrap(source.state.selectedTabID)
        var events: [String] = []
        source.onDocumentClosed = { _, _ in events.append("source.closed") }
        source.onDocumentReady = { _, _ in events.append("source.ready") }
        target.onDocumentClosed = { _, _ in events.append("target.closed") }
        target.onDocumentReady = { _, _ in events.append("target.ready") }

        let payload = try XCTUnwrap(source.detachTabForTransfer(tabID))
        target.insertTransferredTab(payload, at: 0)

        XCTAssertTrue(events.isEmpty, "A live transfer is not a close/open: \(events)")
        XCTAssertTrue(target.currentDocumentController === document)
        XCTAssertNil(source.currentDocumentController)
    }

    /// A group removed from the split tree takes its documents with it.
    /// `deinit` is nonisolated and cannot report them, so the workspace
    /// asks the group to do it while its wiring is still alive.
    func testPreparingForRemovalReportsEveryRemainingDocumentClosed() {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)
        controller.openTab(relativePath: "a.txt", pinned: true, snapshot: SourceSnapshot(text: "hello"))
        controller.openTab(relativePath: "b.txt", pinned: true, snapshot: SourceSnapshot(text: "goodbye"))
        var closedPaths: [String] = []
        controller.onDocumentClosed = { path, _ in closedPaths.append(path) }

        controller.prepareForRemovalFromWorkspace()

        XCTAssertEqual(Set(closedPaths), ["a.txt", "b.txt"])
        XCTAssertNil(controller.currentDocumentController)
    }
}