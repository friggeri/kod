import Foundation
import SourceModel
import XCTest
@testable import WorkspaceCore

final class ReadingAnchorReconcilerTests: XCTestCase {
    func testUnchangedLinesKeepTheirSelectionAndViewportAnchor() throws {
        let old = SourceSnapshot(text: "alpha\nbeta\ngamma\n")
        let new = SourceSnapshot(text: "alpha\nbeta\ngamma\n", version: 2)

        // Selection on "beta" (line 1).
        let selection = EditorSelection(6..<10)
        let anchor = ReadingAnchor(selection: selection, viewportAnchorLine: 2, foldedHeaderLines: [0])

        let reconciled = ReadingAnchorReconciler.reconcile(anchor, from: old, to: new)

        XCTAssertEqual(reconciled.selection, selection)
        XCTAssertEqual(reconciled.viewportAnchorLine, 2)
        XCTAssertEqual(reconciled.foldedHeaderLines, [0])
    }

    func testInsertedLinesAboveShiftTheAnchorToTheMatchingLine() throws {
        let old = SourceSnapshot(text: "alpha\nbeta\ngamma\n")
        // Two new lines inserted before "beta".
        let new = SourceSnapshot(text: "alpha\nNEW1\nNEW2\nbeta\ngamma\n", version: 2)

        let oldBetaRange = try XCTUnwrap(old.utf8RangeForLine(1))
        let selection = EditorSelection(oldBetaRange)
        let anchor = ReadingAnchor(selection: selection, viewportAnchorLine: 1, foldedHeaderLines: [1])

        let reconciled = ReadingAnchorReconciler.reconcile(anchor, from: old, to: new)

        // "beta" is now at line 3 in the new snapshot.
        XCTAssertEqual(new.line(at: 3), "beta")
        let reconciledSelection = try XCTUnwrap(reconciled.selection)
        XCTAssertEqual(try new.text(inUTF8Range: reconciledSelection.range), "beta")
        XCTAssertEqual(reconciled.viewportAnchorLine, 3)
        XCTAssertEqual(reconciled.foldedHeaderLines, [3])
    }

    func testNoMatchingLineWithinWindowClampsToLineCount() throws {
        let old = SourceSnapshot(text: "one\ntwo\nthree\n")
        let new = SourceSnapshot(text: "totally different\ncontent now\n", version: 2)

        let anchor = ReadingAnchor(selection: nil, viewportAnchorLine: 2, foldedHeaderLines: [])
        let reconciled = ReadingAnchorReconciler.reconcile(anchor, from: old, to: new, searchWindow: 5)

        XCTAssertEqual(reconciled.viewportAnchorLine, new.lineCount - 1)
    }

    func testSelectionWithinLineIsClampedWhenLineShrinks() throws {
        let old = SourceSnapshot(text: "a very long line of text here\nsecond\n")
        let new = SourceSnapshot(text: "short\nsecond\n", version: 2)

        // Select near the end of the long first line — it no longer exists
        // verbatim, so the line itself falls back to the clamped index (0),
        // but the character offset must still be valid for the new line.
        let selection = EditorSelection(20..<25)
        let anchor = ReadingAnchor(selection: selection)

        let reconciled = ReadingAnchorReconciler.reconcile(anchor, from: old, to: new, searchWindow: 0)

        let reconciledSelection = try XCTUnwrap(reconciled.selection)
        // Must not throw decoding an out-of-bounds UTF-8 range.
        _ = try new.text(inUTF8Range: reconciledSelection.range)
        XCTAssertLessThanOrEqual(reconciledSelection.upperBound, new.utf8Count)
    }

    func testMultiLineSelectionReconcilesEachEndIndependently() throws {
        let old = SourceSnapshot(text: "one\ntwo\nthree\nfour\n")
        let new = SourceSnapshot(text: "zero\none\ntwo\nthree\nfour\n", version: 2)

        // Selection spanning from "one" (line 0) through "three" (line 2).
        let start = old.utf8RangeForLine(0).map { $0.lowerBound }
        let end = try XCTUnwrap(old.utf8RangeForLine(2)).upperBound
        let selection = EditorSelection((start ?? 0)..<end)
        let anchor = ReadingAnchor(selection: selection)

        let reconciled = ReadingAnchorReconciler.reconcile(anchor, from: old, to: new)

        let reconciledSelection = try XCTUnwrap(reconciled.selection)
        let text = try new.text(inUTF8Range: reconciledSelection.range)
        XCTAssertEqual(text, "one\ntwo\nthree")
    }

    func testEmptyNewSnapshotDoesNotCrash() {
        let old = SourceSnapshot(text: "alpha\nbeta\n")
        let new = SourceSnapshot(text: "", version: 2)

        let anchor = ReadingAnchor(selection: EditorSelection(0..<3), viewportAnchorLine: 1, foldedHeaderLines: [0])
        let reconciled = ReadingAnchorReconciler.reconcile(anchor, from: old, to: new)

        XCTAssertEqual(reconciled.viewportAnchorLine, 0)
    }
}
