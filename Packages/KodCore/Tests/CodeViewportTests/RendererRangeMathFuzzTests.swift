import CoreGraphics
import FuzzSupport
import XCTest
@testable import CodeViewport

/// Bounded, seeded fuzzing of `ViewportMetrics.visibleLineRange`, the
/// renderer range math that turns an arbitrary visible `CGRect` into the
/// (bounded, non-negative, in-range) set of source lines to lay out and
/// draw (SPEC 16.1: "Property and fuzz tests for ... renderer range
/// math"). Includes the documented `CGRect.infinite`/non-finite-rect
/// edge case explicitly, since that is a real, reachable input (a view
/// queried before being installed in a scroll view) rather than a
/// theoretical one.
final class RendererRangeMathFuzzTests: XCTestCase {
    /// Property: for any line count, line height, and query rect (finite
    /// or not, including degenerate/negative ones), the returned range's
    /// bounds always stay within `0...lineCount` and never invert
    /// (`lowerBound <= upperBound`) — a violation here would mean
    /// `CodeViewport` could be asked to lay out a negative or
    /// out-of-bounds line, which SPEC 12.3 requires never happens for
    /// any adversarial input.
    func testVisibleLineRangeNeverEscapesValidBoundsOrInverts() throws {
        try FuzzRun.run("RendererRangeMathFuzzTests.boundsNeverEscape") { source in
            let lineCount = Int.random(in: 0...2_000_000, using: &source)
            let lineHeight = CGFloat.random(in: 0.0...100.0, using: &source)
            let metrics = ViewportMetrics(lineCount: lineCount, lineHeight: lineHeight, contentWidth: 1_200)

            let rect = randomRect(&source)
            let overscan = Int.random(in: 0...50, using: &source)

            let range = metrics.visibleLineRange(in: rect, overscan: overscan)

            XCTAssertLessThanOrEqual(range.lowerBound, range.upperBound)
            XCTAssertGreaterThanOrEqual(range.lowerBound, 0)
            XCTAssertLessThanOrEqual(range.upperBound, max(0, lineCount))
        }
    }

    /// Property: an infinite or NaN-containing rect (the documented
    /// "not yet installed in a scroll view" case) degrades to a valid,
    /// in-bounds range rather than trapping on an `Int(CGFloat.infinity)`
    /// conversion or propagating a NaN into the result.
    func testNonFiniteRectDegradesGracefully() throws {
        try FuzzRun.run("RendererRangeMathFuzzTests.nonFiniteRect", iterations: 100) { source in
            let lineCount = Int.random(in: 0...500_000, using: &source)
            let lineHeight = CGFloat.random(in: 0.1...50.0, using: &source)
            let metrics = ViewportMetrics(lineCount: lineCount, lineHeight: lineHeight, contentWidth: 1_200)

            let nonFiniteRects: [CGRect] = [
                .infinite,
                CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
                CGRect(x: 0, y: CGFloat.nan, width: 100, height: 100),
                CGRect(x: 0, y: 0, width: CGFloat.infinity, height: CGFloat.infinity)
            ]
            let rect = nonFiniteRects[Int.random(in: 0..<nonFiniteRects.count, using: &source)]

            let range = metrics.visibleLineRange(in: rect)
            XCTAssertLessThanOrEqual(range.lowerBound, range.upperBound)
            XCTAssertGreaterThanOrEqual(range.lowerBound, 0)
            XCTAssertLessThanOrEqual(range.upperBound, max(0, lineCount))
        }
    }

    /// Property: a zero or negative `lineHeight`/`lineCount` (a
    /// degenerate, but not impossible-to-construct, metrics value) never
    /// produces a division-by-zero trap or an inverted/negative range —
    /// the documented `guard lineCount > 0, lineHeight > 0` early exit
    /// must hold for every value in that space, not just the ones this
    /// suite happens to hand-pick.
    func testDegenerateMetricsNeverTrapOrInvert() throws {
        try FuzzRun.run("RendererRangeMathFuzzTests.degenerateMetrics", iterations: 200) { source in
            let lineCount = Int.random(in: -1_000...0, using: &source)
            let lineHeight = CGFloat.random(in: -100.0...0.0, using: &source)
            let metrics = ViewportMetrics(lineCount: lineCount, lineHeight: lineHeight, contentWidth: 1_200)
            let range = metrics.visibleLineRange(in: randomRect(&source))
            XCTAssertEqual(range, 0..<0)
        }
    }

    private func randomRect(_ source: inout FuzzRandomSource) -> CGRect {
        CGRect(
            x: CGFloat.random(in: -1_000_000...1_000_000, using: &source),
            y: CGFloat.random(in: -1_000_000...1_000_000, using: &source),
            width: CGFloat.random(in: 0...10_000, using: &source),
            height: CGFloat.random(in: 0...10_000, using: &source)
        )
    }
}
