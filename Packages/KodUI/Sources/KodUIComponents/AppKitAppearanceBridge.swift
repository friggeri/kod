import AppKit

/// Resolves an `NSAppearance` to the light/dark distinction Kod's
/// portable, appearance-aware values are keyed on (Material icons'
/// light-theme overrides today; future `KodUI` targets' theme variants).
///
/// This keeps the resolution rule in exactly one place instead of
/// re-deriving `bestMatch(from:)` at each call site, and makes it
/// testable headlessly without a window.
public enum AppKitAppearanceBridge {
    /// Whether `appearance` is one of macOS' light appearances.
    ///
    /// High-contrast and accessibility variants resolve through
    /// `bestMatch(from:)` to their `.aqua`/`.darkAqua` base, so an
    /// increased-contrast dark appearance is still dark here. Anything
    /// AppKit cannot match to `.darkAqua` is treated as light, which is
    /// the same default macOS itself falls back to.
    public static func isLight(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) != .darkAqua
    }
}
