import AppKit

/// The result of turning `FontSettings` into concrete AppKit/Core Text
/// state: the resolved primary `NSFont` (AppKit/Core Text supplies glyph
/// fallback during layout), the derived line height and monospace character
/// width `CodeViewport` uses for column alignment, ready-made drawing
/// attributes, and an optional warning when the chosen family is not
/// fixed-pitch.
public struct ResolvedFont: @unchecked Sendable {
    public let nsFont: NSFont
    public let lineHeight: CGFloat
    public let characterWidth: CGFloat
    public let ligaturesEnabled: Bool
    public let letterSpacing: CGFloat
    /// Non-`nil` when `familyName` is not a fixed-pitch face. Per SPEC 7.3,
    /// Kod must still render safely — alignment for tabs, indentation
    /// guides, selections, diagnostics, and inline hints may simply vary.
    public let alignmentWarning: String?

    /// Ligature attribute value matching `NSAttributedString.Key.ligature`
    /// semantics (`0` disabled, `1` standard ligatures).
    public var ligatureAttributeValue: Int {
        ligaturesEnabled ? 1 : 0
    }
}

public enum FontResolver {
    public static func resolve(_ settings: FontSettings) -> ResolvedFont {
        let descriptor = fontDescriptor(for: settings)
        let font = NSFont(
            descriptor: descriptor,
            size: CGFloat(settings.pointSize)
        ) ?? NSFont.monospacedSystemFont(ofSize: CGFloat(settings.pointSize), weight: settings.weight.nsFontWeight)

        let lineHeight = ceil(
            (font.ascender - font.descender + font.leading) * CGFloat(settings.lineHeightMultiplier)
        )
        let characterWidth = ceil(
            ("M" as NSString).size(withAttributes: [.font: font]).width
        )

        let isMonospaced = MonospacedFontDiscovery.isFamilyMonospaced(settings.familyName)
        let warning = isMonospaced
            ? nil
            : "\"\(settings.familyName)\" is not a monospaced font; column alignment may vary."

        return ResolvedFont(
            nsFont: font,
            lineHeight: max(1, lineHeight),
            characterWidth: max(1, characterWidth),
            ligaturesEnabled: settings.ligaturesEnabled,
            letterSpacing: CGFloat(settings.letterSpacing),
            alignmentWarning: warning
        )
    }

    private static func fontDescriptor(for settings: FontSettings) -> NSFontDescriptor {
        NSFontDescriptor(fontAttributes: [
            .family: settings.familyName,
            .traits: [NSFontDescriptor.TraitKey.weight: weightTraitValue(settings.weight)]
        ])
    }

    private static func weightTraitValue(_ weight: FontWeight) -> CGFloat {
        // NSFontDescriptor trait weights range roughly -1...1, matching
        // NSFont.Weight's raw values, which are already in that domain.
        weight.nsFontWeight.rawValue
    }
}
