import AppKit
import LanguageClient
import XCTest
@testable import Kod

/// Headless coverage for the durable Call Hierarchy / Type Hierarchy
/// surface (SPEC 6.1). No window is made key and no mouse/keyboard
/// input is synthesized.
@MainActor
final class HierarchyViewControllerTests: XCTestCase {
    private func makeItem(
        name: String,
        binding: LanguageProviderBinding = LanguageProviderFixtures.binding()
    ) -> ValidatedHierarchyItem {
        ValidatedHierarchyItem(
            provider: binding,
            name: name,
            kind: .function,
            detail: nil,
            url: URL(fileURLWithPath: "/workspace/Sources/Foo.swift"),
            range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 3)),
            selectionRange: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 3)),
            data: nil
        )
    }

    func testFetchingChildrenPopulatesTheNodeAndReloadsItsRow() async throws {
        let root = makeItem(name: "root")
        let caller = makeItem(name: "caller")
        let controller = HierarchyViewController(
            root: root,
            modes: [
                HierarchyViewController.Mode(title: "Callers", fetchChildren: { _ in [caller] }),
                HierarchyViewController.Mode(title: "Callees", fetchChildren: { _ in [] })
            ],
            onSelectItem: { _ in }
        )
        controller.loadView()

        let outline = try XCTUnwrap(findOutlineView(in: controller.view))
        let rootNode = try XCTUnwrap(controller.outlineView(outline, child: 0, ofItem: nil) as? HierarchyNode)
        XCTAssertEqual(rootNode.item.name, "root")
        XCTAssertNil(rootNode.children, "Children must not be fetched until requested")

        controller.fetchChildrenIfNeeded(rootNode)
        let deadline = Date().addingTimeInterval(2)
        while rootNode.children == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(rootNode.children?.map(\.item.name), ["caller"])
    }

    func testSelectingANodeInvokesTheSelectionCallback() throws {
        let root = makeItem(name: "root")
        var selected: ValidatedHierarchyItem?
        let controller = HierarchyViewController(
            root: root,
            modes: [HierarchyViewController.Mode(title: "Callers", fetchChildren: { _ in [] })],
            onSelectItem: { item in selected = item }
        )
        controller.loadView()

        let outline = try XCTUnwrap(findOutlineView(in: controller.view))
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        outline.sendAction(outline.action, to: outline.target)

        XCTAssertEqual(selected?.name, "root")
    }

    func testSwitchingModesResetsPreviouslyFetchedChildren() async throws {
        let root = makeItem(name: "root")
        let controller = HierarchyViewController(
            root: root,
            modes: [
                HierarchyViewController.Mode(title: "Callers", fetchChildren: { _ in [self.makeItem(name: "caller")] }),
                HierarchyViewController.Mode(title: "Callees", fetchChildren: { _ in [self.makeItem(name: "callee")] })
            ],
            onSelectItem: { _ in }
        )
        controller.loadView()

        let outline = try XCTUnwrap(findOutlineView(in: controller.view))
        let rootNode = try XCTUnwrap(controller.outlineView(outline, child: 0, ofItem: nil) as? HierarchyNode)
        controller.fetchChildrenIfNeeded(rootNode)
        let deadline = Date().addingTimeInterval(2)
        while rootNode.children == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(rootNode.children?.map(\.item.name), ["caller"])

        let modeControl = try XCTUnwrap(findSegmentedControl(in: controller.view))
        modeControl.selectedSegment = 1
        modeControl.sendAction(modeControl.action, to: modeControl.target)

        XCTAssertNil(rootNode.children, "Switching direction must invalidate previously-fetched children")
    }

    private func findOutlineView(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView {
            return outline
        }
        for subview in view.subviews {
            if let found = findOutlineView(in: subview) {
                return found
            }
        }
        return nil
    }

    private func findSegmentedControl(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl {
            return control
        }
        for subview in view.subviews {
            if let found = findSegmentedControl(in: subview) {
                return found
            }
        }
        return nil
    }
}
