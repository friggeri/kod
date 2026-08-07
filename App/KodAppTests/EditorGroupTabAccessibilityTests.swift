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
        XCTAssertTrue(closeA.isHidden)
        XCTAssertTrue(closeOther.isHidden)
        XCTAssertFalse(try XCTUnwrap(findView(identifier: "tab.icon.src/a.txt", in: controller.view)).isHidden)
        XCTAssertFalse(try XCTUnwrap(findView(identifier: "tab.icon.src/other.txt", in: controller.view)).isHidden)
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

    func testEveryTabTitleSelectsItsOwnFile() throws {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)
        controller.openTab(relativePath: "src/first.txt", pinned: true, snapshot: SourceSnapshot(text: "first"))
        controller.openTab(relativePath: "src/second.txt", pinned: true, snapshot: SourceSnapshot(text: "second"))
        controller.openTab(relativePath: "src/third.txt", pinned: true, snapshot: SourceSnapshot(text: "third"))
        controller.view.layoutSubtreeIfNeeded()

        for (path, expectedText) in [
            ("src/first.txt", "first"),
            ("src/second.txt", "second"),
            ("src/third.txt", "third")
        ] {
            let button = try XCTUnwrap(
                findView(identifier: "tab.title.\(path)", in: controller.view) as? NSButton
            )
            button.sendAction(button.action, to: button.target)

            let selectedPath = controller.state.tabs.first {
                $0.id == controller.state.selectedTabID
            }?.relativePath
            XCTAssertEqual(selectedPath, path)
            XCTAssertEqual(controller.currentDocumentController?.snapshot.text, expectedText)
        }
    }

    func testTabItemsHaveStableWidthsRegardlessOfFileName() throws {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)
        controller.openTab(relativePath: "a.swift", pinned: true, snapshot: SourceSnapshot(text: "a"))
        controller.openTab(
            relativePath: "a-very-long-file-name-that-needs-truncation.swift",
            pinned: true,
            snapshot: SourceSnapshot(text: "b")
        )
        controller.openTab(relativePath: "mid.swift", pinned: true, snapshot: SourceSnapshot(text: "c"))
        controller.view.window?.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        let widths = try [
            "tab.a.swift",
            "tab.a-very-long-file-name-that-needs-truncation.swift",
            "tab.mid.swift"
        ].map {
            try XCTUnwrap(findView(identifier: $0, in: controller.view)).frame.width
        }
        XCTAssertGreaterThan(widths[0], 100)
        XCTAssertEqual(widths[0], widths[1], accuracy: 0.5)
        XCTAssertEqual(widths[1], widths[2], accuracy: 0.5)
    }

    func testTabContentsAreCenteredAndTitlesPassMouseHitsThroughForDragging() throws {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)
        controller.openTab(relativePath: "pinned.swift", pinned: true, snapshot: SourceSnapshot(text: "a"))
        controller.openTab(relativePath: "preview.swift", pinned: false, snapshot: SourceSnapshot(text: "b"))
        controller.view.window?.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        for path in ["pinned.swift", "preview.swift"] {
            let tabView = try XCTUnwrap(findView(identifier: "tab.\(path)", in: controller.view))
            let titleButton = try XCTUnwrap(
                findView(identifier: "tab.title.\(path)", in: controller.view) as? NSButton
            )
            let tabContent = try XCTUnwrap(findView(identifier: "tab.content.\(path)", in: controller.view))
            let contentCenter = tabContent.convert(
                NSPoint(x: tabContent.bounds.midX, y: tabContent.bounds.midY),
                to: tabView
            )
            let tabSuperview = try XCTUnwrap(tabView.superview)
            let titleCenterInTabSuperview = titleButton.convert(
                NSPoint(x: titleButton.bounds.midX, y: titleButton.bounds.midY),
                to: tabSuperview
            )
            let titleCenterInTitleSuperview = titleButton.convert(
                NSPoint(x: titleButton.bounds.midX, y: titleButton.bounds.midY),
                to: try XCTUnwrap(titleButton.superview)
            )

            XCTAssertEqual(contentCenter.x, tabView.bounds.midX, accuracy: 0.5)
            XCTAssertNil(titleButton.hitTest(titleCenterInTitleSuperview))
            XCTAssertTrue(tabView.hitTest(titleCenterInTabSuperview) === tabView)
        }
    }

    func testTabsFillTheAvailableBarWidth() throws {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)
        for path in ["first.swift", "second.swift", "third.swift"] {
            controller.openTab(relativePath: path, pinned: true, snapshot: SourceSnapshot(text: path))
        }
        controller.view.window?.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        let tabBar = try XCTUnwrap(findView(identifier: "editorGroup.tabBar", in: controller.view))
        let totalTabWidth = try ["first.swift", "second.swift", "third.swift"].reduce(CGFloat.zero) {
            $0 + (try XCTUnwrap(findView(identifier: "tab.\($1)", in: controller.view))).frame.width
        }

        XCTAssertEqual(totalTabWidth + 16, tabBar.bounds.width, accuracy: 2)
    }

    func testCloseButtonUsesFixedLeadingOverlayWithoutMovingContent() throws {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)
        controller.openTab(relativePath: "centered.swift", pinned: true, snapshot: SourceSnapshot(text: "a"))
        controller.view.window?.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        let tabView = try XCTUnwrap(findView(identifier: "tab.centered.swift", in: controller.view))
        let contentView = try XCTUnwrap(findView(identifier: "tab.content.centered.swift", in: controller.view))
        let closeButton = try XCTUnwrap(
            findView(identifier: "tab.close.centered.swift", in: controller.view) as? NSButton
        )
        let originalContentFrame = contentView.frame
        let closeFrame = closeButton.convert(closeButton.bounds, to: tabView)

        XCTAssertEqual(closeFrame.minX, 7, accuracy: 0.5)
        XCTAssertEqual(closeFrame.midY, tabView.bounds.midY, accuracy: 0.5)
        XCTAssertTrue(closeButton.isHidden)

        closeButton.isHidden = false
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(contentView.frame, originalContentFrame)
    }

    func testPaneActivationMonitorReturnsControlClicksUnchanged() throws {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        controller.isOnlyGroup = false
        host(controller)
        controller.openTab(relativePath: "src/a.txt", pinned: true, snapshot: SourceSnapshot(text: "hello"))
        controller.view.layoutSubtreeIfNeeded()

        var activatedGroupID: EditorGroupID?
        var closedGroupID: EditorGroupID?
        controller.onActivate = { activatedGroupID = $0 }
        controller.onCloseGroup = { closedGroupID = $0 }

        let closeGroupButton = try XCTUnwrap(
            findView(identifier: "editorGroup.closeGroup", in: controller.view) as? NSButton
        )
        let closeTabButton = try XCTUnwrap(
            findView(identifier: "tab.close.src/a.txt", in: controller.view) as? NSButton
        )
        let window = try XCTUnwrap(controller.view.window)

        XCTAssertTrue(controller.view.gestureRecognizers.isEmpty)
        for button in [closeGroupButton, closeTabButton] {
            let event = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: button.convert(
                        NSPoint(x: button.bounds.midX, y: button.bounds.midY),
                        to: nil
                    ),
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                )
            )
            XCTAssertTrue(controller.processActivationMouseDown(event) === event)
            XCTAssertEqual(activatedGroupID, controller.groupID)
            activatedGroupID = nil
        }

        closeGroupButton.sendAction(closeGroupButton.action, to: closeGroupButton.target)
        XCTAssertEqual(activatedGroupID, controller.groupID)
        XCTAssertEqual(closedGroupID, controller.groupID)

        activatedGroupID = nil
        closeTabButton.sendAction(closeTabButton.action, to: closeTabButton.target)
        XCTAssertEqual(activatedGroupID, controller.groupID)
        XCTAssertTrue(controller.state.tabs.isEmpty)
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
