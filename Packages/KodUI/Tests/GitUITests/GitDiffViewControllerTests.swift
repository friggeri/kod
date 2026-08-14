import AppKit
import CodeViewport
import GitCore
import SourceModel
import ThemeCore
import XCTest
@testable import GitUI

/// Headless coverage for the Git diff viewer (SPEC 9.1: unified and
/// side-by-side modes). Exercises the pure row-building methods plus the
/// controller's public `update(diff:)`/`setMode(_:)` API — never a
/// window, mouse, or keyboard event.
@MainActor
final class GitDiffViewControllerTests: XCTestCase {
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

    func testUnifiedRowsPreserveLinearOrderAndKind() {
        let rows = GitDiffViewController.unifiedRows(for: [makeHunk()])
        XCTAssertEqual(rows, [
            GitDiffViewController.UnifiedRow(kind: .context, text: "same"),
            GitDiffViewController.UnifiedRow(kind: .removed, text: "old"),
            GitDiffViewController.UnifiedRow(kind: .added, text: "new")
        ])
    }

    func testSideBySideDisplayRowsPairRemovedAndAddedLines() {
        let rows = GitDiffViewController.sideBySideDisplayRows(for: [makeHunk()])
        XCTAssertEqual(rows, [
            GitDiffViewController.SideBySideDisplayRow(leftText: "same", rightText: "same", leftMarker: " ", rightMarker: " "),
            GitDiffViewController.SideBySideDisplayRow(leftText: "old", rightText: "new", leftMarker: "-", rightMarker: "+")
        ])
    }

    func testUpdateWithNilDiffClearsPreviousState() {
        let controller = GitDiffViewController()
        controller.loadView()
        let change = GitDiffFileChange(kind: .modified, oldPath: nil, newPath: "f.txt")
        controller.update(diff: GitFileDiff(change: change, content: .text(hunks: [makeHunk()])))
        XCTAssertNotNil(controller.diff)

        controller.update(diff: nil)
        XCTAssertNil(controller.diff)
    }

    func testSetModeUpdatesTheObservableModeProperty() {
        let controller = GitDiffViewController()
        controller.loadView()
        XCTAssertEqual(controller.mode, .unified)

        controller.setMode(.sideBySide)
        XCTAssertEqual(controller.mode, .sideBySide)

        controller.setMode(.unified)
        XCTAssertEqual(controller.mode, .unified)
    }

    func testBinaryDiffIsHandledWithoutCrashing() {
        let controller = GitDiffViewController()
        controller.loadView()
        let change = GitDiffFileChange(kind: .modified, oldPath: nil, newPath: "image.bin")
        controller.update(diff: GitFileDiff(change: change, content: .binary))
        XCTAssertEqual(controller.diff?.content, .binary)
    }

    func testTextDiffUsesAVisibleScrollingTextDocument() {
        let controller = GitDiffViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        controller.update(
            diff: GitFileDiff(
                change: GitDiffFileChange(kind: .modified, oldPath: nil, newPath: "f.txt"),
                content: .text(hunks: [makeHunk()])
            )
        )
        window.layoutIfNeeded()

        XCTAssertTrue(controller.renderedText.contains("-old"))
        XCTAssertTrue(controller.renderedText.contains("+new"))
        XCTAssertGreaterThan(controller.renderedTextViewFrame.width, 100)
        XCTAssertGreaterThan(controller.renderedTextViewFrame.height, 0)
    }

    func testQuickDiffProjectsGutterMarkAndRevealsFirstHunkInline() throws {
        let snapshot = SourceSnapshot(text: "same\nnew\n", version: 7)
        let documentController = CodeDocumentViewController(snapshot: snapshot)
        let diff = GitFileDiff(
            change: GitDiffFileChange(kind: .modified, oldPath: nil, newPath: "f.txt"),
            content: .text(hunks: [makeHunk()])
        )
        let controller = GitQuickDiffController(documentController: documentController)
        controller.update(
            sources: [
                GitQuickDiffSource(
                    label: "Working Tree",
                    diff: diff,
                    projection: GitQuickDiffProjection.project(diff, provider: .workingTree),
                    layer: .primary
                )
            ],
            revealFirstHunk: true
        )

        XCTAssertEqual(documentController.viewport.activeGutterChanges.count, 1)
        XCTAssertEqual(documentController.viewport.activeGutterChanges.first?.kind, .modified)
        XCTAssertEqual(documentController.viewport.activeGutterChanges.first?.location, .lines(1..<2))
        XCTAssertEqual(controller.selectedHunkID, GitQuickDiffHunkID(provider: .workingTree, index: 0))
        XCTAssertNotNil(documentController.viewport.activeViewZoneID)

        documentController.viewport.cancelOperation(nil)

        XCTAssertNil(controller.selectedHunkID)
        XCTAssertNil(documentController.viewport.activeViewZoneID)
    }

    func testQuickDiffPeekUsesCompactVSCodeStyleHeaderAndFullRowTints() {
        let controller = GitDiffViewController.GitQuickDiffPeekViewController(
            hunk: makeHunk(),
            fileName: "README.md",
            providerLabel: "Working Tree",
            hunkIndex: 0,
            hunkCount: 2,
            theme: BundledThemes.light,
            onPrevious: {},
            onNext: {},
            onOpenFullDiff: {},
            onClose: {}
        )
        controller.loadViewIfNeeded()

        XCTAssertTrue(controller.renderedTitle.contains("README.md"))
        XCTAssertTrue(controller.renderedTitle.contains("Git Local Changes"))
        XCTAssertTrue(controller.renderedTitle.contains("Working Tree"))
        XCTAssertEqual(controller.renderedColoredRowCount, 2)
        XCTAssertEqual(Set(controller.renderedIntralineHighlights), ["old", "new"])
    }

    func testDeletedFileAnchorsBeforeEmptySnapshotAndRevealsHunk() {
        let snapshot = SourceSnapshot(text: "", version: 8)
        let documentController = CodeDocumentViewController(snapshot: snapshot)
        let hunk = GitDiffHunk(
            oldStart: 1,
            oldCount: 1,
            newStart: 0,
            newCount: 0,
            sectionHeading: nil,
            lines: [
                GitDiffLine(
                    kind: .removed,
                    oldLineNumber: 1,
                    newLineNumber: nil,
                    text: "deleted"
                )
            ]
        )
        let diff = GitFileDiff(
            change: GitDiffFileChange(kind: .deleted, oldPath: nil, newPath: "gone.txt"),
            content: .text(hunks: [hunk])
        )
        let controller = GitQuickDiffController(documentController: documentController)

        controller.update(
            sources: [
                GitQuickDiffSource(
                    label: "Index",
                    diff: diff,
                    projection: GitQuickDiffProjection.project(diff, provider: .staged),
                    layer: .primary
                )
            ],
            revealFirstHunk: true
        )

        XCTAssertEqual(documentController.viewport.activeGutterChanges.count, 1)
        XCTAssertEqual(
            documentController.viewport.activeGutterChanges.first?.location,
            .deletion(afterLine: -1)
        )
        XCTAssertEqual(
            controller.selectedHunkID,
            GitQuickDiffHunkID(provider: .staged, index: 0)
        )
        XCTAssertNotNil(documentController.viewport.activeViewZoneID)
    }

    func testQuickDiffKeyboardNavigationMovesBetweenHunks() {
        let secondHunk = GitDiffHunk(
            oldStart: 4,
            oldCount: 1,
            newStart: 4,
            newCount: 1,
            sectionHeading: nil,
            lines: [
                GitDiffLine(kind: .removed, oldLineNumber: 4, newLineNumber: nil, text: "before"),
                GitDiffLine(kind: .added, oldLineNumber: nil, newLineNumber: 4, text: "after")
            ]
        )
        let snapshot = SourceSnapshot(text: "same\nnew\nthird\nafter\n")
        let documentController = CodeDocumentViewController(snapshot: snapshot)
        let diff = GitFileDiff(
            change: GitDiffFileChange(kind: .modified, oldPath: nil, newPath: "f.txt"),
            content: .text(hunks: [makeHunk(), secondHunk])
        )
        let controller = GitQuickDiffController(documentController: documentController)
        controller.update(
            sources: [
                GitQuickDiffSource(
                    label: "Working Tree",
                    diff: diff,
                    projection: GitQuickDiffProjection.project(diff, provider: .workingTree),
                    layer: .primary
                )
            ],
            revealFirstHunk: true
        )

        controller.showNextHunk()
        XCTAssertEqual(controller.selectedHunkID, GitQuickDiffHunkID(provider: .workingTree, index: 1))

        controller.showPreviousHunk()
        XCTAssertEqual(controller.selectedHunkID, GitQuickDiffHunkID(provider: .workingTree, index: 0))
    }

    func testQuickDiffUnavailableStateIsExplicitAndCanOpenFallbackDiff() {
        let snapshot = SourceSnapshot(text: "", version: 3)
        let documentController = CodeDocumentViewController(snapshot: snapshot)
        let diff = GitFileDiff(
            change: GitDiffFileChange(kind: .modified, oldPath: nil, newPath: "image.bin"),
            content: .binary
        )
        let controller = GitQuickDiffController(documentController: documentController)
        var openedDiff: GitFileDiff?
        controller.onOpenFullDiff = { openedDiff = $0 }

        controller.showUnavailable(message: "Binary files do not have an inline text diff.", diff: diff)

        XCTAssertTrue(documentController.viewport.activeGutterChanges.isEmpty)
        XCTAssertEqual(documentController.viewport.activeViewZoneID, CodeViewZoneID("git-quick-diff:unavailable"))
        controller.openFullDiff()
        XCTAssertEqual(openedDiff, diff)
    }
}
