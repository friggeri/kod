import AppKit
import SearchCore
import XCTest
@testable import SearchUI

@MainActor
final class SearchSidebarLayoutTests: XCTestCase {
    private func makeController() -> SearchSidebarViewController {
        SearchSidebarViewController(
            root: URL(fileURLWithPath: NSTemporaryDirectory()),
            makeSearcher: {
                try WorkspaceTextSearcher(
                    executableURL: URL(fileURLWithPath: "/usr/bin/true")
                )
            },
            runSearchTask: { _ in Task { @MainActor in } },
            onSelectMatch: { _ in }
        )
    }

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

    func testSearchDetailsStartCollapsedAndToggleFromEllipsis() throws {
        let controller = makeController()
        let details = try XCTUnwrap(
            findView(identifier: "search.details", in: controller.view)
        )
        let searchBar = try XCTUnwrap(
            findView(identifier: "search.bar", in: controller.view)
        )
        let toggle = try XCTUnwrap(
            findView(identifier: "search.detailsToggle", in: controller.view) as? NSButton
        )

        XCTAssertTrue(details.isHidden)
        XCTAssertFalse(toggle.isDescendant(of: searchBar))
        XCTAssertEqual(toggle.title, "...")
        XCTAssertEqual(toggle.state, .off)

        toggle.performClick(nil)

        XCTAssertFalse(details.isHidden)
        XCTAssertEqual(toggle.state, .on)

        toggle.performClick(nil)

        XCTAssertTrue(details.isHidden)
        XCTAssertEqual(toggle.state, .off)
    }

    func testSearchModesAreInlineAndScopeFieldsLiveInDetails() throws {
        let controller = makeController()
        let rootView = controller.view
        let searchBar = try XCTUnwrap(findView(identifier: "search.bar", in: rootView))
        let details = try XCTUnwrap(findView(identifier: "search.details", in: rootView))
        let searchOptions = try XCTUnwrap(
            findView(identifier: "search.options", in: rootView) as? NSStackView
        )
        let matchCase = try XCTUnwrap(
            findView(identifier: "search.matchCase", in: rootView) as? NSButton
        )
        let wholeWord = try XCTUnwrap(
            findView(identifier: "search.wholeWord", in: rootView) as? NSButton
        )
        let regex = try XCTUnwrap(
            findView(identifier: "search.regex", in: rootView) as? NSButton
        )
        let includeField = try XCTUnwrap(
            findView(identifier: "search.includeGlob", in: rootView) as? NSTextField
        )
        let excludeField = try XCTUnwrap(
            findView(identifier: "search.excludeGlob", in: rootView) as? NSTextField
        )
        let showHiddenFiles = try XCTUnwrap(
            findView(identifier: "search.includeHidden", in: rootView) as? NSButton
        )

        XCTAssertTrue(matchCase.isDescendant(of: searchBar))
        XCTAssertTrue(wholeWord.isDescendant(of: searchBar))
        XCTAssertTrue(regex.isDescendant(of: searchBar))
        XCTAssertEqual(matchCase.title, "Aa")
        XCTAssertEqual(wholeWord.attributedTitle.string, "ab")
        XCTAssertEqual(regex.title, ".*")
        XCTAssertEqual(searchOptions.spacing, 4)

        XCTAssertTrue(includeField.isDescendant(of: details))
        XCTAssertTrue(excludeField.isDescendant(of: details))
        XCTAssertEqual(includeField.placeholderString, "e.g. *.swift")
        XCTAssertEqual(excludeField.placeholderString, "e.g. Generated/**")
        XCTAssertEqual(showHiddenFiles.title, "Show Hidden Files")
        XCTAssertNil(findView(identifier: "search.includeIgnored", in: rootView))
        XCTAssertFalse(controller.currentSearchOptions.includeHidden)
        XCTAssertTrue(controller.currentSearchOptions.includeIgnored)

        showHiddenFiles.performClick(nil)

        XCTAssertTrue(controller.currentSearchOptions.includeHidden)
    }

    func testSearchTextHasIconSpacingScrollingAndWorkingClearButton() throws {
        let controller = makeController()
        let rootView = controller.view
        rootView.frame = NSRect(x: 0, y: 0, width: 320, height: 500)
        rootView.layoutSubtreeIfNeeded()

        let searchBar = try XCTUnwrap(findView(identifier: "search.bar", in: rootView))
        let searchIcon = try XCTUnwrap(
            findView(identifier: "search.icon", in: rootView) as? NSImageView
        )
        let searchField = try XCTUnwrap(
            findView(identifier: "search.field", in: rootView) as? NSTextField
        )
        let clearButton = try XCTUnwrap(
            findView(identifier: "search.clear", in: rootView) as? NSButton
        )
        let cell = try XCTUnwrap(searchField.cell as? NSTextFieldCell)

        searchBar.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(searchField.frame.minX, searchIcon.frame.maxX)
        XCTAssertTrue(cell.usesSingleLineMode)
        XCTAssertTrue(cell.isScrollable)
        XCTAssertFalse(cell.wraps)
        XCTAssertTrue(clearButton.isHidden)

        searchField.stringValue = String(repeating: "long-search-query-", count: 20)
        XCTAssertTrue(searchField.sendAction(searchField.action, to: searchField.target))
        XCTAssertFalse(clearButton.isHidden)

        clearButton.performClick(nil)

        XCTAssertEqual(searchField.stringValue, "")
        XCTAssertTrue(clearButton.isHidden)
    }
}
