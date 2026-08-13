import AppKit
import WorkspaceCore
import XCTest
@testable import Kod

@MainActor
final class WorkspaceLayoutPersistenceTests: XCTestCase {
    private struct Fixture {
        let identity: WorkspaceIdentity
        let store: WorkspaceLayoutStore
        let controller: WorkspaceViewController
    }

    private var windows: [NSWindow] = []

    private func makeFixture(savedState: WorkspaceLayoutState? = nil) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let suiteName = "WorkspaceLayoutPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }

        let identity = try WorkspaceIdentity(root: root)
        let store = WorkspaceLayoutStore(defaults: defaults)
        if let savedState {
            store.save(savedState, for: identity)
        }
        let controller = WorkspaceViewController(
            identity: identity,
            trustStore: WorkspaceTrustStore(defaults: defaults),
            layoutStore: store
        )
        return Fixture(identity: identity, store: store, controller: controller)
    }

    @discardableResult
    private func host(
        _ controller: NSViewController,
        frame: NSRect = NSRect(x: 120, y: 100, width: 1_100, height: 720)
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 640, height: 420)
        window.contentViewController = controller
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        windows.append(window)
        return window
    }

    private func sidebarPaneWidth(
        item: NSSplitViewItem,
        in splitView: NSSplitView
    ) -> CGFloat {
        splitView.arrangedSubviews.first?.frame.width
            ?? item.viewController.view.frame.width
    }

    func testSplitContainerCapturesEveryNestedDividerRatio() throws {
        let firstID = EditorGroupID()
        let secondID = EditorGroupID()
        let thirdID = EditorGroupID()
        let root = SplitLayoutNode.split(
            orientation: .horizontal,
            ratio: 0.5,
            first: .leaf(firstID),
            second: .split(
                orientation: .vertical,
                ratio: 0.5,
                first: .leaf(secondID),
                second: .leaf(thirdID)
            )
        )
        let controller = SplitContainerViewController(root: root) { id in
            EditorGroupViewController(
                groupID: id,
                state: EditorGroupState(id: id)
            )
        }
        _ = host(controller)

        let rootSplit = try XCTUnwrap(controller.view.subviews.first as? NSSplitView)
        let nestedSplit = try XCTUnwrap(rootSplit.arrangedSubviews[1] as? NSSplitView)
        rootSplit.setPosition(rootSplit.bounds.width * 0.32, ofDividerAt: 0)
        controller.view.layoutSubtreeIfNeeded()
        nestedSplit.setPosition(nestedSplit.bounds.height * 0.68, ofDividerAt: 0)
        controller.view.layoutSubtreeIfNeeded()

        let expectedRootRatio = rootSplit.arrangedSubviews[0].frame.width / rootSplit.bounds.width
        let expectedNestedRatio = nestedSplit.arrangedSubviews[0].frame.height / nestedSplit.bounds.height
        let captured = controller.captureLayout()

        guard case .split(let rootOrientation, let rootRatio, _, let capturedSecond) = captured,
              case .split(let nestedOrientation, let nestedRatio, _, _) = capturedSecond else {
            return XCTFail("Expected the nested split tree to be preserved")
        }
        XCTAssertEqual(rootOrientation, .horizontal)
        XCTAssertEqual(nestedOrientation, .vertical)
        XCTAssertEqual(rootRatio, Double(expectedRootRatio), accuracy: 0.001)
        XCTAssertEqual(nestedRatio, Double(expectedNestedRatio), accuracy: 0.001)
    }

    func testAppDelegatePersistsWindowAndCollapsedSidebarGeometry() throws {
        let fixture = try makeFixture()
        let window = host(fixture.controller)
        let splitController = try XCTUnwrap(
            fixture.controller.children.compactMap { $0 as? NSSplitViewController }.first
        )
        let sidebarItem = try XCTUnwrap(splitController.splitViewItems.first)

        splitController.splitView.setPosition(318, ofDividerAt: 0)
        window.layoutIfNeeded()
        fixture.controller.view.layoutSubtreeIfNeeded()
        let expandedWidth = sidebarPaneWidth(item: sidebarItem, in: splitController.splitView)
        fixture.controller.toggleSidebar(nil)
        XCTAssertTrue(sidebarItem.isCollapsed)

        AppDelegate().persistCurrentWorkspaceState(in: window)

        let saved = try XCTUnwrap(fixture.store.load(for: fixture.identity))
        let geometry = try XCTUnwrap(saved.geometry)
        XCTAssertEqual(geometry.windowFrame.x, Double(window.frame.origin.x), accuracy: 0.5)
        XCTAssertEqual(geometry.windowFrame.y, Double(window.frame.origin.y), accuracy: 0.5)
        XCTAssertEqual(geometry.windowFrame.width, Double(window.frame.width), accuracy: 0.5)
        XCTAssertEqual(geometry.windowFrame.height, Double(window.frame.height), accuracy: 0.5)
        XCTAssertEqual(geometry.sidebarWidth, Double(expandedWidth), accuracy: 1)
        XCTAssertTrue(geometry.isSidebarCollapsed)
    }

    func testMinimapTogglePersistsPerWorkspaceAndDefaultsOn() throws {
        let fixture = try makeFixture()
        _ = host(fixture.controller)
        XCTAssertTrue(fixture.controller.layoutState.minimapEnabled)

        fixture.controller.toggleMinimap(nil)

        XCTAssertFalse(fixture.controller.layoutState.minimapEnabled)
        XCTAssertFalse(try XCTUnwrap(fixture.store.load(for: fixture.identity)).minimapEnabled)
    }

    func testSavedWindowAndSidebarGeometryRestoreForReconstructedWorkspace() async throws {
        guard let visibleFrame = NSScreen.screens.first?.visibleFrame else {
            throw XCTSkip("No screen is available to constrain a test window")
        }
        let savedFrame = WorkspaceWindowFrame(
            x: Double(visibleFrame.minX + 40),
            y: Double(visibleFrame.minY + 40),
            width: Double(min(960, visibleFrame.width - 80)),
            height: Double(min(680, visibleFrame.height - 80))
        )
        var savedState = WorkspaceLayoutState.singleGroup()
        savedState.geometry = WorkspaceGeometryState(
            windowFrame: savedFrame,
            sidebarWidth: 336,
            isSidebarCollapsed: true
        )
        let fixture = try makeFixture(savedState: savedState)
        let window = host(
            fixture.controller,
            frame: NSRect(x: visibleFrame.minX, y: visibleFrame.minY, width: 700, height: 500)
        )

        fixture.controller.restoreWorkspaceGeometryIfNeeded()
        try await Task.sleep(for: .milliseconds(20))

        let expectedFrame = try XCTUnwrap(
            WorkspaceViewController.constrainedWindowFrame(
                savedFrame,
                minimumSize: window.minSize,
                visibleScreenFrames: NSScreen.screens.map(\.visibleFrame),
                fallbackVisibleFrame: window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            )
        )
        XCTAssertEqual(window.frame.origin.x, expectedFrame.origin.x, accuracy: 0.5)
        XCTAssertEqual(window.frame.origin.y, expectedFrame.origin.y, accuracy: 0.5)
        XCTAssertEqual(window.frame.width, expectedFrame.width, accuracy: 0.5)
        XCTAssertEqual(window.frame.height, expectedFrame.height, accuracy: 0.5)

        let splitController = try XCTUnwrap(
            fixture.controller.children.compactMap { $0 as? NSSplitViewController }.first
        )
        let sidebarItem = try XCTUnwrap(splitController.splitViewItems.first)
        XCTAssertTrue(sidebarItem.isCollapsed)
        XCTAssertEqual(
            sidebarItem.preferredThicknessFraction,
            336 / splitController.splitView.bounds.width,
            accuracy: 0.001
        )
    }

    func testExpandedSidebarRestoresItsPaneThickness() async throws {
        guard let visibleFrame = NSScreen.screens.first?.visibleFrame else {
            throw XCTSkip("No screen is available to constrain a test window")
        }
        var savedState = WorkspaceLayoutState.singleGroup()
        savedState.geometry = WorkspaceGeometryState(
            windowFrame: WorkspaceWindowFrame(
                x: Double(visibleFrame.minX + 60),
                y: Double(visibleFrame.minY + 60),
                width: 960,
                height: 680
            ),
            sidebarWidth: 300,
            isSidebarCollapsed: false
        )
        let fixture = try makeFixture(savedState: savedState)
        let window = host(fixture.controller)

        fixture.controller.restoreWorkspaceGeometryIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        window.layoutIfNeeded()
        fixture.controller.view.layoutSubtreeIfNeeded()

        let splitController = try XCTUnwrap(
            fixture.controller.children.compactMap { $0 as? NSSplitViewController }.first
        )
        let sidebarItem = try XCTUnwrap(splitController.splitViewItems.first)
        XCTAssertFalse(sidebarItem.isCollapsed)
        XCTAssertEqual(
            sidebarPaneWidth(item: sidebarItem, in: splitController.splitView),
            300,
            accuracy: 1
        )
    }

    func testWindowFrameConstraintMovesStaleFrameOntoFallbackScreen() throws {
        let screen = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let restored = try XCTUnwrap(
            WorkspaceViewController.constrainedWindowFrame(
                WorkspaceWindowFrame(x: 5_000, y: -300, width: 100, height: 100),
                minimumSize: NSSize(width: 640, height: 420),
                visibleScreenFrames: [screen],
                fallbackVisibleFrame: screen
            )
        )

        XCTAssertEqual(restored, NSRect(x: 800, y: 0, width: 640, height: 420))
    }

    func testFullscreenPersistenceSelectsLastNormalWindowFrame() throws {
        let normalFrame = NSRect(x: 120, y: 100, width: 1_100, height: 720)
        let fullscreenFrame = NSRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let selectedFrame = try XCTUnwrap(
            WorkspaceViewController.normalWindowFrame(
                currentFrame: fullscreenFrame,
                isFullScreen: true,
                lastNormalFrame: normalFrame,
                persistedFrame: nil
            )
        )

        XCTAssertEqual(selectedFrame, normalFrame)
    }
}
