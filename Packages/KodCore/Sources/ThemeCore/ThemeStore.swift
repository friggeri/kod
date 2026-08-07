import DiagnosticsCore
import Foundation

/// Persists the active theme choice and any imported themes outside the
/// workspace, following the same `UserDefaults`-backed external-metadata
/// pattern as `WorkspaceLayoutStore` and `FontSettingsStore`.
///
/// Corrupt imported-theme data is quarantined and rebuilt (SPEC 15), never
/// silently treated as "no themes were ever imported" with no trace: see
/// `FontSettingsStore`'s doc comment for the same rationale, which applies
/// identically here.
@MainActor
public final class ThemeStore {
    private let defaults: UserDefaults
    private let activeThemeKey = "kod.active-theme-identifier"
    private let importedThemesKey = "kod.imported-themes"
    public let quarantine: CorruptStateQuarantine

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.quarantine = CorruptStateQuarantine(defaults: defaults)
    }

    public func activeThemeIdentifier() -> String? {
        defaults.string(forKey: activeThemeKey)
    }

    public func setActiveThemeIdentifier(_ identifier: String) {
        defaults.set(identifier, forKey: activeThemeKey)
    }

    public func importedThemes() -> [KodTheme] {
        switch quarantine.decode([KodTheme].self, forKey: importedThemesKey) {
        case .restored(let themes):
            return themes
        case .absent, .quarantined:
            return []
        }
    }

    public func addImportedTheme(_ theme: KodTheme) {
        var themes = importedThemes().filter { $0.identifier != theme.identifier }
        themes.append(theme)
        persist(themes)
    }

    public func removeImportedTheme(identifier: String) {
        persist(importedThemes().filter { $0.identifier != identifier })
    }

    public func theme(forIdentifier identifier: String) -> KodTheme? {
        BundledThemes.theme(forIdentifier: identifier)
            ?? importedThemes().first { $0.identifier == identifier }
    }

    /// The theme that should be active right now: the user's explicit
    /// choice if it still resolves, otherwise the bundled theme matching
    /// the current system appearance.
    public func resolvedActiveTheme(systemIsDark: Bool, systemIsHighContrast: Bool) -> KodTheme {
        if let identifier = activeThemeIdentifier(), let theme = theme(forIdentifier: identifier) {
            return theme
        }
        return BundledThemes.defaultTheme(isDark: systemIsDark, isHighContrast: systemIsHighContrast)
    }

    private func persist(_ themes: [KodTheme]) {
        guard let data = try? JSONEncoder().encode(themes) else {
            return
        }
        defaults.set(data, forKey: importedThemesKey)
    }
}
