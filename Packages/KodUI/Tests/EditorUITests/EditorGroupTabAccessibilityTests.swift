import AppKit
import SourceModel
import WorkspaceCore
import XCTest
@testable import EditorUI

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

    private func hostSideBySide(
        _ first: EditorGroupViewController,
        _ second: EditorGroupViewController
    ) {
        let root = NSViewController()
        root.view = NSView()
        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        root.addChild(first)
        root.addChild(second)
        splitView.addArrangedSubview(first.view)
        splitView.addArrangedSubview(second.view)
        root.view.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: root.view.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: root.view.bottomAnchor)
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = root
        window.setContentSize(NSSize(width: 900, height: 600))
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        splitView.setPosition(450, ofDividerAt: 0)
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
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
        XCTAssertEqual(
            titleButton.accessibilityCustomActions()?.map(\.name),
            ["Pin b.txt"]
        )

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
        let tabRail = try XCTUnwrap(findView(identifier: "editorGroup.tabRail", in: controller.view))
        let selectedTabBackground = try XCTUnwrap(
            findView(
                identifier: "tab.background.third.swift",
                in: controller.view
            ) as? NSVisualEffectView
        )
        let tabCollection = try XCTUnwrap(
            findView(identifier: "editorGroup.tabCollection", in: controller.view) as? NSCollectionView
        )
        let totalTabWidth = try ["first.swift", "second.swift", "third.swift"].reduce(CGFloat.zero) {
            $0 + (try XCTUnwrap(findView(identifier: "tab.\($1)", in: controller.view))).frame.width
        }

        XCTAssertEqual(totalTabWidth + 16, tabBar.bounds.width, accuracy: 2)
        XCTAssertEqual(tabRail.layer?.cornerRadius, 16)
        XCTAssertGreaterThan(tabRail.layer?.backgroundColor?.alpha ?? 0, 0)
        XCTAssertEqual(tabRail.layer?.borderWidth, 0)
        XCTAssertFalse(selectedTabBackground.isHidden)
        XCTAssertEqual(selectedTabBackground.material, .windowBackground)
        XCTAssertEqual(selectedTabBackground.blendingMode, .behindWindow)
        XCTAssertEqual(selectedTabBackground.layer?.borderWidth, 0)
        XCTAssertGreaterThan(selectedTabBackground.layer?.shadowOpacity ?? 0, 0)
        XCTAssertEqual(tabRail.frame.minX, 8, accuracy: 0.5)
        XCTAssertEqual(tabRail.frame.maxX, tabBar.bounds.maxX - 8, accuracy: 0.5)
        XCTAssertNil(tabCollection.enclosingScrollView)
    }

    func testManyTabsShrinkToTheRoundedRailWithoutOverflow() throws {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)
        let paths = (0..<12).map { "tab-\($0).swift" }
        for path in paths {
            controller.openTab(relativePath: path, pinned: true, snapshot: SourceSnapshot(text: path))
        }
        controller.view.window?.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        let tabCollection = try XCTUnwrap(
            findView(identifier: "editorGroup.tabCollection", in: controller.view) as? NSCollectionView
        )
        let totalTabWidth = try paths.reduce(CGFloat.zero) {
            $0 + (try XCTUnwrap(findView(identifier: "tab.\($1)", in: controller.view))).frame.width
        }

        XCTAssertEqual(totalTabWidth, tabCollection.bounds.width, accuracy: 1)
        XCTAssertNil(tabCollection.enclosingScrollView)
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

    func testDragGeometryUsesThresholdRailClampingAndLiveSlotCrossings() {
        XCTAssertFalse(
            EditorTabDragGeometry.hasExceededActivationDistance(
                from: .zero,
                to: NSPoint(x: 2, y: 2)
            )
        )
        XCTAssertTrue(
            EditorTabDragGeometry.hasExceededActivationDistance(
                from: .zero,
                to: NSPoint(x: 3, y: 0)
            )
        )

        let visibleBounds = NSRect(x: 100, y: 0, width: 400, height: 32)
        XCTAssertEqual(
            EditorTabDragGeometry.clampedOriginX(
                20,
                itemWidth: 100,
                visibleBounds: visibleBounds,
                horizontalInset: 8
            ),
            108
        )
        XCTAssertEqual(
            EditorTabDragGeometry.clampedOriginX(
                1_000,
                itemWidth: 100,
                visibleBounds: visibleBounds,
                horizontalInset: 8
            ),
            392
        )

        let centers: [CGFloat] = [50, 150, 250, 350]
        XCTAssertEqual(
            EditorTabDragGeometry.updatedTargetIndex(
                currentTargetIndex: 0,
                draggedCenterX: 149,
                slotCenters: centers
            ),
            0
        )
        XCTAssertEqual(
            EditorTabDragGeometry.updatedTargetIndex(
                currentTargetIndex: 0,
                draggedCenterX: 251,
                slotCenters: centers
            ),
            2
        )
        XCTAssertEqual(
            EditorTabDragGeometry.updatedTargetIndex(
                currentTargetIndex: 2,
                draggedCenterX: 49,
                slotCenters: centers
            ),
            0
        )
    }

    func testDragGeometryShiftsOnlyTabsBetweenSourceAndTarget() {
        XCTAssertEqual(
            (0..<4).map {
                EditorTabDragGeometry.visualSlot(
                    forItemAt: $0,
                    sourceIndex: 0,
                    targetIndex: 2
                )
            },
            [0, 0, 1, 3]
        )
        XCTAssertEqual(
            (0..<4).map {
                EditorTabDragGeometry.visualSlot(
                    forItemAt: $0,
                    sourceIndex: 3,
                    targetIndex: 1
                )
            },
            [0, 2, 3, 3]
        )
    }

    func testDropAnchorsPreserveInsertionPointWhenAnotherTabClosesDuringSettlement() throws {
        let a = EditorTabID()
        let b = EditorTabID()
        let c = EditorTabID()
        let d = EditorTabID()
        let anchors = try XCTUnwrap(
            EditorTabDropAnchors(
                tabIDs: [a, b, c, d],
                sourceTabID: d,
                destination: 1
            )
        )

        XCTAssertEqual(anchors.destination(in: [b, c, d]), 0)
        XCTAssertNil(anchors.destination(in: [a, b, c]))
    }

    func testDraggingTabTracksHorizontallyAndCommitsLiveReorder() throws {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)
        for path in ["first.md", "second.swift", "third.swift"] {
            controller.openTab(relativePath: path, pinned: true, snapshot: SourceSnapshot(text: path))
        }
        controller.view.window?.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        let draggedTab = try XCTUnwrap(findView(identifier: "tab.first.md", in: controller.view))
        let destinationTab = try XCTUnwrap(findView(identifier: "tab.third.swift", in: controller.view))
        let window = try XCTUnwrap(controller.view.window)
        let draggedTabID = try XCTUnwrap(
            controller.state.tabs.first(where: { $0.relativePath == "first.md" })?.id
        )
        let originalDraggedFrame = draggedTab.frame
        let downLocation = draggedTab.convert(
            NSPoint(x: draggedTab.bounds.midX, y: draggedTab.bounds.midY),
            to: nil
        )
        let destinationLocation = destinationTab.convert(
            NSPoint(x: destinationTab.bounds.midX + 1, y: destinationTab.bounds.midY + 80),
            to: nil
        )

        func event(_ type: NSEvent.EventType, at location: NSPoint) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type,
                    location: location,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                )
            )
        }

        draggedTab.mouseDown(with: try event(.leftMouseDown, at: downLocation))
        draggedTab.mouseDragged(with: try event(.leftMouseDragged, at: destinationLocation))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        let currentDraggedTab = try XCTUnwrap(
            findView(identifier: "tab.first.md", in: controller.view)
        )
        XCTAssertEqual(currentDraggedTab.frame.minY, originalDraggedFrame.minY, accuracy: 0.5)
        XCTAssertEqual(currentDraggedTab.frame.height, originalDraggedFrame.height, accuracy: 0.5)
        let shiftedSecondVisual = try XCTUnwrap(
            findView(identifier: "tab.visual.second.swift", in: controller.view)
        )
        XCTAssertLessThan(
            shiftedSecondVisual.frame.minX,
            0,
            "The neighboring tab should move into the open slot during the drag"
        )

        draggedTab.mouseUp(with: try event(.leftMouseUp, at: destinationLocation))
        controller.pinTab(draggedTabID)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))

        XCTAssertEqual(
            controller.state.tabs.map(\.relativePath),
            ["second.swift", "third.swift", "first.md"]
        )
        for path in ["first.md", "second.swift", "third.swift"] {
            let tab = try XCTUnwrap(findView(identifier: "tab.\(path)", in: controller.view))
            let visual = try XCTUnwrap(findView(identifier: "tab.visual.\(path)", in: controller.view))
            XCTAssertEqual(tab.layer?.zPosition, 0)
            XCTAssertEqual(visual.frame.minX, 0, accuracy: 0.5)
        }
    }

    func testDraggingTabBetweenPanesAnimatesBothRailsAndTransfersItsLiveController() throws {
        let source = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        let destination = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        hostSideBySide(source, destination)
        let initialSourceWidth = source.view.frame.width
        let initialDestinationWidth = destination.view.frame.width
        source.openTab(
            relativePath: "Stay.swift",
            pinned: true,
            snapshot: SourceSnapshot(text: "stay")
        )
        source.openTab(
            relativePath: "Source.swift",
            pinned: true,
            snapshot: SourceSnapshot(text: "source")
        )
        destination.openTab(
            relativePath: "Destination.swift",
            pinned: true,
            snapshot: SourceSnapshot(text: "destination")
        )
        source.view.window?.layoutIfNeeded()
        XCTAssertEqual(source.view.frame.width, initialSourceWidth, accuracy: 0.5)
        XCTAssertEqual(destination.view.frame.width, initialDestinationWidth, accuracy: 0.5)

        source.onTabDragUpdate = { _, _, windowLocation in
            destination.showTabDropPreview(at: windowLocation)
        }
        source.onTabDragEnd = { _ in
            destination.clearTabDropPreview()
        }
        source.onTabDrop = { _, tabID, preview in
            guard preview.groupID == destination.groupID,
                  let payload = source.detachTabForTransfer(tabID) else {
                return false
            }
            destination.consumeTabDropPreview()
            destination.insertTransferredTab(payload, at: preview.insertionIndex)
            return true
        }

        let sourceTab = try XCTUnwrap(findView(identifier: "tab.Source.swift", in: source.view))
        let stayingSourceTab = try XCTUnwrap(
            findView(identifier: "tab.Stay.swift", in: source.view)
        )
        let destinationTab = try XCTUnwrap(
            findView(identifier: "tab.Destination.swift", in: destination.view)
        )
        let originalStayingSourceTabWidth = stayingSourceTab.frame.width
        let originalDestinationTabWidth = destinationTab.frame.width
        let window = try XCTUnwrap(source.view.window)
        let downLocation = sourceTab.convert(
            NSPoint(x: sourceTab.bounds.midX, y: sourceTab.bounds.midY),
            to: nil
        )
        let destinationLocation = destinationTab.convert(
            NSPoint(x: destinationTab.bounds.midX, y: destinationTab.bounds.midY),
            to: nil
        )

        func event(_ type: NSEvent.EventType, at location: NSPoint) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type,
                    location: location,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                )
            )
        }

        sourceTab.mouseDown(with: try event(.leftMouseDown, at: downLocation))
        sourceTab.mouseDragged(with: try event(.leftMouseDragged, at: destinationLocation))
        let dragProxy = try XCTUnwrap(
            findView(identifier: "editorGroup.tabDragProxy", in: window.contentView!)
        )
        XCTAssertTrue(sourceTab.alphaValue == 0)
        XCTAssertGreaterThan(stayingSourceTab.frame.width, originalStayingSourceTabWidth)
        XCTAssertLessThan(destinationTab.frame.width, originalDestinationTabWidth)
        let destinationFrameInWindow = destinationTab.convert(
            destinationTab.bounds,
            to: window.contentView
        )
        XCTAssertEqual(dragProxy.frame.midY, destinationFrameInWindow.midY, accuracy: 1)

        sourceTab.mouseDragged(with: try event(.leftMouseDragged, at: downLocation))
        XCTAssertNil(findView(identifier: "editorGroup.tabDragProxy", in: window.contentView!))
        XCTAssertEqual(sourceTab.alphaValue, 1)
        XCTAssertEqual(stayingSourceTab.frame.width, originalStayingSourceTabWidth, accuracy: 0.5)
        XCTAssertEqual(destinationTab.frame.width, originalDestinationTabWidth, accuracy: 0.5)

        sourceTab.mouseDragged(with: try event(.leftMouseDragged, at: destinationLocation))
        XCTAssertNotNil(findView(identifier: "editorGroup.tabDragProxy", in: window.contentView!))
        sourceTab.mouseUp(with: try event(.leftMouseUp, at: destinationLocation))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))

        XCTAssertEqual(source.state.tabs.map(\.relativePath), ["Stay.swift"])
        XCTAssertEqual(
            destination.state.tabs.map(\.relativePath),
            ["Destination.swift", "Source.swift"]
        )
        XCTAssertEqual(destination.currentDocumentController?.snapshot.text, "source")
        XCTAssertNil(findView(identifier: "editorGroup.tabDragProxy", in: window.contentView!))
        XCTAssertEqual(source.view.frame.width, initialSourceWidth, accuracy: 0.5)
        XCTAssertEqual(destination.view.frame.width, initialDestinationWidth, accuracy: 0.5)
    }

    func testDraggingSuppressesSeparatorsImmediatelyBesideMovingTab() throws {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)
        var tabIDs: [String: EditorTabID] = [:]
        for path in ["A.swift", "B.swift", "C.swift", "D.swift"] {
            controller.openTab(relativePath: path, pinned: true, snapshot: SourceSnapshot(text: path))
            tabIDs[path] = try XCTUnwrap(
                controller.state.tabs.first(where: { $0.relativePath == path })?.id
            )
        }
        controller.selectTab(try XCTUnwrap(tabIDs["C.swift"]))
        controller.view.window?.layoutIfNeeded()

        let draggedTab = try XCTUnwrap(findView(identifier: "tab.C.swift", in: controller.view))
        let destinationTab = try XCTUnwrap(findView(identifier: "tab.B.swift", in: controller.view))
        let leftSeparator = try XCTUnwrap(
            findView(identifier: "tab.separator.A.swift", in: controller.view)
        )
        let sourceSeparator = try XCTUnwrap(
            findView(identifier: "tab.separator.C.swift", in: controller.view)
        )
        XCTAssertFalse(leftSeparator.isHidden)

        let window = try XCTUnwrap(controller.view.window)
        let downLocation = draggedTab.convert(
            NSPoint(x: draggedTab.bounds.midX, y: draggedTab.bounds.midY),
            to: nil
        )
        let destinationLocation = destinationTab.convert(
            NSPoint(x: destinationTab.bounds.midX - 1, y: destinationTab.bounds.midY),
            to: nil
        )
        func event(_ type: NSEvent.EventType, at location: NSPoint) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type,
                    location: location,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                )
            )
        }

        draggedTab.mouseDown(with: try event(.leftMouseDown, at: downLocation))
        draggedTab.mouseDragged(with: try event(.leftMouseDragged, at: destinationLocation))

        XCTAssertTrue(leftSeparator.isHidden)
        XCTAssertTrue(sourceSeparator.isHidden)
        draggedTab.mouseUp(with: try event(.leftMouseUp, at: destinationLocation))
    }

    func testPaneActivationMonitorReturnsRemainingControlClicksUnchanged() throws {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)
        controller.openTab(relativePath: "src/a.txt", pinned: true, snapshot: SourceSnapshot(text: "hello"))
        controller.view.layoutSubtreeIfNeeded()

        var activatedGroupID: EditorGroupID?
        controller.onActivate = { activatedGroupID = $0 }

        let closeTabButton = try XCTUnwrap(
            findView(identifier: "tab.close.src/a.txt", in: controller.view) as? NSButton
        )
        let window = try XCTUnwrap(controller.view.window)

        XCTAssertNil(findView(identifier: "editorGroup.back", in: controller.view))
        XCTAssertNil(findView(identifier: "editorGroup.forward", in: controller.view))
        XCTAssertNil(findView(identifier: "editorGroup.closeGroup", in: controller.view))
        XCTAssertNil(findView(identifier: "editorGroup.splitRight", in: controller.view))
        XCTAssertNil(findView(identifier: "editorGroup.splitDown", in: controller.view))
        XCTAssertTrue(controller.view.gestureRecognizers.isEmpty)
        for button in [closeTabButton] {
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
