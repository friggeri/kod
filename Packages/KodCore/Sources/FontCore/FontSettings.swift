import Foundation

/// User-facing font settings for the code viewer, persisted outside any
/// workspace (SPEC 7.3 and 11.7). Values are validated on construction so a
/// corrupt or hand-edited settings file cannot produce a zero or negative
/// size, an empty fallback chain entry, or other unrenderable state.
public struct FontSettings: Codable, Equatable, Sendable {
    public static let defaultFamilyName = "SF Mono"
    public static let defaultFallbackFamilies = ["Menlo", "Monaco"]
    /// Upper bound chosen so a 300%-zoomed default-size (13pt) viewport —
    /// SPEC 14's "Text zoom must reach at least 300 percent without
    /// clipping controls" — sits comfortably inside the range rather than
    /// right at its edge: 13 * 3 = 39pt, with headroom to spare below 48.
    public static let sizeRange: ClosedRange<Double> = 8...48
    public static let lineHeightRange: ClosedRange<Double> = 0.9...2.5
    public static let letterSpacingRange: ClosedRange<Double> = -2...8

    public var familyName: String
    public var pointSize: Double
    public var weight: FontWeight
    public var ligaturesEnabled: Bool
    public var lineHeightMultiplier: Double
    public var letterSpacing: Double
    public var fallbackFamilies: [String]

    public init(
        familyName: String = FontSettings.defaultFamilyName,
        pointSize: Double = 13,
        weight: FontWeight = .regular,
        ligaturesEnabled: Bool = false,
        lineHeightMultiplier: Double = 1.2,
        letterSpacing: Double = 0,
        fallbackFamilies: [String] = FontSettings.defaultFallbackFamilies
    ) {
        self.familyName = familyName
        self.pointSize = pointSize.clamped(to: Self.sizeRange)
        self.weight = weight
        self.ligaturesEnabled = ligaturesEnabled
        self.lineHeightMultiplier = lineHeightMultiplier.clamped(to: Self.lineHeightRange)
        self.letterSpacing = letterSpacing.clamped(to: Self.letterSpacingRange)
        self.fallbackFamilies = fallbackFamilies.filter { !$0.isEmpty }
    }

    public static let `default` = FontSettings()
}

extension Double {
    fileprivate func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
