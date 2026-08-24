import CoreGraphics
import SourceModel
import SyntaxCore
import TextDecorationModel
import ThemeCore
import XCTest
@testable import CodeViewport

final class TextLayoutEngineTests: XCTestCase {
    func testWrapRangesPreferWhitespaceAndPreserveUTF16Boundaries() {
        XCTAssertEqual(
            TextLayoutEngine.wrapUnitRanges("alpha beta", maxColumns: 6),
            [0..<6, 6..<10]
        )
        XCTAssertEqual(
            TextLayoutEngine.wrapUnitRanges("界界界", maxColumns: 2),
            [0..<2, 2..<3]
        )
    }

    func testCacheKeyTracksWrapColumnsAndFoldVersion() {
        let snapshot = SourceSnapshot(text: "alpha beta\nsecond\n")
        var engine = TextLayoutEngine()
        let folds = FoldState()

        XCTAssertTrue(engine.rebuildIfNeeded(
            snapshot: snapshot,
            wrapEnabled: true,
            maximumColumns: 6,
            folds: folds
        ))
        XCTAssertFalse(engine.rebuildIfNeeded(
            snapshot: snapshot,
            wrapEnabled: true,
            maximumColumns: 6,
            folds: folds
        ))
        XCTAssertTrue(engine.rebuildIfNeeded(
            snapshot: snapshot,
            wrapEnabled: true,
            maximumColumns: 5,
            folds: folds
        ))
    }
}

final class FoldStateTests: XCTestCase {
    func testLongestRangeWinsAndRestoredFoldHidesBody() {
        var state = FoldState()
        state.restore([1])
        state.apply(ranges: [
            FoldRange(headerLine: 1, endLine: 2),
            FoldRange(headerLine: 1, endLine: 4)
        ])

        XCTAssertEqual(state.rangesByHeaderLine[1]?.endLine, 4)
        XCTAssertTrue(state.isFolded(1))
        XCTAssertEqual(state.hiddenLines(lineCount: 6), [
            false, false, true, true, true, false
        ])
    }

    func testRevealExpandsEveryFoldContainingLine() {
        var state = FoldState()
        state.apply(ranges: [
            FoldRange(headerLine: 0, endLine: 6),
            FoldRange(headerLine: 2, endLine: 5)
        ])
        state.toggle(0)
        state.toggle(2)

        XCTAssertTrue(state.reveal(line: 4))
        XCTAssertFalse(state.isActive)
    }
}

@MainActor
final class DecorationStateTests: XCTestCase {
    func testRejectsStaleAndSupersededLayersWithoutChangingRuns() {
        let color = BundledThemes.dark.editor.foreground
        let state = DecorationState(snapshotVersion: 7)
        let accepted = DecorationLayerSnapshot(
            kind: .semantic,
            snapshotVersion: 7,
            layerVersion: 2,
            runs: [DecorationRun(
                utf8Range: 1..<4,
                attributes: DecorationAttributes(foreground: color)
            )]
        )
        XCTAssertTrue(state.apply(accepted))
        XCTAssertFalse(state.apply(DecorationLayerSnapshot(
            kind: .semantic,
            snapshotVersion: 7,
            layerVersion: 1,
            runs: []
        )))
        XCTAssertFalse(state.apply(DecorationLayerSnapshot(
            kind: .semantic,
            snapshotVersion: 6,
            layerVersion: 3,
            runs: []
        )))
        XCTAssertEqual(state.composedRuns(in: 0..<5), accepted.runs)
    }

    func testRemovingOneDecorationLayerPreservesTheOthers() {
        let foreground = BundledThemes.dark.editor.foreground
        let semantic = DecorationLayerSnapshot(
            kind: .semantic,
            snapshotVersion: 7,
            layerVersion: 1,
            runs: [DecorationRun(
                utf8Range: 1..<4,
                attributes: DecorationAttributes(foreground: foreground)
            )]
        )
        let diagnostics = DecorationLayerSnapshot(
            kind: .diagnostics,
            snapshotVersion: 7,
            layerVersion: 1,
            runs: [DecorationRun(
                utf8Range: 2..<3,
                attributes: DecorationAttributes(isUnderlined: true)
            )]
        )
        let state = DecorationState(snapshotVersion: 7)
        XCTAssertTrue(state.apply(semantic))
        XCTAssertTrue(state.apply(diagnostics))

        XCTAssertTrue(state.remove(.semantic))
        XCTAssertFalse(state.remove(.semantic))
        XCTAssertEqual(
            state.composedRuns(in: 0..<5),
            diagnostics.runs
        )
    }
}

final class GutterModelTests: XCTestCase {
    private func change(
        id: String,
        layer: CodeGutterChange.Layer,
        location: CodeGutterChange.Location,
        kind: CodeGutterChange.Kind = .modified
    ) -> CodeGutterChange {
        CodeGutterChange(
            id: id,
            kind: kind,
            layer: layer,
            location: location,
            accessibilityLabel: id
        )
    }

    func testValidationVersioningAndPrimaryLookup() {
        var model = GutterModel()
        let secondary = change(id: "secondary", layer: .secondary, location: .lines(2..<4))
        let primary = change(id: "primary", layer: .primary, location: .lines(2..<4))

        XCTAssertTrue(model.apply(
            [secondary, primary],
            snapshotVersion: 3,
            activeSnapshotVersion: 3,
            layerVersion: 4,
            lineCount: 10
        ))
        XCTAssertEqual(model.lineChange(at: 3), primary)
        XCTAssertFalse(model.apply(
            [],
            snapshotVersion: 3,
            activeSnapshotVersion: 3,
            layerVersion: 2,
            lineCount: 10
        ))
        XCTAssertEqual(model.changes, [secondary, primary])
    }

    func testLaneAndMarkerGeometryStayInsideGutter() {
        let lanes = GutterModel.laneLayout(width: 80, height: 200)
        XCTAssertLessThan(lanes.lineNumbers.maxX, lanes.gitStatus.minX)
        XCTAssertLessThan(lanes.gitStatus.maxX, lanes.folding.minX)
        XCTAssertEqual(
            GutterModel.markerRect(in: lanes.gitStatus, layer: .primary, y: 20, height: 10),
            CGRect(x: lanes.gitStatus.minX + 1, y: 20, width: 4, height: 10)
        )
    }
}

final class ViewportCoordinateMapperTests: XCTestCase {
    func testFoldedRowsAndViewZoneMapBackToSource() {
        let mapper = ViewportCoordinateMapper(
            visualRowStarts: [0, 2, 2, 3],
            lineCount: 3,
            viewZoneAfterLine: 0,
            viewZoneHeight: 2
        )

        XCTAssertEqual(mapper.viewZoneDisplayRows, 2..<4)
        XCTAssertEqual(mapper.displayRowRange(forLine: 2), 4..<5)
        XCTAssertNil(mapper.baseRow(forDisplayRow: 3))
        XCTAssertEqual(
            mapper.sourceIdentity(forDisplayRow: 4),
            ViewportSourceIdentity(line: 2, segmentIndex: 0)
        )
    }
}

final class MinimapPresentationSnapshotBuilderTests: XCTestCase {
    func testBuildsCappedTokenSpansAndBlankViewZoneRows() {
        let foreground = BundledThemes.dark.editor.foreground
        let builder = MinimapPresentationSnapshotBuilder(
            maximumColumns: 5,
            defaultForeground: foreground
        )
        let presentation = builder.build(
            totalVisualRows: 2,
            requestedRows: 0..<2,
            rows: [
                .init(
                    visualRow: 0,
                    sourceLine: 0,
                    segmentIndex: 0,
                    utf8Range: 10..<17,
                    text: "\tABC",
                    decorationRuns: [DecorationRun(
                        utf8Range: 10..<12,
                        attributes: DecorationAttributes(foreground: foreground)
                    )],
                    isViewZone: false
                ),
                .init(
                    visualRow: 1,
                    sourceLine: nil,
                    segmentIndex: nil,
                    utf8Range: nil,
                    text: "ignored",
                    decorationRuns: [],
                    isViewZone: true
                )
            ]
        )

        XCTAssertEqual(presentation.rows[0].text, "\tA")
        XCTAssertEqual(presentation.rows[0].tokenSpans, [
            CodeMinimapTokenSpan(columns: 0..<5, color: foreground)
        ])
        XCTAssertTrue(presentation.rows[1].isViewZone)
        XCTAssertEqual(presentation.rows[1].text, "")
    }
}

final class FindStateModelTests: XCTestCase {
    func testSearchAnchorsAndWrapsMatchNavigation() {
        let snapshot = SourceSnapshot(text: "one two one")
        var state = FindStateModel()

        XCTAssertEqual(
            state.search(
                snapshot: snapshot,
                query: "one",
                options: FindOptions(),
                anchorUTF8Offset: 5
            ),
            .matches
        )
        XCTAssertEqual(state.currentMatch?.utf8Range, 8..<11)
        XCTAssertEqual(state.select(offsetBy: 1)?.utf8Range, 0..<3)
        XCTAssertEqual(state.statusText, "1 of 2")
    }

    func testInvalidRegexClearsPriorResults() {
        let snapshot = SourceSnapshot(text: "one")
        var state = FindStateModel()
        state.search(
            snapshot: snapshot,
            query: "one",
            options: FindOptions(),
            anchorUTF8Offset: 0
        )

        XCTAssertEqual(
            state.search(
                snapshot: snapshot,
                query: "(",
                options: FindOptions(useRegex: true),
                anchorUTF8Offset: 0
            ),
            .invalid
        )
        XCTAssertTrue(state.matches.isEmpty)
        XCTAssertNil(state.currentMatch)
    }
}
