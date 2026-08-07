import AppKit
import LanguageClient
import XCTest
@testable import Kod

/// Headless coverage for the Symbols sidebar (SPEC 6.1). No window is
/// made key and no mouse/keyboard input is synthesized — the search
/// field's action is invoked directly, matching the rest of this
/// project's headless-only App-layer test style.
@MainActor
final class SymbolsViewControllerTests: XCTestCase {
    func testRunningASearchPopulatesResultsFromTheProvidedSearchClosure() throws {
        let expectation = expectation(description: "search ran")
        let symbol = WorkspaceSymbolLocation(
            url: URL(fileURLWithPath: "/workspace/Sources/Foo.swift"),
            range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 3)),
            name: "Foo",
            kind: .structType,
            containerName: nil
        )
        let controller = SymbolsViewController(
            search: { query in
                XCTAssertEqual(query, "Foo")
                expectation.fulfill()
                return [symbol]
            },
            onSelectSymbol: { _ in }
        )
        controller.loadView()

        let searchField = try XCTUnwrap(findSearchField(in: controller.view))
        searchField.stringValue = "Foo"
        searchField.sendAction(searchField.action, to: searchField.target)

        wait(for: [expectation], timeout: 2)

        let outline = try XCTUnwrap(findOutlineView(in: controller.view))
        let deadline = Date().addingTimeInterval(2)
        while outline.numberOfChildren(ofItem: nil) == 0, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(outline.numberOfChildren(ofItem: nil), 1)
    }

    func testSelectingASymbolInvokesTheSelectionCallback() throws {
        var selected: WorkspaceSymbolLocation?
        let symbol = WorkspaceSymbolLocation(
            url: URL(fileURLWithPath: "/workspace/Sources/Foo.swift"),
            range: LSPRange(start: LSPPosition(line: 1, character: 0), end: LSPPosition(line: 1, character: 3)),
            name: "Foo",
            kind: .structType,
            containerName: nil
        )
        let controller = SymbolsViewController(
            search: { _ in [symbol] },
            onSelectSymbol: { selection in selected = selection }
        )
        controller.loadView()

        let searchField = try XCTUnwrap(findSearchField(in: controller.view))
        searchField.stringValue = "Foo"
        searchField.sendAction(searchField.action, to: searchField.target)

        let outline = try XCTUnwrap(findOutlineView(in: controller.view))
        let deadline = Date().addingTimeInterval(2)
        while outline.numberOfChildren(ofItem: nil) == 0, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        outline.sendAction(outline.action, to: outline.target)

        XCTAssertEqual(selected?.name, "Foo")
    }

    private func findSearchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField {
            return field
        }
        for subview in view.subviews {
            if let found = findSearchField(in: subview) {
                return found
            }
        }
        return nil
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
}
