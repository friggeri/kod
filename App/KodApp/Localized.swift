import Foundation

/// Thin wrapper around Swift's built-in String Catalog resolution
/// mechanism, `String(localized:comment:)` — Apple's real, current API
/// for resolving a string against an Xcode String Catalog
/// (`Localizable.xcstrings`) at runtime (SPEC 14: "User-facing strings
/// are localized through string catalogs from the first release, even
/// if 1.0 initially ships in English"). This is intentionally not a
/// custom bundle/`.strings`-table lookup system: `String(localized:)`
/// already reads from whichever String Catalog is bundled with the
/// target, matching on the literal source string used as the key.
///
/// AppKit call sites (menu item titles, button titles, panel/alert
/// messages, `accessibilityLabel()`/`accessibilityHelp()`/
/// `accessibilityRoleDescription()` override return values) funnel
/// through `Localized.string(_:comment:)` so the original English text
/// stays the catalog key and every migrated string carries a real
/// `comment:` describing where/how it is shown, giving a translator or
/// reviewer context.
///
/// SwiftUI's own `Text(_:)`, `Label(_:systemImage:)`, and other
/// `LocalizedStringKey`-based initializers already resolve against the
/// same catalog automatically when given a plain string literal (Swift
/// prefers the concrete `LocalizedStringKey` overload over the generic,
/// verbatim `StringProtocol` overload for literals written directly in
/// source) — those call sites keep using `Text("...", comment: "...")`
/// directly rather than this helper. `Localized.string` is for the
/// modifiers and AppKit APIs that only accept a plain `String` and
/// otherwise would treat literal text as verbatim, unlocalized content
/// (for example `.accessibilityLabel(_:)`'s `StringProtocol` overload).
enum Localized {
    /// Resolves `key` against the app's String Catalog. `key` keeps the
    /// exact English source text so it matches the catalog entry; a
    /// non-optional `comment` is required so every migrated call site
    /// documents its context for translators/reviewers.
    static func string(_ key: String.LocalizationValue, comment: StaticString) -> String {
        String(localized: key, comment: comment)
    }
}
