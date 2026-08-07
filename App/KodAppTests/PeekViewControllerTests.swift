import AppKit
import LanguageClient
import XCTest
@testable import Kod

/// Headless coverage for the durable Peek Definition/References surface
/// (SPEC: "Peek Definition/References and durable navigation-result
/// surfaces"). No window is made key and no mouse/keyboard input is
/// synthesized, matching this project's headless-only App-layer style.
@MainActor
final class PeekViewControllerTests: XCTestCase {
    func testShowReplacesResultsWholesaleAndUpdatesTitle() throws {
        let controller = PeekViewController(onSelect: { _ in })
        controller.loadView()

        let first = PeekResult(
            url: URL(fileURLWithPath: "/workspace/Sources/Foo.swift"),
            range: LSPRange(start: LSPPosition(line: 4, character: 0), end: LSPPosition(line: 4, character: 3)),
            previewLine: "func foo() {}"
        )
        controller.show(title: "Definition", results: [first])
        XCTAssertEqual(controller.results, [first])

        let titleLabel = try XCTUnwrap(findLabel(in: controller.view, identifier: "peek.title"))
        XCTAssertEqual(titleLabel.stringValue, "Definition (1)")

        // A later, superseded call fully replaces the prior content —
        // there is no partial/merged state.
        controller.show(title: "References", results: [])
        XCTAssertEqual(controller.results, [])
        XCTAssertEqual(titleLabel.stringValue, "References — No results")
    }

    func testDoubleClickingARowInvokesTheSelectionCallback() throws {
        var selected: PeekResult?
        let controller = PeekViewController(onSelect: { result in selected = result })
        controller.loadView()

        let target = PeekResult(
            url: URL(fileURLWithPath: "/workspace/Sources/Foo.swift"),
            range: LSPRange(start: LSPPosition(line: 1, character: 0), end: LSPPosition(line: 1, character: 3))
        )
        controller.show(title: "Definition", results: [target])

        let tableView = try XCTUnwrap(findTableView(in: controller.view))
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tableView.sendAction(tableView.doubleAction, to: tableView.target)

        XCTAssertEqual(selected, target)
    }

    private func findLabel(in view: NSView, identifier: String) -> NSTextField? {
        if let field = view as? NSTextField, field.identifier?.rawValue == identifier {
            return field
        }
        for subview in view.subviews {
            if let found = findLabel(in: subview, identifier: identifier) {
                return found
            }
        }
        return nil
    }

    private func findTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView {
            return table
        }
        for subview in view.subviews {
            if let found = findTableView(in: subview) {
                return found
            }
        }
        return nil
    }
}
