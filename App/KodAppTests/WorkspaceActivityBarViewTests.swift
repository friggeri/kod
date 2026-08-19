import AppKit
import KodUIComponents
import WorkspaceCore
import XCTest
@testable import Kod

@MainActor
final class WorkspaceActivityBarViewTests: XCTestCase {
    private var windows: [NSWindow] = []

    func testBarExposesFourOrderedAccessibleDestinations() throws {
        let bar = WorkspaceActivityBarView()
        let window = host(bar, size: NSSize(width: 240, height: 40))

        XCTAssertEqual(
            WorkspaceActivityBarView.orderedSurfaces,
            [.explorer, .search, .sourceControl, .problems]
        )
        XCTAssertEqual(bar.accessibilityLabel(), "Activity")
        XCTAssertEqual(bar.frame.height, 40, accuracy: 0.5)
        let stack = try XCTUnwrap(
            bar.subviews.compactMap { $0 as? NSStackView }.first
        )
        XCTAssertEqual(stack.arrangedSubviews.count, 4)
        XCTAssertTrue(
            stack.arrangedSubviews.allSatisfy { $0 is KodSymbolButton },
            "selection should use button background only, with no separate underline views"
        )

        for surface in WorkspaceActivityBarView.orderedSurfaces {
            let button = try XCTUnwrap(bar.button(for: surface))
            XCTAssertEqual(button.frame.size, NSSize(width: 28, height: 28))
            XCTAssertNotNil(button.toolTip)
        }
        XCTAssertEqual(
            bar.button(for: .explorer)?.accessibilityValue() as? String,
            "Selected"
        )
        XCTAssertEqual(
            bar.button(for: .problems)?.accessibilityValue() as? String,
            "Not selected"
        )
        _ = window
    }

    func testSelectionCallbackAndExplicitSelectedValueStayInSync() throws {
        let bar = WorkspaceActivityBarView()
        var selected: WorkspaceSidebarSurface?
        bar.onSelectSurface = { selected = $0 }

        let problemsButton = try XCTUnwrap(bar.button(for: .problems))
        problemsButton.performClick(nil)
        XCTAssertEqual(selected, .problems)

        bar.setSelectedSurface(.problems)
        XCTAssertEqual(bar.selectedSurface, .problems)
        XCTAssertEqual(
            problemsButton.accessibilityValue() as? String,
            "Selected"
        )
        XCTAssertEqual(
            bar.button(for: .explorer)?.accessibilityValue() as? String,
            "Not selected"
        )
    }

    func testWorkspaceCommandsPersistSurfaceAndRevealCollapsedSidebar() throws {
        let fixture = try KodAppTestEnvironment.make(in: self)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let identity = try WorkspaceIdentity(root: root)
        let controller = WorkspaceViewController(
            identity: identity,
            dependencies: fixture.environment.makeWorkspaceDependencies()
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 520),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        windows.append(window)

        let splitController = try XCTUnwrap(
            controller.children.compactMap { $0 as? NSSplitViewController }.first
        )
        let sidebarItem = try XCTUnwrap(splitController.splitViewItems.first)
        let explorerView = try XCTUnwrap(
            findView(identifier: "workspace.explorer", in: controller.view)
        )
        let problemsOutline = try XCTUnwrap(
            findView(identifier: "problems.outline", in: controller.view)
        )
        controller.showProblems(nil)
        controller.showExplorer(nil)
        XCTAssertTrue(
            findView(identifier: "workspace.explorer", in: controller.view)
                === explorerView
        )
        XCTAssertTrue(
            findView(identifier: "problems.outline", in: controller.view)
                === problemsOutline
        )
        controller.toggleSidebar(nil)
        XCTAssertTrue(waitUntil { sidebarItem.isCollapsed })
        controller.showProblems(nil)

        XCTAssertTrue(waitUntil { !sidebarItem.isCollapsed })
        XCTAssertEqual(controller.layoutState.sidebarSurface, .problems)
        guard case .value(let saved, _) = try controller.layoutStore.load(for: identity) else {
            return XCTFail("Expected persisted layout")
        }
        XCTAssertEqual(saved.sidebarSurface, .problems)
        XCTAssertTrue(
            findView(identifier: "problems.outline", in: controller.view)
                === problemsOutline
        )
    }

    @discardableResult
    private func host(_ view: NSView, size: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        windows.append(window)
        return window
    }

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

    private func waitUntil(
        timeout: TimeInterval = 1,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}
