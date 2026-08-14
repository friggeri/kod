import XCTest
@testable import TextDecorationModel

/// Focused coverage of the value-level composition rules the decoration
/// model owns, independent of any theme, parser, or language server:
/// attribute overlay semantics and the SPEC 7.1 layer precedence order.
final class DecorationAttributesCompositionTests: XCTestCase {
    func testOverlayingKeepsLowerLayerColorWhenUpperLayerDoesNotSetIt() {
        let lower = DecorationAttributes(
            foreground: ThemeColor(hex: "#112233"),
            background: ThemeColor(hex: "#445566")
        )
        let upper = DecorationAttributes(background: ThemeColor(hex: "#778899"))

        let composed = lower.overlaying(upper)

        XCTAssertEqual(composed.foreground, ThemeColor(hex: "#112233"))
        XCTAssertEqual(composed.background, ThemeColor(hex: "#778899"))
    }

    func testOverlayingUnionsBooleanTraitsAndNeverClearsThem() {
        let lower = DecorationAttributes(isBold: true, isUnderlined: true)
        let upper = DecorationAttributes(isItalic: true, isStrikethrough: true)

        let composed = lower.overlaying(upper)

        XCTAssertTrue(composed.isBold)
        XCTAssertTrue(composed.isItalic)
        XCTAssertTrue(composed.isUnderlined)
        XCTAssertTrue(composed.isStrikethrough)

        // A higher layer that sets nothing must not blank the lower one.
        XCTAssertEqual(lower.overlaying(.none), lower)
    }

    func testOverlayingIsIdentityWhenLowerLayerIsEmpty() {
        let upper = DecorationAttributes(foreground: ThemeColor(hex: "#FFFFFF"), isItalic: true)
        XCTAssertEqual(DecorationAttributes.none.overlaying(upper), upper)
    }

    func testLayerKindPrecedenceOrderMatchesSpecOrdering() {
        XCTAssertEqual(
            DecorationLayerKind.allCases,
            [.base, .lexical, .semantic, .search, .diagnostics, .selection],
            "allCases order is the precedence order the compositor iterates"
        )
        XCTAssertTrue(DecorationLayerKind.base < .lexical)
        XCTAssertTrue(DecorationLayerKind.lexical < .semantic)
        XCTAssertTrue(DecorationLayerKind.semantic < .search)
        XCTAssertTrue(DecorationLayerKind.search < .diagnostics)
        XCTAssertTrue(DecorationLayerKind.diagnostics < .selection)
    }

    @MainActor
    func testHigherLayerForegroundWinsRegardlessOfApplicationOrder() {
        let lexical = DecorationLayerSnapshot(
            kind: .lexical,
            snapshotVersion: 7,
            layerVersion: 1,
            runs: [
                DecorationRun(
                    utf8Range: 0..<6,
                    attributes: DecorationAttributes(foreground: ThemeColor(hex: "#101010"))
                )
            ]
        )
        let semantic = DecorationLayerSnapshot(
            kind: .semantic,
            snapshotVersion: 7,
            layerVersion: 1,
            runs: [
                DecorationRun(
                    utf8Range: 0..<6,
                    attributes: DecorationAttributes(foreground: ThemeColor(hex: "#202020"))
                )
            ]
        )

        let inOrder = DecorationCompositor(activeSnapshotVersion: 7)
        XCTAssertTrue(inOrder.apply(lexical))
        XCTAssertTrue(inOrder.apply(semantic))

        let reversed = DecorationCompositor(activeSnapshotVersion: 7)
        XCTAssertTrue(reversed.apply(semantic))
        XCTAssertTrue(reversed.apply(lexical))

        let expected = [
            DecorationRun(
                utf8Range: 0..<6,
                attributes: DecorationAttributes(foreground: ThemeColor(hex: "#202020"))
            )
        ]
        XCTAssertEqual(inOrder.composedRuns(inUTF8Range: 0..<6), expected)
        XCTAssertEqual(reversed.composedRuns(inUTF8Range: 0..<6), expected)
    }

    @MainActor
    func testStaleSnapshotAndSupersededLayerVersionsAreRejected() {
        let compositor = DecorationCompositor(activeSnapshotVersion: 2)
        let current = DecorationLayerSnapshot(
            kind: .lexical,
            snapshotVersion: 2,
            layerVersion: 5,
            runs: [
                DecorationRun(
                    utf8Range: 0..<4,
                    attributes: DecorationAttributes(foreground: ThemeColor(hex: "#010101"))
                )
            ]
        )
        XCTAssertTrue(compositor.apply(current))

        let superseded = DecorationLayerSnapshot(
            kind: .lexical,
            snapshotVersion: 2,
            layerVersion: 4,
            runs: []
        )
        XCTAssertFalse(compositor.apply(superseded))

        let stale = DecorationLayerSnapshot(
            kind: .lexical,
            snapshotVersion: 1,
            layerVersion: 99,
            runs: []
        )
        XCTAssertFalse(compositor.apply(stale))

        XCTAssertEqual(compositor.layerVersion(for: .lexical), 5)
        XCTAssertEqual(compositor.composedRuns(inUTF8Range: 0..<4).count, 1)

        compositor.activate(snapshotVersion: 3)
        XCTAssertNil(compositor.layerVersion(for: .lexical))
        XCTAssertTrue(compositor.composedRuns(inUTF8Range: 0..<4).isEmpty)
    }
}
