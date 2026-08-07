import CoreGraphics
import Foundation

public struct ViewportMetrics: Equatable, Sendable {
    public let lineCount: Int
    public let lineHeight: CGFloat
    public let contentWidth: CGFloat

    public init(lineCount: Int, lineHeight: CGFloat, contentWidth: CGFloat) {
        self.lineCount = lineCount
        self.lineHeight = lineHeight
        self.contentWidth = contentWidth
    }

    public var contentSize: CGSize {
        CGSize(
            width: contentWidth,
            height: max(lineHeight, CGFloat(lineCount) * lineHeight)
        )
    }

    public func visibleLineRange(
        in rect: CGRect,
        overscan: Int = 3
    ) -> Range<Int> {
        guard lineCount > 0, lineHeight > 0 else {
            return 0..<0
        }

        let totalContentHeight = CGFloat(lineCount) * lineHeight

        // A view with no superview (not yet installed in a scroll view, or
        // queried headlessly before layout) reports `visibleRect` as
        // `CGRect.infinite`. Its `minY`/`maxY` are *not* actually +/-
        // infinity, though: Apple documents `CGRect.infinite` as having
        // `CGFloat.greatestFiniteMagnitude`-scale (but still technically
        // finite) origin/size, so an `.isFinite` check alone does not
        // catch it — dividing such a huge-but-finite value by
        // `lineHeight` and converting the result to `Int` overflows
        // `Int`'s representable range and traps (a real, fuzz-found
        // crash: SPEC 12.3 "no adversarial input may cause ... a
        // crash"). Clamp to a bound proportional to the document's own
        // content height instead, which sanitizes NaN, +/-infinity, and
        // any merely-enormous finite value identically, so every one of
        // them degrades to a safe, valid line range rather than
        // crashing.
        func sanitized(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
            guard value.isFinite else {
                return fallback
            }
            return min(max(value, -totalContentHeight), totalContentHeight * 2)
        }

        let minY = sanitized(rect.minY, fallback: 0)
        let maxY = sanitized(rect.maxY, fallback: totalContentHeight)

        // `firstVisible` must itself be clamped to `lineCount`, not just
        // bounded below by zero: for a huge `minY` (even after the
        // `sanitized` proportional clamp above) combined with a small
        // `lineHeight`, `Int(floor(minY / lineHeight))` can still land
        // above `lineCount`. Previously only `lastVisible` was clamped
        // to `lineCount` and the final range used
        // `max(firstVisible, lastVisible)` as its upper bound purely to
        // avoid an *inverted* range — which let an unclamped,
        // over-`lineCount` `firstVisible` leak through as the returned
        // upper bound whenever it exceeded the properly-clamped
        // `lastVisible`. Found by `RendererRangeMathFuzzTests`, which
        // explores exactly this "huge offset, tiny line height"
        // combination.
        let firstVisible = min(lineCount, max(0, Int(floor(minY / lineHeight)) - overscan))
        let lastVisible = min(
            lineCount,
            Int(ceil(maxY / lineHeight)) + overscan
        )
        return firstVisible..<max(firstVisible, lastVisible)
    }
}

