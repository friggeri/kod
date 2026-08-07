import GitCore
import XCTest
@testable import Kod

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
}
