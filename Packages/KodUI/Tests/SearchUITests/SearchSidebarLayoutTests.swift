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

    func testSearchStatusIsAccessibleAndAnnouncesImportantChangedStates() throws {
        var announcements: [String] = []
        let controller = SearchSidebarViewController(
            root: URL(fileURLWithPath: NSTemporaryDirectory()),
            makeSearcher: {
                try WorkspaceTextSearcher(
                    executableURL: URL(fileURLWithPath: "/usr/bin/true")
                )
            },
            runSearchTask: { _ in Task { @MainActor in } },
            postAccessibilityAnnouncement: { announcements.append($0) },
            onSelectMatch: { _ in }
        )
        let status = try XCTUnwrap(
            findView(identifier: "search.status", in: controller.view) as? NSTextField
        )

        XCTAssertTrue(status.isAccessibilityElement())
        XCTAssertEqual(status.accessibilityLabel(), "Search status")

        controller.applyCompletion(
            SearchCompletion(
                queryVersion: 1,
                matchedFileCount: 0,
                matchCount: 0,
                truncated: false
            )
        )
        controller.applyCompletion(
            SearchCompletion(
                queryVersion: 1,
                matchedFileCount: 0,
                matchCount: 0,
                truncated: false
            )
        )
        controller.applyCompletion(
            SearchCompletion(
                queryVersion: 2,
                matchedFileCount: 2,
                matchCount: 10,
                truncated: true
            )
        )
        controller.setStatus("Search cancelled.", announcement: .cancellation)
        controller.setStatus("Search cancelled.", announcement: .cancellation)
        controller.setStatus(
            "Search failed: test failure",
            color: .systemRed,
            announcement: .error
        )

        XCTAssertEqual(
            announcements,
            [
                "No results.",
                "Showing first 10 matches (more available).",
                "Search cancelled.",
                "Search failed: test failure"
            ]
        )
        XCTAssertEqual(
            status.accessibilityValue(),
            "Search failed: test failure"
        )
    }

    private struct CustomSearchUnavailableError: Error, CustomStringConvertible {
        var description: String { "engine-startup-failure" }
    }

    func testInitializationErrorDoesNotRecursivelyEnterLoadViewInProductionMode() throws {
        let controller = SearchSidebarViewController(
            root: URL(fileURLWithPath: NSTemporaryDirectory()),
            makeSearcher: { throw CustomSearchUnavailableError() },
            runSearchTask: { _ in Task { @MainActor in } },
            onSelectMatch: { _ in }
        )

        XCTAssertFalse(controller.isViewLoaded)

        let rootView = controller.view
        XCTAssertTrue(controller.isViewLoaded)

        let status = try XCTUnwrap(
            findView(identifier: "search.status", in: rootView) as? NSTextField
        )
        XCTAssertFalse(status.isHidden)
        XCTAssertTrue(status.stringValue.contains("engine-startup-failure"))
        XCTAssertEqual(status.textColor, .systemRed)
        XCTAssertEqual(status.accessibilityValue(), status.stringValue)
    }

    func testInitializationErrorAnnouncesStatusDuringLoadViewAndSubsequentErrorsAnnounce() throws {
        var announcements: [String] = []
        let controller = SearchSidebarViewController(
            root: URL(fileURLWithPath: NSTemporaryDirectory()),
            makeSearcher: { throw CustomSearchUnavailableError() },
            runSearchTask: { _ in Task { @MainActor in } },
            postAccessibilityAnnouncement: { announcements.append($0) },
            onSelectMatch: { _ in }
        )

        XCTAssertFalse(controller.isViewLoaded)
        XCTAssertEqual(announcements, [])

        let rootView = controller.view
        XCTAssertTrue(controller.isViewLoaded)
        XCTAssertEqual(announcements.count, 1)
        XCTAssertTrue(announcements[0].contains("engine-startup-failure"))

        controller.setStatus(
            "Search failed: retry error",
            color: .systemRed,
            announcement: .error
        )
        XCTAssertEqual(announcements.count, 2)
        XCTAssertEqual(announcements[1], "Search failed: retry error")

        let status = try XCTUnwrap(
            findView(identifier: "search.status", in: rootView) as? NSTextField
        )
        XCTAssertEqual(status.stringValue, "Search failed: retry error")
    }

    func testPreLoadStatusUpdateDoesNotForceLoadViewAndPreservesStatusOnLoad() throws {
        var announcements: [String] = []
        let controller = SearchSidebarViewController(
            root: URL(fileURLWithPath: NSTemporaryDirectory()),
            makeSearcher: {
                try WorkspaceTextSearcher(
                    executableURL: URL(fileURLWithPath: "/usr/bin/true")
                )
            },
            runSearchTask: { _ in Task { @MainActor in } },
            postAccessibilityAnnouncement: { announcements.append($0) },
            onSelectMatch: { _ in }
        )

        XCTAssertFalse(controller.isViewLoaded)

        controller.setStatus(
            "Search failed: offline error",
            color: .systemRed,
            announcement: .error
        )

        XCTAssertFalse(controller.isViewLoaded)
        XCTAssertEqual(announcements, ["Search failed: offline error"])

        let rootView = controller.view
        XCTAssertTrue(controller.isViewLoaded)

        let status = try XCTUnwrap(
            findView(identifier: "search.status", in: rootView) as? NSTextField
        )
        XCTAssertFalse(status.isHidden)
        XCTAssertEqual(status.stringValue, "Search failed: offline error")
        XCTAssertEqual(status.textColor, .systemRed)

        controller.setStatus(
            "Search cancelled.",
            announcement: .cancellation
        )
        XCTAssertEqual(announcements, ["Search failed: offline error", "Search cancelled."])
    }

    func testProductionAnnouncementPostsSafelyWithAndWithoutWindow() throws {
        let controller = makeController()

        XCTAssertFalse(controller.isViewLoaded)

        controller.setStatus("Pre-load status", announcement: .completion)
        XCTAssertFalse(controller.isViewLoaded)

        let rootView = controller.view
        XCTAssertTrue(controller.isViewLoaded)

        controller.setStatus("Post-load detached status", announcement: .completion)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = rootView

        controller.setStatus("Post-load attached status", announcement: .completion)

        let status = try XCTUnwrap(
            findView(identifier: "search.status", in: rootView) as? NSTextField
        )
        XCTAssertEqual(status.stringValue, "Post-load attached status")
    }
}
