import AppKit
import FontCore
import SourceModel
import XCTest
@testable import CodeViewport

/// Covers `CodeViewport.measureGutterWidth(lineCount:resolvedFont:)` and
/// its live wiring through `applyFontSettings()` (SPEC 14: 300% zoom
/// "without clipping"). Before this fix, `gutterWidth` was a fixed 64pt
/// constant regardless of font size or digit count, so a large zoom
/// level or a long file's line-number glyphs (drawn at
/// `resolvedFont.pointSize - 2`) could overflow into the code column.
@MainActor
final class CodeViewportGutterWidthTests: XCTestCase {
    private func resolvedFont(pointSize: Double) -> ResolvedFont {
        FontResolver.resolve(FontSettings(pointSize: pointSize))
    }

    func testGutterWidthGrowsWithDigitCount() {
        let font = resolvedFont(pointSize: 13)
        let smallFile = CodeViewport.measureGutterWidth(lineCount: 9, resolvedFont: font)
        let hugeFile = CodeViewport.measureGutterWidth(lineCount: 1_000_000, resolvedFont: font)
        XCTAssertGreaterThan(
            hugeFile,
            smallFile,
            "a 7-digit line count needs more gutter width than a 1-digit one at the same font size"
        )
    }

    func testGutterWidthGrowsWithFontSize() {
        let smallFont = resolvedFont(pointSize: 13)
        // 300%-equivalent of the 13pt default.
        let largeFont = resolvedFont(pointSize: 39)
        let smallWidth = CodeViewport.measureGutterWidth(lineCount: 100_000, resolvedFont: smallFont)
        let largeWidth = CodeViewport.measureGutterWidth(lineCount: 100_000, resolvedFont: largeFont)
        XCTAssertGreaterThan(
            largeWidth,
            smallWidth,
            "300%-equivalent zoom needs a wider gutter than the default size for the same line count"
        )
    }

    func testGutterWidthNeverShrinksBelowOriginalSixtyFourPointFloor() {
        let font = resolvedFont(pointSize: 8)
        let width = CodeViewport.measureGutterWidth(lineCount: 1, resolvedFont: font)
        XCTAssertGreaterThanOrEqual(width, 64, "short files/small fonts must keep the original spacious layout")
    }

    /// End-to-end: a real `CodeViewport` at 300%-equivalent zoom with a
    /// huge (7-digit) line count must actually grow its own content
    /// width to accommodate the wider gutter — proving
    /// `applyFontSettings()` really recomputes `gutterWidth` on a live
    /// font-size change rather than leaving it at a stale/fixed value.
    func testViewportContentWidthGrowsAfterZoomingToLargeFontWithManyLines() {
        let text = (0..<1_500_000).map { "l\($0)" }.joined(separator: "\n")
        let snapshot = SourceSnapshot(text: text)
        let viewport = CodeViewport(snapshot: snapshot, fontSettings: FontSettings(pointSize: 13))
        viewport.setMinimumViewportWidth(200)
        let widthBeforeZoom = viewport.frame.width

        viewport.fontSettings = FontSettings(pointSize: 39)
        let widthAfterZoom = viewport.frame.width

        XCTAssertGreaterThan(
            widthAfterZoom,
            widthBeforeZoom,
            "zooming to 300%-equivalent with a 7-digit line count must widen the viewport to keep the gutter from clipping"
        )
    }
}
