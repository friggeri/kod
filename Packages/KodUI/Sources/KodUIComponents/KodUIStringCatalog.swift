import Foundation

/// A localization key declared by a `KodUI` target's own package
/// resource bundle.
///
/// Package targets cannot read the app's Xcode String Catalog
/// (`App/KodApp/Resources/Localizable.xcstrings`): a SwiftPM target resolves
/// strings against its own `Bundle.module`. So `KodUI` targets keep
/// explicit, namespaced identifier keys (`kodui.<area>.<purpose>`)
/// rather than English-source-text keys — that way a missing
/// translation is *observable* (the key comes back, and it never looks
/// like a plausible English sentence) instead of silently rendering as
/// untranslated prose.
public struct KodUIStringKey: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public extension KodUIStringKey {
    /// Role description a read-only text surface reports to assistive
    /// technologies.
    static let readOnlyTextAccessibilityRoleDescription = KodUIStringKey(
        rawValue: "kodui.readOnlyText.accessibilityRoleDescription"
    )
}

extension KodUIStringKey {
    /// Every key `KodUIComponents`' own catalog declares. Tests assert
    /// each one resolves to a real entry, so a key can never be added
    /// in code without its `Localizable.strings` entry (or vice versa).
    static let componentKeys: [KodUIStringKey] = [
        .readOnlyTextAccessibilityRoleDescription
    ]
}

/// Package-local localized string lookup for `KodUI`'s AppKit targets
/// (SPEC 14: user-facing strings are localized from the first release).
///
/// This is a thin, explicit wrapper over Foundation's real bundle-table
/// lookup — not a custom translation mechanism. Each `KodUI` target
/// owns its own `<locale>.lproj/Localizable.strings` inside its target
/// directory and exposes a catalog bound to its own `Bundle.module`,
/// which is how `SearchUI`/`PreviewUI`/`GitUI`/`EditorUI` localize their
/// own strings without either sharing a
/// mutable global or reaching into `Bundle.main` (the app bundle is not
/// theirs to read).
///
/// Lookup failure is deliberately *not* silent-but-plausible: a missing
/// entry returns the key itself, which is visibly a key.
public struct KodUIStringCatalog: Sendable {
    private let bundle: Bundle
    private let table: String

    /// - Parameters:
    ///   - bundle: the owning target's `Bundle.module`.
    ///   - table: the `.strings` table name inside that bundle.
    public init(bundle: Bundle, table: String = "Localizable") {
        self.bundle = bundle
        self.table = table
    }

    /// Resolves `key` against this catalog's bundle and table.
    ///
    /// `comment` is required, and documents for a translator or
    /// reviewer where and how the string is shown — the same contract
    /// the app layer's `Localized.string(_:comment:)` enforces.
    ///
    /// - Returns: the localized value, or `key.rawValue` when the
    ///   catalog has no entry for it.
    public func string(_ key: KodUIStringKey, comment: StaticString) -> String {
        bundle.localizedString(forKey: key.rawValue, value: key.rawValue, table: table)
    }

    /// Resolves an English-source localization key, including Swift
    /// interpolation, in this catalog's resource bundle. If the key is
    /// absent, Foundation preserves the English source string.
    public func string(_ key: String.LocalizationValue, comment: StaticString) -> String {
        String(
            localized: key,
            table: table,
            bundle: bundle,
            comment: comment
        )
    }
}

public extension KodUIStringCatalog {
    /// The catalog backing `KodUIComponents`' own strings.
    static var components: KodUIStringCatalog {
        KodUIStringCatalog(bundle: .module)
    }
}
