import AppKit
import SourceModel
import WorkspaceCore
import XCTest
@testable import Kod

/// Headless coverage for SPEC 14's tab-bar and active-split-group
/// accessibility requirements: each tab chip needs a label (file name)
/// and a value/state for pinned vs. preview vs. tombstoned, the close
/// button needs its own per-tab accessible name, and the active split
/// group must be accessibly distinguishable from an inactive one — not
/// only via the visual highlight. No window is shown/made key; this is
/// not UI automation (mirrors `EditorGroupViewControllerReloadTests`'
/// established off-screen-window pattern).
@MainActor
final class EditorGroupTabAccessibilityTests: XCTestCase {
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

    /// Depth-first search for a subview whose `identifier` exactly
    /// matches `identifier`, starting from `view` itself.
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

    // MARK: - editorTabAccessibilityValue (pure)

    func testAccessibilityValuePureFunctionCoversAllStateCombinations() {
        let pinned = EditorTab(relativePath: "a.txt", isPinned: true)
        let preview = EditorTab(relativePath: "b.txt", isPinned: false)
        var tombstonedPinned = pinned
        tombstonedPinned.tombstoneReason = .missing

        XCTAssertEqual(editorTabAccessibilityValue(tab: pinned, isSelected: false), "Pinned tab")
        XCTAssertEqual(editorTabAccessibilityValue(tab: pinned, isSelected: true), "Selected, Pinned tab")
        XCTAssertEqual(editorTabAccessibilityValue(tab: preview, isSelected: false), "Preview tab")
        XCTAssertEqual(editorTabAccessibilityValue(tab: preview, isSelected: true), "Selected, Preview tab")
        XCTAssertEqual(
            editorTabAccessibilityValue(tab: tombstonedPinned, isSelected: false),
            "Unavailable, Pinned tab"
        )
        XCTAssertEqual(
            editorTabAccessibilityValue(tab: tombstonedPinned, isSelected: true),
            "Selected, Unavailable, Pinned tab"
        )
    }

    // MARK: - Real chip view wiring

    func testPinnedTabChipHasFileNameLabelAndPinnedValue() throws {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)
        controller.openTab(relativePath: "src/a.txt", pinned: true, snapshot: SourceSnapshot(text: "hello"))
        controller.view.layoutSubtreeIfNeeded()

        let titleButton = try XCTUnwrap(findView(identifier: "tab.title.src/a.txt", in: controller.view) as? NSButton)
        XCTAssertEqual(titleButton.accessibilityLabel(), "a.txt")
        XCTAssertEqual(titleButton.accessibilityValue() as? String, "Selected, Pinned tab")
    }

    func testPreviewTabChipShowsPreviewValueAndHasPinButton() throws {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)
        controller.openTab(relativePath: "src/b.txt", pinned: false, snapshot: SourceSnapshot(text: "hello"))
        controller.view.layoutSubtreeIfNeeded()

        let titleButton = try XCTUnwrap(findView(identifier: "tab.title.src/b.txt", in: controller.view) as? NSButton)
        XCTAssertEqual(titleButton.accessibilityValue() as? String, "Selected, Preview tab")

        let pinButton = try XCTUnwrap(findView(identifier: "tab.pin.src/b.txt", in: controller.view) as? NSButton)
        XCTAssertEqual(pinButton.accessibilityLabel(), "Pin b.txt")
    }

    func testCloseButtonHasPerTabAccessibleName() throws {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)
        controller.openTab(relativePath: "src/a.txt", pinned: true, snapshot: SourceSnapshot(text: "hello"))
        controller.openTab(relativePath: "src/other.txt", pinned: true, snapshot: SourceSnapshot(text: "hello"))
        controller.view.layoutSubtreeIfNeeded()

        let closeA = try XCTUnwrap(findView(identifier: "tab.close.src/a.txt", in: controller.view) as? NSButton)
        let closeOther = try XCTUnwrap(findView(identifier: "tab.close.src/other.txt", in: controller.view) as? NSButton)
        XCTAssertEqual(closeA.accessibilityLabel(), "Close a.txt")
        XCTAssertEqual(closeOther.accessibilityLabel(), "Close other.txt")
        XCTAssertNotEqual(closeA.accessibilityLabel(), closeOther.accessibilityLabel())
    }

    func testTombstonedTabValueIncludesUnavailable() throws {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)
        controller.openTab(relativePath: "src/a.txt", pinned: true, snapshot: SourceSnapshot(text: "hello"))
        controller.markTombstoned(relativePath: "src/a.txt", reason: .missing)
        controller.view.layoutSubtreeIfNeeded()

        let titleButton = try XCTUnwrap(findView(identifier: "tab.title.src/a.txt", in: controller.view) as? NSButton)
        let value = try XCTUnwrap(titleButton.accessibilityValue() as? String)
        XCTAssertTrue(value.contains("Unavailable"))
    }

    // MARK: - Active split group (SplitContainerViewController-adjacent)

    func testActiveEditorGroupHasDistinctAccessibilityValueFromInactive() {
        let active = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        let inactive = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(active)
        host(inactive)

        // Both default to `isActive == true` until a coordinator (in
        // production, `WorkspaceViewController.refreshActiveGroupHighlighting()`)
        // tells them otherwise — mirrors how a freshly-created lone group
        // starts out active.
        XCTAssertEqual(active.view.accessibilityValue() as? String, "Active editor group")

        inactive.isActive = false
        XCTAssertEqual(inactive.view.accessibilityValue() as? String, "Inactive editor group")
        XCTAssertNotEqual(active.view.accessibilityValue() as? String, inactive.view.accessibilityValue() as? String)
    }
}
