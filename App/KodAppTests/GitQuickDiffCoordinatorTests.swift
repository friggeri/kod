import CodeViewport
import GitCore
import XCTest
@testable import Kod

/// Headless coverage for the shared Quick Diff request/projection/error
/// policy: per-consumer request channels that cancel only themselves, and
/// the single mapping from a `GitFileDiff` to the provider, label and
/// unavailable-message Quick Diff shows. No Git process, editor group or
/// workspace controller is constructed.
@MainActor
final class GitQuickDiffCoordinatorTests: XCTestCase {
    // MARK: - Request channels

    func testEachChannelHasItsOwnGenerationSequence() {
        var registry = GitQuickDiffRequestRegistry()

        let sidebar = registry.begin(.sidebarSelection)
        let visible = registry.begin(.visibleEditors)

        XCTAssertTrue(registry.isCurrent(sidebar, in: .sidebarSelection))
        XCTAssertTrue(registry.isCurrent(visible, in: .visibleEditors))
    }

    func testSupersedingOneChannelLeavesTheOtherCurrent() {
        var registry = GitQuickDiffRequestRegistry()
        let sidebar = registry.begin(.sidebarSelection)
        let visible = registry.begin(.visibleEditors)

        _ = registry.begin(.visibleEditors)

        XCTAssertTrue(
            registry.isCurrent(sidebar, in: .sidebarSelection),
            "A visible-editor refresh must not cancel the sidebar's request"
        )
        XCTAssertFalse(registry.isCurrent(visible, in: .visibleEditors))
    }

    func testInvalidatingOneChannelLeavesTheOtherCurrent() {
        var registry = GitQuickDiffRequestRegistry()
        let sidebar = registry.begin(.sidebarSelection)
        let visible = registry.begin(.visibleEditors)

        registry.invalidate(.sidebarSelection)

        XCTAssertFalse(registry.isCurrent(sidebar, in: .sidebarSelection))
        XCTAssertTrue(registry.isCurrent(visible, in: .visibleEditors))
    }

    func testGenerationsIncreaseMonotonicallyPerChannel() {
        var registry = GitQuickDiffRequestRegistry()
        XCTAssertEqual(registry.generation(for: .sidebarSelection), 0)

        let first = registry.begin(.sidebarSelection)
        let second = registry.begin(.sidebarSelection)

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
        XCTAssertFalse(registry.isCurrent(first, in: .sidebarSelection))
    }

    // MARK: - Shared policy

    private func makeHunk() -> GitDiffHunk {
        GitDiffHunk(
            oldStart: 1, oldCount: 2, newStart: 1, newCount: 2,
            sectionHeading: nil,
            lines: [
                GitDiffLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "same"),
                GitDiffLine(kind: .removed, oldLineNumber: 2, newLineNumber: nil, text: "old"),
                GitDiffLine(kind: .added, oldLineNumber: nil, newLineNumber: 2, text: "new")
            ]
        )
    }

    private func makeDiff(
        kind: GitDiffFileChange.Kind = .modified,
        oldMode: String? = nil,
        newMode: String? = nil
    ) -> GitFileDiff {
        GitFileDiff(
            change: GitDiffFileChange(
                kind: kind,
                oldPath: nil,
                newPath: "f.txt",
                oldMode: oldMode,
                newMode: newMode
            ),
            content: .text(hunks: [makeHunk()])
        )
    }

    func testDiffTargetsMapToTheirQuickDiffRole() {
        XCTAssertEqual(
            GitQuickDiffPolicy.label(for: GitQuickDiffPolicy.role(for: .indexVsHead)),
            "Index"
        )
        XCTAssertEqual(
            GitQuickDiffPolicy.provider(
                for: GitQuickDiffPolicy.role(for: .indexVsHead)
            ).id,
            GitQuickDiffProvider.staged.id
        )
        XCTAssertEqual(
            GitQuickDiffPolicy.provider(
                for: GitQuickDiffPolicy.role(for: .workingTreeVsIndex)
            ).id,
            GitQuickDiffProvider.workingTree.id
        )
        XCTAssertEqual(
            GitQuickDiffPolicy.label(
                for: GitQuickDiffPolicy.role(for: .workingTreeVsHead)
            ),
            "Working Tree"
        )
        XCTAssertEqual(
            GitQuickDiffPolicy.provider(
                for: GitQuickDiffPolicy.role(for: .workingTreeVsHead)
            ).id,
            "working-tree-head"
        )
    }

    func testSourcesAreProjectedForTheirRoleAndLayer() {
        let source = GitQuickDiffPolicy.source(
            diff: makeDiff(),
            role: .workingTree,
            layer: .primary
        )

        XCTAssertEqual(source.label, "Working Tree")
        XCTAssertEqual(source.layer, .primary)
        XCTAssertEqual(source.projection.provider.id, GitQuickDiffProvider.workingTree.id)
        XCTAssertFalse(source.projection.hunks.isEmpty)
    }

    func testStagedOverlaySuppressesMarksAlreadyShownByThePrimaryLayer() {
        let diff = makeDiff()
        let primary = GitQuickDiffPolicy.source(
            diff: diff,
            role: .workingTree,
            layer: .primary
        )
        let overlay = GitQuickDiffPolicy.source(
            diff: diff,
            role: .index,
            layer: .secondary,
            suppressingMarksOverlapping: primary
        )
        let plainOverlay = GitQuickDiffPolicy.source(
            diff: diff,
            role: .index,
            layer: .secondary
        )

        XCTAssertEqual(overlay.label, "Index")
        XCTAssertEqual(overlay.layer, .secondary)
        XCTAssertLessThan(
            overlay.projection.hunks.flatMap(\.marks).count,
            plainOverlay.projection.hunks.flatMap(\.marks).count
        )
    }

    func testGitlinkDiffsAreDetectedFromEitherSideOfTheModePair() {
        XCTAssertTrue(GitQuickDiffPolicy.isGitlink(makeDiff(oldMode: "160000")))
        XCTAssertTrue(GitQuickDiffPolicy.isGitlink(makeDiff(newMode: "160000")))
        XCTAssertFalse(
            GitQuickDiffPolicy.isGitlink(makeDiff(oldMode: "100644", newMode: "100644"))
        )
    }

    func testUnavailableMessagesAreSharedByBothConsumers() {
        XCTAssertEqual(
            GitQuickDiffPolicy.conflictedMessage,
            "Inline Git changes are unavailable while this file has unresolved conflicts."
        )
        XCTAssertEqual(
            GitQuickDiffPolicy.binaryMessage,
            "Binary files do not have an inline text diff."
        )
        XCTAssertEqual(
            GitQuickDiffPolicy.noInlineDifferencesMessage,
            "This change has no inline line differences."
        )
        XCTAssertEqual(
            GitQuickDiffPolicy.loadFailureMessage,
            "Git diff could not be loaded."
        )
    }

    // MARK: - Selection liveness

    private func entry(
        indexStatus: GitStatusChangeCode,
        worktreeStatus: GitStatusChangeCode
    ) -> GitStatusEntry {
        GitStatusEntry(
            path: "f.txt",
            shape: .ordinary(indexStatus: indexStatus, worktreeStatus: worktreeStatus)
        )
    }

    func testStagedSelectionSurvivesOnlyWhileTheIndexStillDiffers() {
        XCTAssertTrue(
            GitQuickDiffPolicy.selection(
                .indexVsHead,
                stillAppliesTo: entry(indexStatus: .modified, worktreeStatus: .unmodified)
            )
        )
        XCTAssertFalse(
            GitQuickDiffPolicy.selection(
                .indexVsHead,
                stillAppliesTo: entry(indexStatus: .unmodified, worktreeStatus: .modified)
            )
        )
    }

    func testWorkingTreeSelectionSurvivesForUnstagedUntrackedAndConflicted() {
        XCTAssertTrue(
            GitQuickDiffPolicy.selection(
                .workingTreeVsIndex,
                stillAppliesTo: entry(indexStatus: .unmodified, worktreeStatus: .modified)
            )
        )
        XCTAssertTrue(
            GitQuickDiffPolicy.selection(
                .workingTreeVsIndex,
                stillAppliesTo: GitStatusEntry(path: "f.txt", shape: .untracked)
            )
        )
        XCTAssertFalse(
            GitQuickDiffPolicy.selection(
                .workingTreeVsIndex,
                stillAppliesTo: entry(indexStatus: .modified, worktreeStatus: .unmodified)
            )
        )
    }

    func testWorkingTreeAgainstHeadSelectionSurvivesForEitherSide() {
        XCTAssertTrue(
            GitQuickDiffPolicy.selection(
                .workingTreeVsHead,
                stillAppliesTo: entry(indexStatus: .modified, worktreeStatus: .unmodified)
            )
        )
        XCTAssertTrue(
            GitQuickDiffPolicy.selection(
                .workingTreeVsHead,
                stillAppliesTo: entry(indexStatus: .unmodified, worktreeStatus: .modified)
            )
        )
        XCTAssertFalse(
            GitQuickDiffPolicy.selection(
                .workingTreeVsHead,
                stillAppliesTo: entry(indexStatus: .unmodified, worktreeStatus: .unmodified)
            )
        )
    }
}
