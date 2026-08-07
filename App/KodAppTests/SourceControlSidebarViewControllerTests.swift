import AppKit
import GitCore
import XCTest
@testable import Kod

/// Headless coverage for the Source Control sidebar (SPEC 9.1): file
/// status grouped into conflicted/staged/unstaged/untracked/ignored
/// sections, and selecting a row reports the correct diff target for its
/// group. Constructs the view controller directly and drives it via its
/// public API — no window is ever made key and `KodAppUITests`/
/// `XCUIApplication` are never involved.
@MainActor
final class SourceControlSidebarViewControllerTests: XCTestCase {
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

    func testUpdateGroupsEntriesIntoSectionsInFixedOrder() throws {
        var selections: [SourceControlSidebarViewController.FileSelection] = []
        let controller = SourceControlSidebarViewController { selection in
            selections.append(selection)
        }
        controller.loadView()

        let staged = GitStatusEntry(path: "staged.txt", shape: .ordinary(indexStatus: .added, worktreeStatus: .unmodified))
        let unstaged = GitStatusEntry(path: "unstaged.txt", shape: .ordinary(indexStatus: .unmodified, worktreeStatus: .modified))
        let untracked = GitStatusEntry(path: "untracked.txt", shape: .untracked)
        let ignored = GitStatusEntry(path: "ignored.log", shape: .ignored)
        let snapshot = GitStatusSnapshot(entries: [staged, unstaged, untracked, ignored])
        controller.update(snapshot: snapshot)

        let outline = try XCTUnwrap(findOutlineView(in: controller.view))
        XCTAssertEqual(outline.numberOfChildren(ofItem: nil), 4)
        let firstSection = try XCTUnwrap(outline.child(0, ofItem: nil) as? SourceControlSidebarViewController.Section)
        XCTAssertEqual(firstSection.kind, .staged)
        let secondSection = try XCTUnwrap(outline.child(1, ofItem: nil) as? SourceControlSidebarViewController.Section)
        XCTAssertEqual(secondSection.kind, .unstaged)
        let thirdSection = try XCTUnwrap(outline.child(2, ofItem: nil) as? SourceControlSidebarViewController.Section)
        XCTAssertEqual(thirdSection.kind, .untracked)
        let fourthSection = try XCTUnwrap(outline.child(3, ofItem: nil) as? SourceControlSidebarViewController.Section)
        XCTAssertEqual(fourthSection.kind, .ignored)
    }

    func testConflictedSectionAppearsFirstWhenPresent() throws {
        let controller = SourceControlSidebarViewController { _ in }
        controller.loadView()

        let conflicted = GitStatusEntry(
            path: "shared.txt",
            shape: .unmerged(
                code: "UU",
                base: nil,
                ours: GitUnmergedStage(mode: "100644", objectID: String(repeating: "a", count: 40)),
                theirs: GitUnmergedStage(mode: "100644", objectID: String(repeating: "b", count: 40))
            )
        )
        let staged = GitStatusEntry(path: "staged.txt", shape: .ordinary(indexStatus: .added, worktreeStatus: .unmodified))
        controller.update(snapshot: GitStatusSnapshot(entries: [conflicted, staged]))

        let outline = try XCTUnwrap(findOutlineView(in: controller.view))
        let firstSection = try XCTUnwrap(outline.child(0, ofItem: nil) as? SourceControlSidebarViewController.Section)
        XCTAssertEqual(firstSection.kind, .conflicted)
    }

    func testSelectingAStagedRowReportsIndexVsHeadTarget() throws {
        var selections: [SourceControlSidebarViewController.FileSelection] = []
        let controller = SourceControlSidebarViewController { selection in
            selections.append(selection)
        }
        controller.loadView()

        let staged = GitStatusEntry(path: "staged.txt", shape: .ordinary(indexStatus: .added, worktreeStatus: .unmodified))
        controller.update(snapshot: GitStatusSnapshot(entries: [staged]))

        let outline = try XCTUnwrap(findOutlineView(in: controller.view))
        outline.expandItem(outline.child(0, ofItem: nil))
        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        outline.sendAction(outline.action, to: outline.target)

        XCTAssertEqual(selections.count, 1)
        XCTAssertEqual(selections.first?.path, "staged.txt")
        XCTAssertEqual(selections.first?.target, .indexVsHead)
        XCTAssertFalse(selections.first?.isUntracked ?? true)
    }

    func testSelectingAnUntrackedRowReportsIsUntrackedTrue() throws {
        var selections: [SourceControlSidebarViewController.FileSelection] = []
        let controller = SourceControlSidebarViewController { selection in
            selections.append(selection)
        }
        controller.loadView()

        let untracked = GitStatusEntry(path: "new.txt", shape: .untracked)
        controller.update(snapshot: GitStatusSnapshot(entries: [untracked]))

        let outline = try XCTUnwrap(findOutlineView(in: controller.view))
        outline.expandItem(outline.child(0, ofItem: nil))
        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        outline.sendAction(outline.action, to: outline.target)

        XCTAssertEqual(selections.first?.isUntracked, true)
    }

    func testStatusPresentationsUseFamiliarGitLettersAndColorRoles() {
        let modified = GitStatusEntry(
            path: "modified.txt",
            shape: .ordinary(indexStatus: .unmodified, worktreeStatus: .modified)
        )
        let added = GitStatusEntry(
            path: "added.txt",
            shape: .ordinary(indexStatus: .added, worktreeStatus: .unmodified)
        )
        let deleted = GitStatusEntry(
            path: "deleted.txt",
            shape: .ordinary(indexStatus: .unmodified, worktreeStatus: .deleted)
        )
        let untracked = GitStatusEntry(path: "new.txt", shape: .untracked)

        XCTAssertEqual(
            SourceControlSidebarViewController.statusPresentation(for: modified, in: .unstaged),
            .init(letter: "M", colorRole: .modified)
        )
        XCTAssertEqual(
            SourceControlSidebarViewController.statusPresentation(for: added, in: .staged),
            .init(letter: "A", colorRole: .added)
        )
        XCTAssertEqual(
            SourceControlSidebarViewController.statusPresentation(for: deleted, in: .unstaged),
            .init(letter: "D", colorRole: .deleted)
        )
        XCTAssertEqual(
            SourceControlSidebarViewController.statusPresentation(for: untracked, in: .untracked),
            .init(letter: "U", colorRole: .untracked)
        )
    }

    func testEntryChangedOnBothSidesUsesTheSelectedSectionsDiffTarget() throws {
        var selections: [SourceControlSidebarViewController.FileSelection] = []
        let controller = SourceControlSidebarViewController { selections.append($0) }
        controller.loadView()
        let changedOnBothSides = GitStatusEntry(
            path: "both.txt",
            shape: .ordinary(indexStatus: .added, worktreeStatus: .modified)
        )
        controller.update(snapshot: GitStatusSnapshot(entries: [changedOnBothSides]))

        let outline = try XCTUnwrap(findOutlineView(in: controller.view))
        let unstagedRow = (0..<outline.numberOfRows).first { row in
            guard let item = outline.item(atRow: row) as? SourceControlSidebarViewController.FileItem else {
                return false
            }
            return item.sectionKind == .unstaged
        }
        outline.selectRowIndexes(
            IndexSet(integer: try XCTUnwrap(unstagedRow)),
            byExtendingSelection: false
        )
        outline.sendAction(outline.action, to: outline.target)

        XCTAssertEqual(selections.first?.target, .workingTreeVsIndex)
    }

    func testNilSnapshotClearsSectionsAndShowsNoRepositoryStatus() throws {
        let controller = SourceControlSidebarViewController { _ in }
        controller.loadView()

        let staged = GitStatusEntry(path: "staged.txt", shape: .ordinary(indexStatus: .added, worktreeStatus: .unmodified))
        controller.update(snapshot: GitStatusSnapshot(entries: [staged]))
        controller.update(snapshot: nil)

        let outline = try XCTUnwrap(findOutlineView(in: controller.view))
        XCTAssertEqual(outline.numberOfChildren(ofItem: nil), 0)
    }
}
