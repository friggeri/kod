import Foundation
import SourceModel
import SyntaxCore
import ThemeCore
import XCTest
@testable import GitCore

final class GitLineDecorationBuilderTests: XCTestCase {
    func testPureAddRunProducesAddedDecorations() {
        let hunk = GitDiffHunk(
            oldStart: 1, oldCount: 1, newStart: 1, newCount: 3,
            sectionHeading: nil,
            lines: [
                GitDiffLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "same"),
                GitDiffLine(kind: .added, oldLineNumber: nil, newLineNumber: 2, text: "new2"),
                GitDiffLine(kind: .added, oldLineNumber: nil, newLineNumber: 3, text: "new3")
            ]
        )
        let (changes, deletions) = GitLineDecorationBuilder.lineDecorations(for: [hunk])
        XCTAssertEqual(changes, [
            GitLineDecoration(newLineNumber: 2, kind: .added),
            GitLineDecoration(newLineNumber: 3, kind: .added)
        ])
        XCTAssertTrue(deletions.isEmpty)
    }

    func testRemovedFollowedByAddedProducesModifiedDecorations() {
        let hunk = GitDiffHunk(
            oldStart: 1, oldCount: 2, newStart: 1, newCount: 2,
            sectionHeading: nil,
            lines: [
                GitDiffLine(kind: .removed, oldLineNumber: 1, newLineNumber: nil, text: "old"),
                GitDiffLine(kind: .added, oldLineNumber: nil, newLineNumber: 1, text: "new")
            ]
        )
        let (changes, deletions) = GitLineDecorationBuilder.lineDecorations(for: [hunk])
        XCTAssertEqual(changes, [GitLineDecoration(newLineNumber: 1, kind: .modified)])
        XCTAssertTrue(deletions.isEmpty)
    }

    func testPureRemovalWithNoAddedCounterpartProducesADeletionMarker() {
        let hunk = GitDiffHunk(
            oldStart: 1, oldCount: 2, newStart: 1, newCount: 1,
            sectionHeading: nil,
            lines: [
                GitDiffLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "keep"),
                GitDiffLine(kind: .removed, oldLineNumber: 2, newLineNumber: nil, text: "gone")
            ]
        )
        let (changes, deletions) = GitLineDecorationBuilder.lineDecorations(for: [hunk])
        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(deletions, [GitDeletionMarker(afterNewLineNumber: 1)])
    }

    func testDeletionBeforeTheFirstLineUsesZeroAsTheBoundary() {
        let hunk = GitDiffHunk(
            oldStart: 1, oldCount: 1, newStart: 1, newCount: 0,
            sectionHeading: nil,
            lines: [
                GitDiffLine(kind: .removed, oldLineNumber: 1, newLineNumber: nil, text: "gone")
            ]
        )
        let (changes, deletions) = GitLineDecorationBuilder.lineDecorations(for: [hunk])
        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(deletions, [GitDeletionMarker(afterNewLineNumber: 0)])
    }

    func testDecorationLayerBuilderProducesBackgroundRunsAtCorrectByteRanges() {
        let source = "line1\nline2\nline3\n"
        let snapshot = SourceSnapshot(text: source)
        let hunk = GitDiffHunk(
            oldStart: 1, oldCount: 1, newStart: 1, newCount: 3,
            sectionHeading: nil,
            lines: [
                GitDiffLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "line1"),
                GitDiffLine(kind: .added, oldLineNumber: nil, newLineNumber: 2, text: "line2"),
                GitDiffLine(kind: .added, oldLineNumber: nil, newLineNumber: 3, text: "line3")
            ]
        )
        let colors = GitDecorationColors(
            added: ThemeColor(hex: "#00FF00")!,
            modified: ThemeColor(hex: "#0000FF")!,
            deleted: ThemeColor(hex: "#FF0000")!,
            conflict: ThemeColor(hex: "#FF00FF")!
        )

        let (layer, deletions) = GitDecorationLayerBuilder.layer(
            for: [hunk], snapshot: snapshot, colors: colors, snapshotVersion: 1, layerVersion: 1
        )

        XCTAssertEqual(layer.kind, .gitChange)
        XCTAssertEqual(layer.runs.count, 2)
        XCTAssertTrue(deletions.isEmpty)

        let expectedLine2Range = snapshot.utf8RangeForLine(1)
        let expectedLine3Range = snapshot.utf8RangeForLine(2)
        XCTAssertEqual(layer.runs[0].utf8Range, expectedLine2Range)
        XCTAssertEqual(layer.runs[0].attributes.background, colors.added)
        XCTAssertEqual(layer.runs[1].utf8Range, expectedLine3Range)
        XCTAssertEqual(layer.runs[1].attributes.background, colors.added)
    }

    @MainActor
    func testDecorationCompositorAcceptsTheGitChangeLayerAndComposesBeneathLexical() {
        let compositor = DecorationCompositor(activeSnapshotVersion: 1)
        let gitLayer = DecorationLayerSnapshot(
            kind: .gitChange,
            snapshotVersion: 1,
            layerVersion: 1,
            runs: [DecorationRun(utf8Range: 0..<5, attributes: DecorationAttributes(background: ThemeColor(hex: "#00FF00")!))]
        )
        XCTAssertTrue(compositor.apply(gitLayer))

        let lexicalLayer = DecorationLayerSnapshot(
            kind: .lexical,
            snapshotVersion: 1,
            layerVersion: 1,
            runs: [DecorationRun(utf8Range: 0..<5, attributes: DecorationAttributes(foreground: ThemeColor(hex: "#FFFFFF")!))]
        )
        XCTAssertTrue(compositor.apply(lexicalLayer))

        let runs = compositor.composedRuns(inUTF8Range: 0..<5)
        XCTAssertEqual(runs.count, 1)
        // Both the git background and the lexical foreground survive
        // composition — the git tint never gets blanked out by a layer
        // that only sets foreground.
        XCTAssertEqual(runs[0].attributes.background, ThemeColor(hex: "#00FF00")!)
        XCTAssertEqual(runs[0].attributes.foreground, ThemeColor(hex: "#FFFFFF")!)
    }
}
