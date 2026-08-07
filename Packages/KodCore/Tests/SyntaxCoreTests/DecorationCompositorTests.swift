import ThemeCore
import XCTest
@testable import SyntaxCore

@MainActor
final class DecorationCompositorTests: XCTestCase {
    func testBaseLayerAlone() {
        let compositor = DecorationCompositor(activeSnapshotVersion: 1)
        let base = DecorationLayerSnapshot(
            kind: .base,
            snapshotVersion: 1,
            layerVersion: 1,
            runs: [DecorationRun(utf8Range: 0..<10, attributes: DecorationAttributes(foreground: .init(hex: "#111111")))]
        )
        XCTAssertTrue(compositor.apply(base))

        let runs = compositor.composedRuns(inUTF8Range: 0..<10)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].utf8Range, 0..<10)
        XCTAssertEqual(runs[0].attributes.foreground, ThemeColor(hex: "#111111"))
    }

    func testLexicalOverridesBaseForegroundButSelectionBackgroundLayersOnTop() {
        let compositor = DecorationCompositor(activeSnapshotVersion: 1)
        XCTAssertTrue(compositor.apply(DecorationLayerSnapshot(
            kind: .base,
            snapshotVersion: 1,
            layerVersion: 1,
            runs: [DecorationRun(utf8Range: 0..<20, attributes: DecorationAttributes(foreground: .init(hex: "#000000")))]
        )))
        XCTAssertTrue(compositor.apply(DecorationLayerSnapshot(
            kind: .lexical,
            snapshotVersion: 1,
            layerVersion: 1,
            runs: [DecorationRun(utf8Range: 0..<5, attributes: DecorationAttributes(foreground: .init(hex: "#FF0000")))]
        )))
        XCTAssertTrue(compositor.apply(DecorationLayerSnapshot(
            kind: .selection,
            snapshotVersion: 1,
            layerVersion: 1,
            runs: [DecorationRun(utf8Range: 2..<8, attributes: DecorationAttributes(background: .init(hex: "#0000FF")))]
        )))

        let runs = compositor.composedRuns(inUTF8Range: 0..<20)
        // Expect disjoint segments: [0,2) lexical-red-no-bg, [2,5) lexical-red+selection-bg,
        // [5,8) base-black+selection-bg, [8,20) base-black only.
        XCTAssertEqual(runs.count, 4)

        XCTAssertEqual(runs[0].utf8Range, 0..<2)
        XCTAssertEqual(runs[0].attributes.foreground, ThemeColor(hex: "#FF0000"))
        XCTAssertNil(runs[0].attributes.background)

        XCTAssertEqual(runs[1].utf8Range, 2..<5)
        XCTAssertEqual(runs[1].attributes.foreground, ThemeColor(hex: "#FF0000"))
        XCTAssertEqual(runs[1].attributes.background, ThemeColor(hex: "#0000FF"))

        XCTAssertEqual(runs[2].utf8Range, 5..<8)
        XCTAssertEqual(runs[2].attributes.foreground, ThemeColor(hex: "#000000"))
        XCTAssertEqual(runs[2].attributes.background, ThemeColor(hex: "#0000FF"))

        XCTAssertEqual(runs[3].utf8Range, 8..<20)
        XCTAssertEqual(runs[3].attributes.foreground, ThemeColor(hex: "#000000"))
        XCTAssertNil(runs[3].attributes.background)
    }

    func testStaleSnapshotVersionIsRejected() {
        let compositor = DecorationCompositor(activeSnapshotVersion: 5)
        let staleLayer = DecorationLayerSnapshot(
            kind: .lexical,
            snapshotVersion: 4,
            layerVersion: 1,
            runs: [DecorationRun(utf8Range: 0..<5, attributes: DecorationAttributes(foreground: .init(hex: "#FF0000")))]
        )
        XCTAssertFalse(compositor.apply(staleLayer))
        XCTAssertNil(compositor.layerVersion(for: .lexical))
        XCTAssertTrue(compositor.composedRuns(inUTF8Range: 0..<5).isEmpty)
    }

    func testOutOfOrderLayerVersionIsRejected() {
        let compositor = DecorationCompositor(activeSnapshotVersion: 1)
        let newer = DecorationLayerSnapshot(
            kind: .lexical,
            snapshotVersion: 1,
            layerVersion: 2,
            runs: [DecorationRun(utf8Range: 0..<5, attributes: DecorationAttributes(foreground: .init(hex: "#00FF00")))]
        )
        let older = DecorationLayerSnapshot(
            kind: .lexical,
            snapshotVersion: 1,
            layerVersion: 1,
            runs: [DecorationRun(utf8Range: 0..<5, attributes: DecorationAttributes(foreground: .init(hex: "#FF0000")))]
        )
        XCTAssertTrue(compositor.apply(newer))
        XCTAssertFalse(compositor.apply(older))

        let runs = compositor.composedRuns(inUTF8Range: 0..<5)
        XCTAssertEqual(runs.first?.attributes.foreground, ThemeColor(hex: "#00FF00"))
    }

    func testActivatingNewSnapshotDiscardsAllLayers() {
        let compositor = DecorationCompositor(activeSnapshotVersion: 1)
        XCTAssertTrue(compositor.apply(DecorationLayerSnapshot(
            kind: .lexical,
            snapshotVersion: 1,
            layerVersion: 1,
            runs: [DecorationRun(utf8Range: 0..<5, attributes: DecorationAttributes(foreground: .init(hex: "#FF0000")))]
        )))
        XCTAssertFalse(compositor.composedRuns(inUTF8Range: 0..<5).isEmpty)

        compositor.activate(snapshotVersion: 2)
        XCTAssertTrue(compositor.composedRuns(inUTF8Range: 0..<5).isEmpty)

        // A layer computed for the old version must still be rejected even
        // after activation, simulating a late-arriving async result.
        let lateStaleLayer = DecorationLayerSnapshot(
            kind: .lexical,
            snapshotVersion: 1,
            layerVersion: 2,
            runs: [DecorationRun(utf8Range: 0..<5, attributes: DecorationAttributes(foreground: .init(hex: "#00FF00")))]
        )
        XCTAssertFalse(compositor.apply(lateStaleLayer))
        XCTAssertTrue(compositor.composedRuns(inUTF8Range: 0..<5).isEmpty)
    }

    func testBoldAndItalicTraitsAccumulateAcrossLayers() {
        let compositor = DecorationCompositor(activeSnapshotVersion: 1)
        XCTAssertTrue(compositor.apply(DecorationLayerSnapshot(
            kind: .lexical,
            snapshotVersion: 1,
            layerVersion: 1,
            runs: [DecorationRun(utf8Range: 0..<5, attributes: DecorationAttributes(isBold: true))]
        )))
        XCTAssertTrue(compositor.apply(DecorationLayerSnapshot(
            kind: .semantic,
            snapshotVersion: 1,
            layerVersion: 1,
            runs: [DecorationRun(utf8Range: 0..<5, attributes: DecorationAttributes(isItalic: true))]
        )))

        let runs = compositor.composedRuns(inUTF8Range: 0..<5)
        XCTAssertEqual(runs.count, 1)
        XCTAssertTrue(runs[0].attributes.isBold)
        XCTAssertTrue(runs[0].attributes.isItalic)
    }

    func testEmptyRangeProducesNoRuns() {
        let compositor = DecorationCompositor(activeSnapshotVersion: 1)
        XCTAssertTrue(compositor.composedRuns(inUTF8Range: 5..<5).isEmpty)
    }
}
