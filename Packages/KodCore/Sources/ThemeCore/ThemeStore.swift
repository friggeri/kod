import Foundation
import SettingsCore

/// Persists the active theme choice and any imported themes outside the
/// workspace through an injected SettingsCore repository shared with
/// `WorkspaceLayoutStore` and `FontSettingsStore`.
///
/// Corrupt imported-theme data is quarantined and rebuilt (SPEC 15), never
/// silently treated as "no themes were ever imported" with no trace: see
/// `FontSettingsStore`'s doc comment for the same rationale, which applies
/// identically here.
@MainActor
public final class ThemeStore {
    private static let activeThemeSetting = CodableSetting<String>(
        key: "kod.active-theme-identifier",
        currentVersion: 1,
        migrations: [
            .unversionedStoredValue { value in
                guard case .string(let identifier) = value else {
                    return .failure(
                        SettingsMigrationFailure(
                            reason: "Expected a legacy theme identifier string."
                        )
                    )
                }
                return .success(identifier)
            }
        ],
        validate: {
            $0.isEmpty
                ? SettingsValidationFailure(
                    reason: "The active theme identifier is empty."
                )
                : nil
        }
    )
    private static let importedThemesSetting = CodableSetting<[KodTheme]>(
        key: "kod.imported-themes",
        currentVersion: 1,
        migrations: [
            .unversionedCodable([KodTheme].self) { $0 }
        ]
    )
    private let repository: CodableSettingsRepository

    public init(repository: CodableSettingsRepository) {
        self.repository = repository
    }

    public var quarantine: SettingsQuarantine {
        repository.quarantine
    }

    public func activeThemeIdentifier(
    ) throws(SettingsRepositoryError) -> SettingsLoadOutcome<String> {
        try repository.read(Self.activeThemeSetting)
    }

    public func setActiveThemeIdentifier(
        _ identifier: String
    ) throws(SettingsRepositoryError) {
        try repository.write(identifier, to: Self.activeThemeSetting)
    }

    public func importedThemes(
    ) throws(SettingsRepositoryError) -> SettingsLoadOutcome<[KodTheme]> {
        try repository.read(Self.importedThemesSetting)
    }

    public func addImportedTheme(
        _ theme: KodTheme
    ) throws(SettingsRepositoryError) {
        var themes = try resolvedImportedThemes()
            .filter { $0.identifier != theme.identifier }
        themes.append(theme)
        try repository.write(themes, to: Self.importedThemesSetting)
    }

    public func removeImportedTheme(
        identifier: String
    ) throws(SettingsRepositoryError) {
        let themes = try resolvedImportedThemes().filter {
            $0.identifier != identifier
        }
        try repository.write(
            themes,
            to: Self.importedThemesSetting
        )
    }

    public func theme(
        forIdentifier identifier: String
    ) throws(SettingsRepositoryError) -> KodTheme? {
        if let bundled = BundledThemes.theme(forIdentifier: identifier) {
            return bundled
        }
        return try resolvedImportedThemes().first {
            $0.identifier == identifier
        }
    }

    /// The Kod theme matching the current system appearance. Persisted theme
    /// choices are retained for migration compatibility but no longer affect
    /// presentation.
    public func resolvedActiveTheme(
        systemIsDark: Bool,
        systemIsHighContrast _: Bool
    ) throws(SettingsRepositoryError) -> KodTheme {
        BundledThemes.defaultTheme(
            isDark: systemIsDark,
            isHighContrast: false
        )
    }

    public func observeChanges(
        _ observer: @escaping @Sendable (SettingsChange) -> Void
    ) -> SettingsObservation {
        SettingsObservation.combine([
            repository.observe(Self.activeThemeSetting, observer),
            repository.observe(Self.importedThemesSetting, observer)
        ])
    }

    private func resolvedImportedThemes(
    ) throws(SettingsRepositoryError) -> [KodTheme] {
        switch try importedThemes() {
        case .value(let themes, _):
            return themes
        case .absent, .quarantined:
            return []
        }
    }
}
