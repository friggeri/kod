import AppKit
import FontCore
import GitCore
import ThemeCore
import XCTest
@testable import KodUIComponents
@testable import GitUI

/// Headless AppKit coverage for the read-only Source Control sidebar. No
/// application launch, key window, XCUIApplication, or UI automation is used.
@MainActor
final class SourceControlSidebarViewControllerTests: XCTestCase {
    private func makeController(
        onSelectFile: @escaping (
            SourceControlSidebarViewController.FileSelection
        ) -> Void = { _ in }
    ) throws -> SourceControlSidebarViewController {
        SourceControlSidebarViewController(
            appearanceCenter: AppearanceCenter(
                testing: AppearanceCenter.Snapshot(
                    theme: BundledThemes.defaultTheme(
                        isDark: AppearanceCenter.systemIsDark(),
                        isHighContrast: AppearanceCenter
                            .systemIsHighContrast()
                    ),
                    fontSettings: .default
                )
            ),
            onSelectFile: onSelectFile
        )
    }

    private func findView<T: NSView>(
        ofType type: T.Type,
        identifier: String? = nil,
        in view: NSView
    ) -> T? {
        if let match = view as? T,
           identifier == nil || match.identifier?.rawValue == identifier {
            return match
        }
        for subview in view.subviews {
            if let found = findView(ofType: type, identifier: identifier, in: subview) {
                return found
            }
        }
        return nil
    }

    private func outline(in controller: SourceControlSidebarViewController) throws -> NSOutlineView {
        try XCTUnwrap(findView(ofType: NSOutlineView.self, in: controller.view))
    }

    private func statusLabel(
        in controller: SourceControlSidebarViewController
    ) throws -> NSTextField {
        try XCTUnwrap(
            findView(
                ofType: NSTextField.self,
                identifier: "sourceControl.status",
                in: controller.view
            )
        )
    }

    private func section(
        _ kind: SourceControlSidebarViewController.Section.Kind,
        in outline: NSOutlineView
    ) -> SourceControlSidebarViewController.Section? {
        (0..<outline.numberOfChildren(ofItem: nil))
            .compactMap { outline.child($0, ofItem: nil) as? SourceControlSidebarViewController.Section }
            .first { $0.kind == kind }
    }

    private func row(
        path: String,
        group: SourceControlSidebarViewController.Section.Kind,
        in outline: NSOutlineView
    ) -> Int? {
        (0..<outline.numberOfRows).first { row in
            guard let item = outline.item(atRow: row) as? SourceControlSidebarViewController.FileItem else {
                return false
            }
            return item.entry.path == path && item.sectionKind == group
        }
    }

    func testUpdateBuildsThreeVSCodeGroupsInOrderAndMixesUntrackedChanges() throws {
        let controller = try makeController()
        controller.loadView()

        let conflicted = GitStatusEntry(
            path: "conflicted.txt",
            shape: .unmerged(
                code: "UU",
                base: nil,
                ours: GitUnmergedStage(
                    mode: "100644",
                    objectID: String(repeating: "a", count: 40)
                ),
                theirs: GitUnmergedStage(
                    mode: "100644",
                    objectID: String(repeating: "b", count: 40)
                )
            )
        )
        let staged = GitStatusEntry(
            path: "staged.txt",
            shape: .ordinary(indexStatus: .added, worktreeStatus: .unmodified)
        )
        let unstaged = GitStatusEntry(
            path: "unstaged.txt",
            shape: .ordinary(indexStatus: .unmodified, worktreeStatus: .modified)
        )
        let untracked = GitStatusEntry(path: "untracked.txt", shape: .untracked)
        let ignored = GitStatusEntry(path: "ignored.log", shape: .ignored)
        controller.update(
            snapshot: GitStatusSnapshot(
                entries: [ignored, untracked, unstaged, staged, conflicted]
            )
        )

        let outline = try outline(in: controller)
        XCTAssertEqual(outline.numberOfChildren(ofItem: nil), 3)

        let merge = try XCTUnwrap(
            outline.child(0, ofItem: nil) as? SourceControlSidebarViewController.Section
        )
        XCTAssertEqual(merge.kind, .mergeChanges)
        XCTAssertEqual(merge.title, "Merge Changes")

        let stagedSection = try XCTUnwrap(
            outline.child(1, ofItem: nil) as? SourceControlSidebarViewController.Section
        )
        XCTAssertEqual(stagedSection.kind, .stagedChanges)

        let changes = try XCTUnwrap(
            outline.child(2, ofItem: nil) as? SourceControlSidebarViewController.Section
        )
        XCTAssertEqual(changes.kind, .changes)
        XCTAssertEqual(changes.entries.map(\.path), ["unstaged.txt", "untracked.txt"])
        XCTAssertFalse(
            [merge, stagedSection, changes]
                .flatMap(\.entries)
                .contains(where: \.isIgnored)
        )
    }

    func testRowsAreSortedByFullPathWithinEachGroup() throws {
        let controller = try makeController()
        controller.loadView()
        controller.update(
            snapshot: GitStatusSnapshot(entries: [
                GitStatusEntry(path: "zeta/file.swift", shape: .untracked),
                GitStatusEntry(
                    path: "Alpha/file.swift",
                    shape: .ordinary(indexStatus: .unmodified, worktreeStatus: .modified)
                ),
                GitStatusEntry(path: "beta/file.swift", shape: .untracked)
            ])
        )

        let changes = try XCTUnwrap(section(.changes, in: outline(in: controller)))
        XCTAssertEqual(
            changes.entries.map(\.path),
            ["Alpha/file.swift", "beta/file.swift", "zeta/file.swift"]
        )
    }

    func testStatusPresentationsCoverGroupSpecificLettersAndThemeRoles() {
        let stagedModified = GitStatusEntry(
            path: "modified.txt",
            shape: .ordinary(indexStatus: .modified, worktreeStatus: .unmodified)
        )
        let stagedDeleted = GitStatusEntry(
            path: "deleted.txt",
            shape: .ordinary(indexStatus: .deleted, worktreeStatus: .unmodified)
        )
        let copied = GitStatusEntry(
            path: "copy.txt",
            shape: .renameOrCopy(
                indexStatus: .copied,
                worktreeStatus: .unmodified,
                similarityPercentage: 100,
                originalPath: "source.txt"
            )
        )
        let typeChanged = GitStatusEntry(
            path: "typed.txt",
            shape: .ordinary(indexStatus: .unmodified, worktreeStatus: .typeChanged)
        )
        let untracked = GitStatusEntry(path: "new.txt", shape: .untracked)

        XCTAssertEqual(
            SourceControlSidebarViewController.statusPresentation(
                for: stagedModified,
                in: .stagedChanges
            ),
            GitStatusPresentation(status: .modified, colorRole: .stagedModified)
        )
        XCTAssertEqual(
            SourceControlSidebarViewController.statusPresentation(
                for: stagedDeleted,
                in: .stagedChanges
            ),
            GitStatusPresentation(status: .deleted, colorRole: .stagedDeleted)
        )
        XCTAssertEqual(
            SourceControlSidebarViewController.statusPresentation(
                for: copied,
                in: .stagedChanges
            ),
            GitStatusPresentation(status: .copied, colorRole: .renamed)
        )
        XCTAssertEqual(
            SourceControlSidebarViewController.statusPresentation(
                for: typeChanged,
                in: .changes
            ),
            GitStatusPresentation(status: .typeChanged, colorRole: .modified)
        )
        XCTAssertEqual(
            SourceControlSidebarViewController.statusPresentation(
                for: untracked,
                in: .changes
            ),
            GitStatusPresentation(status: .untracked, colorRole: .untracked)
        )
    }

    func testChangedOnBothSidesAppearsInBothGroupsWithCorrectDiffTargets() throws {
        var selections: [SourceControlSidebarViewController.FileSelection] = []
        let controller = try makeController {
            selections.append($0)
        }
        controller.loadView()
        let changedOnBothSides = GitStatusEntry(
            path: "both.txt",
            shape: .ordinary(indexStatus: .added, worktreeStatus: .modified)
        )
        controller.update(snapshot: GitStatusSnapshot(entries: [changedOnBothSides]))

        let outline = try outline(in: controller)
        let stagedRow = try XCTUnwrap(row(path: "both.txt", group: .stagedChanges, in: outline))
        let changesRow = try XCTUnwrap(row(path: "both.txt", group: .changes, in: outline))

        outline.selectRowIndexes(IndexSet(integer: stagedRow), byExtendingSelection: false)
        outline.sendAction(outline.action, to: outline.target)
        outline.selectRowIndexes(IndexSet(integer: changesRow), byExtendingSelection: false)
        outline.sendAction(outline.action, to: outline.target)

        XCTAssertEqual(selections.map(\.target), [.indexVsHead, .workingTreeVsIndex])
        XCTAssertEqual(selections.map(\.isUntracked), [false, false])
    }

    func testSelectingMixedUntrackedRowUsesWorkingTreeDiffAndUntrackedFlag() throws {
        var selections: [SourceControlSidebarViewController.FileSelection] = []
        let controller = try makeController {
            selections.append($0)
        }
        controller.loadView()
        controller.update(
            snapshot: GitStatusSnapshot(entries: [
                GitStatusEntry(path: "new.txt", shape: .untracked)
            ])
        )

        let outline = try outline(in: controller)
        let untrackedRow = try XCTUnwrap(row(path: "new.txt", group: .changes, in: outline))
        outline.selectRowIndexes(IndexSet(integer: untrackedRow), byExtendingSelection: false)
        outline.sendAction(outline.action, to: outline.target)

        XCTAssertEqual(selections.first?.target, .workingTreeVsIndex)
        XCTAssertEqual(selections.first?.isUntracked, true)
    }

    func testSelectingMergeChangePreservesConflictDiffTarget() throws {
        var selections: [SourceControlSidebarViewController.FileSelection] = []
        let controller = try makeController {
            selections.append($0)
        }
        controller.loadView()
        controller.update(
            snapshot: GitStatusSnapshot(entries: [
                GitStatusEntry(
                    path: "conflicted.txt",
                    shape: .unmerged(
                        code: "UU",
                        base: nil,
                        ours: GitUnmergedStage(
                            mode: "100644",
                            objectID: String(repeating: "a", count: 40)
                        ),
                        theirs: GitUnmergedStage(
                            mode: "100644",
                            objectID: String(repeating: "b", count: 40)
                        )
                    )
                )
            ])
        )

        let outline = try outline(in: controller)
        let conflictRow = try XCTUnwrap(
            row(path: "conflicted.txt", group: .mergeChanges, in: outline)
        )
        outline.selectRowIndexes(IndexSet(integer: conflictRow), byExtendingSelection: false)
        outline.sendAction(outline.action, to: outline.target)

        XCTAssertEqual(selections.first?.target, .workingTreeVsIndex)
        XCTAssertEqual(selections.first?.isUntracked, false)
    }

    func testFileRowsShowMaterialIconBasenameParentRenameBadgeAndDeletionStyle() throws {
        let controller = try makeController()
        controller.loadView()
        let renamed = GitStatusEntry(
            path: "Sources/New.swift",
            shape: .renameOrCopy(
                indexStatus: .renamed,
                worktreeStatus: .unmodified,
                similarityPercentage: 100,
                originalPath: "Sources/Old.swift"
            )
        )
        let deleted = GitStatusEntry(
            path: "Sources/Deleted.swift",
            shape: .ordinary(indexStatus: .unmodified, worktreeStatus: .deleted)
        )
        controller.update(snapshot: GitStatusSnapshot(entries: [deleted, renamed]))

        let outline = try outline(in: controller)
        let renameRow = try XCTUnwrap(row(path: "Sources/New.swift", group: .stagedChanges, in: outline))
        let renameCell = try XCTUnwrap(
            outline.view(atColumn: 0, row: renameRow, makeIfNecessary: true)
        )
        XCTAssertNotNil(
            findView(
                ofType: MaterialFileIconView.self,
                identifier: "sourceControl.fileIcon",
                in: renameCell
            )
        )
        XCTAssertEqual(
            findView(
                ofType: NSTextField.self,
                identifier: "sourceControl.fileName",
                in: renameCell
            )?.stringValue,
            "New.swift"
        )
        XCTAssertEqual(
            findView(
                ofType: NSTextField.self,
                identifier: "sourceControl.parentPath",
                in: renameCell
            )?.stringValue,
            "Sources"
        )
        XCTAssertTrue(
            findView(
                ofType: NSTextField.self,
                identifier: "sourceControl.renameContext",
                in: renameCell
            )?.stringValue.contains("Sources/Old.swift") == true
        )
        let renameBadge = try XCTUnwrap(
            findView(
                ofType: NSTextField.self,
                identifier: "sourceControl.statusBadge",
                in: renameCell
            )
        )
        XCTAssertEqual(renameBadge.stringValue, "R")
        XCTAssertTrue(
            renameBadge.textColor?.isEqual(
                ThemeColorAppKitBridge.nsColor(
                    BundledThemes.defaultTheme(
                        isDark: AppearanceCenter.systemIsDark(),
                        isHighContrast: AppearanceCenter
                            .systemIsHighContrast()
                    ).git.renamed
                )
            ) == true
        )
        XCTAssertTrue(
            findView(
                ofType: NSTextField.self,
                identifier: "sourceControl.fileName",
                in: renameCell
            )?.accessibilityLabel()?.contains("Renamed") == true
        )

        let deletedRow = try XCTUnwrap(row(path: "Sources/Deleted.swift", group: .changes, in: outline))
        let deletedCell = try XCTUnwrap(
            outline.view(atColumn: 0, row: deletedRow, makeIfNecessary: true)
        )
        let deletedName = try XCTUnwrap(
            findView(
                ofType: NSTextField.self,
                identifier: "sourceControl.fileName",
                in: deletedCell
            )
        )
        XCTAssertEqual(
            deletedName.attributedStringValue.attribute(
                .strikethroughStyle,
                at: 0,
                effectiveRange: nil
            ) as? Int,
            NSUnderlineStyle.single.rawValue
        )
        XCTAssertEqual(
            findView(
                ofType: NSTextField.self,
                identifier: "sourceControl.statusBadge",
                in: deletedCell
            )?.stringValue,
            "D"
        )
    }

    func testSectionCollapseStateSurvivesStatusRefresh() throws {
        let controller = try makeController()
        controller.loadView()
        controller.update(
            snapshot: GitStatusSnapshot(entries: [
                GitStatusEntry(
                    path: "staged.txt",
                    shape: .ordinary(indexStatus: .added, worktreeStatus: .unmodified)
                ),
                GitStatusEntry(
                    path: "changed.txt",
                    shape: .ordinary(indexStatus: .unmodified, worktreeStatus: .modified)
                )
            ])
        )

        let outline = try outline(in: controller)
        let changes = try XCTUnwrap(section(.changes, in: outline))
        outline.collapseItem(changes)
        XCTAssertFalse(outline.isItemExpanded(changes))

        controller.update(
            snapshot: GitStatusSnapshot(entries: [
                GitStatusEntry(
                    path: "staged.txt",
                    shape: .ordinary(indexStatus: .added, worktreeStatus: .unmodified)
                ),
                GitStatusEntry(path: "new.txt", shape: .untracked)
            ])
        )

        let refreshedChanges = try XCTUnwrap(section(.changes, in: outline))
        let refreshedStaged = try XCTUnwrap(section(.stagedChanges, in: outline))
        XCTAssertFalse(outline.isItemExpanded(refreshedChanges))
        XCTAssertTrue(outline.isItemExpanded(refreshedStaged))
    }

    func testCleanAndNonRepositoryStatesRemainDistinct() throws {
        let controller = try makeController()
        controller.loadView()

        controller.update(snapshot: GitStatusSnapshot(entries: []))
        XCTAssertEqual(try statusLabel(in: controller).stringValue, "No changes.")
        XCTAssertEqual(try outline(in: controller).numberOfChildren(ofItem: nil), 0)

        controller.update(snapshot: nil)
        XCTAssertEqual(try statusLabel(in: controller).stringValue, "No repository.")
        XCTAssertEqual(try outline(in: controller).numberOfChildren(ofItem: nil), 0)
    }
}
