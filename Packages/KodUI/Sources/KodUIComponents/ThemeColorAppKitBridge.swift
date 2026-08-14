import AppKit
import TextDecorationModel

/// Converts between `TextDecorationModel`'s portable `ThemeColor` value
/// and AppKit's `NSColor`.
///
/// `ThemeColor` stays in `TextDecorationModel` precisely so the parser,
/// the LSP transport, the theme schema, and every other non-presentation
/// target can describe color without importing AppKit. This bridge is
/// the presentation-side counterpart: it lives in `KodUI`, the only
/// package allowed to depend on both, so converting a color never pulls
/// AppKit back into a `KodCore` domain/parser/transport target.
///
/// It is deliberately a namespace of functions rather than an extension
/// on `ThemeColor`: `CodeViewport` already vends `ThemeColor.nsColor`
/// for the code viewport it paints, and a second extension member with
/// the same name would make every call site that imports both modules
/// ambiguous.
public enum ThemeColorAppKitBridge {
    /// The sRGB `NSColor` for `color`. `ThemeColor` components are
    /// already sRGB, so this conversion is exact and never fails.
    public static func nsColor(_ color: ThemeColor) -> NSColor {
        NSColor(
            srgbRed: CGFloat(color.red),
            green: CGFloat(color.green),
            blue: CGFloat(color.blue),
            alpha: CGFloat(color.alpha)
        )
    }

    /// The portable `ThemeColor` for `nsColor`, or `nil` when the color
    /// has no sRGB representation.
    ///
    /// The nil case is real, not defensive padding: pattern colors (and
    /// any other color whose `usingColorSpace(.sRGB)` returns `nil`)
    /// have no component values to read, and asking for
    /// `redComponent` on one is undefined. Callers get an explicit
    /// failure to handle instead of a fabricated color. The contract is
    /// exactly: this returns `nil` if and only if
    /// `nsColor.usingColorSpace(.sRGB)` does.
    public static func themeColor(_ nsColor: NSColor) -> ThemeColor? {
        guard let converted = nsColor.usingColorSpace(.sRGB) else {
            return nil
        }
        return ThemeColor(
            red: Double(converted.redComponent),
            green: Double(converted.greenComponent),
            blue: Double(converted.blueComponent),
            alpha: Double(converted.alphaComponent)
        )
    }
}
