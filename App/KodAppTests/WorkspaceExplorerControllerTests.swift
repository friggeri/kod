import AppKit
import GitCore
import GitUI
import ThemeCore
import WorkspaceCore
import XCTest
@testable import Kod

/// Headless coverage for `WorkspaceExplorerController`: the tree model it
/// keeps for the outline view, the reveal-filter policy for live updates,
/// its data source/decoration output, and the typed intents it emits. No
/// workspace session, window or Git process is involved.
@MainActor
final class WorkspaceExplorerControllerTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/workspace-explorer-tests")

    private func makeController(
        options: WorkspaceDiscoveryOptions = WorkspaceDiscoveryOptions(),
        decoration: @escaping (String, Bool) -> GitExplorerDecoration? = { _, _ in nil }
    ) -> WorkspaceExplorerController {
        WorkspaceExplorerController(
            discoveryOptions: { options },
            gitDecoration: decoration
        )
    }

    private func entry(
        _ relativePath: String,
        kind: WorkspaceFileKind = .file,
        isHidden: Bool = false,
        isIgnored: Bool = false
    ) -> WorkspaceFileEntry {
        WorkspaceFileEntry(
            url: root.appendingPathComponent(relativePath),
            relativePath: relativePath,
            kind: kind,
            isHidden: isHidden,
            isIgnored: isIgnored
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

    func testDiscoveryBatchesAreGroupedByParentPath() {
        let controller = makeController()

        controller.apply(
            WorkspaceDiscoveryBatch(
                entries: [
                    entry("src", kind: .directory),
                    entry("src/main.swift"),
                    entry("README.md")
                ],
                discoveredCount: 3
            )
        )

        XCTAssertEqual(
            (controller.entriesByParent[""] ?? []).map(\.relativePath).sorted(),
            ["README.md", "src"]
        )
        XCTAssertEqual(
            (controller.entriesByParent["src"] ?? []).map(\.relativePath),
            ["src/main.swift"]
        )
    }

    func testRescanClearsTheTreeAndNodeCache() {
        let controller = makeController()
        controller.apply(
            WorkspaceDiscoveryBatch(entries: [entry("a.txt")], discoveredCount: 1)
        )
        XCTAssertFalse(controller.children(of: "").isEmpty)

        controller.applyDiscoveryStatus(.scanning)

        XCTAssertTrue(controller.entriesByParent.isEmpty)
        XCTAssertTrue(controller.children(of: "").isEmpty)
    }

    func testAddOrUpdateReplacesAnExistingEntryWithoutDuplicating() {
        let controller = makeController()
        controller.addOrUpdate(entry("a.txt"))
        controller.addOrUpdate(entry("a.txt", isIgnored: true))

        let entries = controller.entriesByParent[""] ?? []
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].isIgnored)
    }

    func testRemoveEntryDropsItFromTheTree() {
        let controller = makeController()
        controller.addOrUpdate(entry("nested/a.txt"))
        XCTAssertEqual((controller.entriesByParent["nested"] ?? []).count, 1)

        controller.removeEntry(relativePath: "nested/a.txt")

        XCTAssertTrue((controller.entriesByParent["nested"] ?? []).isEmpty)
    }

    func testHiddenAndIgnoredEntriesOnlyJoinTheTreeWhenRevealed() {
        let hiding = makeController()
        XCTAssertFalse(hiding.shouldInclude(entry(".env", isHidden: true)))
        XCTAssertFalse(hiding.shouldInclude(entry("build/out", isIgnored: true)))
        XCTAssertTrue(hiding.shouldInclude(entry("a.txt")))

        let revealing = makeController(
            options: WorkspaceDiscoveryOptions(includeHidden: true, includeIgnored: true)
        )
        XCTAssertTrue(revealing.shouldInclude(entry(".env", isHidden: true)))
        XCTAssertTrue(revealing.shouldInclude(entry("build/out", isIgnored: true)))
    }

    func testChildrenSortDirectoriesFirstAndReuseCachedNodes() {
        let controller = makeController()
        controller.apply(
            WorkspaceDiscoveryBatch(
                entries: [
                    entry("b.txt"),
                    entry("a.txt"),
                    entry("zzz", kind: .directory)
                ],
                discoveredCount: 3
            )
        )

        let children = controller.children(of: "")
        XCTAssertEqual(
            children.map(\.entry.relativePath),
            ["zzz", "a.txt", "b.txt"]
        )
        XCTAssertTrue(children[0] === controller.children(of: "")[0])
    }

    func testUpdatingAnEntryInvalidatesItsCachedNode() {
        let controller = makeController()
        controller.addOrUpdate(entry("a.txt"))
        let first = controller.children(of: "")[0]

        controller.addOrUpdate(entry("a.txt", isIgnored: true))

        XCTAssertFalse(first === controller.children(of: "")[0])
    }

    func testOutlineDataSourceMirrorsTheTree() {
        let controller = makeController()
        _ = controller.makeView()
        controller.apply(
            WorkspaceDiscoveryBatch(
                entries: [entry("src", kind: .directory), entry("src/main.swift")],
                discoveredCount: 2
            )
        )

        let outline = controller.outlineView
        XCTAssertEqual(controller.outlineView(outline, numberOfChildrenOfItem: nil), 1)
        let directory = controller.outlineView(outline, child: 0, ofItem: nil)
        XCTAssertTrue(controller.outlineView(outline, isItemExpandable: directory))
        XCTAssertEqual(
            controller.outlineView(outline, numberOfChildrenOfItem: directory),
            1
        )
        let file = controller.outlineView(outline, child: 0, ofItem: directory)
        XCTAssertFalse(controller.outlineView(outline, isItemExpandable: file))
    }

    func testCellRendersNameKindAndGitDecorationIntoOneAccessibilityLabel() throws {
        let controller = makeController(
            decoration: { relativePath, _ in
                relativePath == "a.txt"
                    ? GitExplorerDecoration(
                        presentation: GitStatusPresentation(status: .modified, colorRole: .modified),
                        indicator: .statusLetter
                    )
                    : nil
            }
        )
        _ = controller.makeView()
        controller.setDecorationColors(BundledThemes.dark.git)
        controller.addOrUpdate(entry("a.txt"))

        let outline = controller.outlineView
        let item = controller.outlineView(outline, child: 0, ofItem: nil)
        let cell = try XCTUnwrap(
            controller.outlineView(
                outline,
                viewFor: outline.outlineTableColumn,
                item: item
            ) as? NSTableCellView
        )

        XCTAssertEqual(cell.textField?.stringValue, "a.txt")
        let label = try XCTUnwrap(cell.textField?.accessibilityLabel())
        XCTAssertTrue(label.hasPrefix("a.txt, file"))
        XCTAssertTrue(
            label.contains(
                GitStatusPresentation(status: .modified, colorRole: .modified)
                    .accessibilityDescription
            )
        )
    }

    func testCellOmitsGitDecorationWhenThereIsNone() throws {
        let controller = makeController()
        _ = controller.makeView()
        controller.addOrUpdate(entry("plain.txt"))

        let outline = controller.outlineView
        let item = controller.outlineView(outline, child: 0, ofItem: nil)
        let cell = try XCTUnwrap(
            controller.outlineView(
                outline,
                viewFor: outline.outlineTableColumn,
                item: item
            ) as? NSTableCellView
        )

        XCTAssertEqual(cell.textField?.accessibilityLabel(), "plain.txt, file")
        XCTAssertEqual(cell.textField?.textColor, .labelColor)
    }

    func testRevealTogglesEmitAVisibilityIntentWithBothFlags() throws {
        let controller = makeController()
        let container = controller.makeView()
        var intents: [WorkspaceExplorerController.Intent] = []
        controller.onIntent = { intents.append($0) }

        let hidden = try XCTUnwrap(
            findView(identifier: "workspace.showHiddenFiles", in: container) as? NSButton
        )
        let ignored = try XCTUnwrap(
            findView(identifier: "workspace.showIgnoredFiles", in: container) as? NSButton
        )
        hidden.state = .on
        hidden.sendAction(hidden.action, to: hidden.target)
        ignored.state = .on
        ignored.sendAction(ignored.action, to: ignored.target)

        XCTAssertEqual(intents.count, 2)
        guard case .changeVisibility(let first) = intents[0],
              case .changeVisibility(let second) = intents[1] else {
            return XCTFail("Expected two visibility intents")
        }
        XCTAssertTrue(first.includeHidden)
        XCTAssertFalse(first.includeIgnored)
        XCTAssertTrue(second.includeHidden)
        XCTAssertTrue(second.includeIgnored)
    }

    func testExplorerViewKeepsItsAccessibilityIdentifiersAndContextMenu() throws {
        let controller = makeController()
        let container = controller.makeView()

        XCTAssertNotNil(findView(identifier: "workspace.explorer", in: container))
        XCTAssertNotNil(findView(identifier: "workspace.discoveryStatus", in: container))
        XCTAssertNotNil(findView(identifier: "workspace.showHiddenFiles", in: container))
        XCTAssertNotNil(findView(identifier: "workspace.showIgnoredFiles", in: container))

        let menu = try XCTUnwrap(controller.outlineView.menu)
        XCTAssertEqual(menu.items.count, 1)
        // Left target-less on purpose so the command travels the responder
        // chain to the workspace controller, exactly like the main menu.
        XCTAssertNil(menu.items[0].target)
        XCTAssertEqual(
            menu.items[0].action,
            #selector(WorkspaceViewController.showGitBlameForSelectedFile(_:))
        )
    }

    func testActionTargetIsNilWithoutAClickedOrSelectedFileRow() {
        let controller = makeController()
        _ = controller.makeView()
        XCTAssertNil(controller.actionTargetFileRelativePath)
    }
}
