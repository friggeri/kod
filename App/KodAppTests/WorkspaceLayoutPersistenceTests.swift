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

        let appFixture = try KodAppTestEnvironment.make(in: self)
        let identity = try WorkspaceIdentity(root: root)
        let dependencies =
            appFixture.environment.makeWorkspaceDependencies()
        let store = dependencies.layoutStore
        if let savedState {
            try store.save(savedState, for: identity)
        }
        let controller = WorkspaceViewController(
            identity: identity,
            dependencies: dependencies
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

        let appFixture = try KodAppTestEnvironment.make(in: self)
        AppDelegate(environment: appFixture.environment)
            .persistCurrentWorkspaceState(in: window)

        guard case .value(let saved, _) =
                try fixture.store.load(for: fixture.identity) else {
            return XCTFail("Expected persisted workspace layout")
        }
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
        guard case .value(let saved, _) =
                try fixture.store.load(for: fixture.identity) else {
            return XCTFail("Expected persisted workspace layout")
        }
        XCTAssertFalse(saved.minimapEnabled)
    }

    func testNewWorkspaceUsesDefaultTotalSidebarWidth() async throws {
        let fixture = try makeFixture()
        let window = host(fixture.controller)

        fixture.controller.restoreWorkspaceGeometryIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        window.layoutIfNeeded()
        fixture.controller.view.layoutSubtreeIfNeeded()

        let splitController = try XCTUnwrap(
            fixture.controller.children
                .compactMap { $0 as? NSSplitViewController }
                .first
        )
        let sidebarItem = try XCTUnwrap(splitController.splitViewItems.first)
        XCTAssertEqual(
            sidebarItem.preferredThicknessFraction,
            WorkspaceGeometryController.defaultSidebarWidth
                / splitController.splitView.bounds.width,
            accuracy: 0.001
        )
        XCTAssertEqual(
            sidebarPaneWidth(item: sidebarItem, in: splitController.splitView),
            WorkspaceGeometryController.defaultSidebarWidth,
            accuracy: 1
        )
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
            WorkspaceGeometryController.constrainedWindowFrame(
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

    func testSelectedSidebarSurfaceRestoresWithoutStealingFocus() throws {
        var savedState = WorkspaceLayoutState.singleGroup()
        savedState.sidebarSurface = .symbols
        let fixture = try makeFixture(savedState: savedState)
        let window = host(fixture.controller)
        let activityBar = try XCTUnwrap(
            findView(
                identifier: "workspace.activityBar",
                in: fixture.controller.view
            ) as? WorkspaceActivityBarView
        )
        let symbolsField = try XCTUnwrap(
            findView(
                identifier: "symbols.field",
                in: fixture.controller.view
            )
        )

        XCTAssertEqual(activityBar.selectedSurface, .symbols)
        XCTAssertFalse(symbolsField.isHidden)
        XCTAssertFalse(window.firstResponder === symbolsField)
    }

    // The pure frame-constraint and fullscreen-selection policy these
    // tests used to cover now lives in `WorkspaceGeometryController`; see
    // `WorkspaceGeometryControllerTests`.

    private func findView(identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier {
            return view
        }
        for subview in view.subviews {
            if let found = findView(identifier: identifier, in: subview) {
                return found
            }
        }
        return nil
    }
}
