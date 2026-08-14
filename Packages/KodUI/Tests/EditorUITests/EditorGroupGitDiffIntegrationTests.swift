import AppKit
import CodeViewport
import GitCore
import SourceModel
import WorkspaceCore
import XCTest
@testable import EditorUI
@testable import GitUI

/// Cross-product coverage for EditorUI's full and inline Git projections.
/// These tests stay headless and exercise no App-shell coordinator.
@MainActor
final class EditorGroupGitDiffIntegrationTests: XCTestCase {
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

    func testEditorGroupShowsDiffInViewerAndFileOpenRestoresSource() throws {
        let editor = EditorGroupViewController(
            groupID: EditorGroupID(),
            state: EditorGroupState()
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = editor

        let diff = GitFileDiff(
            change: GitDiffFileChange(kind: .modified, oldPath: nil, newPath: "f.txt"),
            content: .text(hunks: [makeHunk()])
        )
        editor.openDiffTab(relativePath: "f.txt", diff: diff)
        let tabID = try XCTUnwrap(editor.state.selectedTabID)

        XCTAssertEqual(editor.displayedContentKind(forTabID: tabID), .diff)
        XCTAssertNotNil(editor.diffController(forTabID: tabID))
        XCTAssertNil(editor.currentDocumentController)

        editor.openTab(
            relativePath: "f.txt",
            pinned: true,
            snapshot: SourceSnapshot(text: "current contents")
        )

        XCTAssertEqual(editor.displayedContentKind(forTabID: tabID), .source)
        XCTAssertNil(editor.diffController(forTabID: tabID))
        XCTAssertEqual(editor.currentDocumentController?.snapshot.text, "current contents")
    }

    func testEditorGroupQuickDiffUsesVirtualSnapshotAndFullDiffActionStaysReachable() throws {
        let editor = EditorGroupViewController(
            groupID: EditorGroupID(),
            state: EditorGroupState()
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = editor

        let diff = GitFileDiff(
            change: GitDiffFileChange(kind: .modified, oldPath: nil, newPath: "f.txt"),
            content: .text(hunks: [makeHunk()])
        )
        let indexSnapshot = SourceSnapshot(
            text: "same\nindex contents\n",
            url: URL(fileURLWithPath: "/workspace/f.txt"),
            version: 11
        )
        editor.openQuickDiffTab(
            relativePath: "f.txt",
            snapshot: indexSnapshot,
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
        let tabID = try XCTUnwrap(editor.state.selectedTabID)

        XCTAssertEqual(editor.displayedContentKind(forTabID: tabID), .quickDiff)
        XCTAssertNil(editor.currentDocumentController, "virtual index content must not enter normal source/LSP state")
        XCTAssertNil(editor.currentVisibleDocumentController)
        XCTAssertNotNil(editor.currentQuickDiffController)
        XCTAssertEqual(editor.currentQuickDiffController?.selectedHunkID, GitQuickDiffHunkID(provider: .staged, index: 0))

        editor.currentQuickDiffController?.openFullDiff()

        XCTAssertEqual(editor.displayedContentKind(forTabID: tabID), .diff)
        XCTAssertEqual(editor.diffController(forTabID: tabID)?.diff, diff)
    }

    func testWorkingTreeReloadDoesNotReplaceVirtualQuickDiffSnapshot() throws {
        let editor = EditorGroupViewController(
            groupID: EditorGroupID(),
            state: EditorGroupState()
        )
        editor.loadViewIfNeeded()
        editor.openTab(
            relativePath: "f.txt",
            pinned: true,
            snapshot: SourceSnapshot(text: "working tree before\n", version: 10)
        )
        let diff = GitFileDiff(
            change: GitDiffFileChange(kind: .modified, oldPath: nil, newPath: "f.txt"),
            content: .text(hunks: [makeHunk()])
        )
        editor.openQuickDiffTab(
            relativePath: "f.txt",
            snapshot: SourceSnapshot(text: "same\nindex contents\n", version: 11),
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
        let tabID = try XCTUnwrap(editor.state.selectedTabID)
        let quickDiffController = try XCTUnwrap(editor.currentQuickDiffController)

        editor.reloadTab(
            relativePath: "f.txt",
            with: SourceSnapshot(text: "working tree contents\n", version: 12)
        )

        XCTAssertEqual(editor.displayedContentKind(forTabID: tabID), .quickDiff)
        XCTAssertTrue(editor.currentQuickDiffController === quickDiffController)
        XCTAssertNil(editor.currentDocumentController)
        XCTAssertEqual(
            editor.currentQuickDiffController?.selectedHunkID,
            GitQuickDiffHunkID(provider: .staged, index: 0)
        )

        editor.openTab(
            relativePath: "f.txt",
            pinned: true,
            snapshot: SourceSnapshot(text: "working tree contents\n", version: 12)
        )
        XCTAssertEqual(editor.currentDocumentController?.snapshot.text, "working tree contents\n")
    }
}
