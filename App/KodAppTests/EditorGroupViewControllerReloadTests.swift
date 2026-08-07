import AppKit
import SourceModel
import WorkspaceCore
import XCTest
@testable import Kod

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
}