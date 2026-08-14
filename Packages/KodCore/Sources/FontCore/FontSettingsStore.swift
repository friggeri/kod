import Foundation
import SettingsCore

/// Persists global font settings outside any workspace through an injected
/// SettingsCore repository. Fonts are a global preference, not a
/// per-workspace one, so unlike `WorkspaceLayoutStore` there is a single
/// fixed key.
///
/// A corrupt/undecodable stored value is never silently discarded as if it
/// had simply never existed (SPEC 15: "Corrupt Kod metadata is quarantined
/// and rebuilt"): it is removed from the live key (via
/// `SettingsQuarantine`, so it cannot keep failing to decode on every
/// future launch) and recorded in `quarantine.records()` so a diagnostics/
/// support-bundle UI can surface that a preference reset happened, rather
/// than the reset looking indistinguishable from "first launch defaults."
@MainActor
public final class FontSettingsStore {
    private static let setting = CodableSetting<FontSettings>(
        key: "kod.font-settings",
        currentVersion: 1,
        migrations: [
            .unversionedCodable(FontSettings.self) { $0 }
        ],
        validate: { settings in
            if settings.familyName.isEmpty {
                return SettingsValidationFailure(
                    reason: "The primary font family is empty."
                )
            }
            if !FontSettings.sizeRange.contains(settings.pointSize) {
                return SettingsValidationFailure(
                    reason: "The font point size is outside the supported range."
                )
            }
            if !FontSettings.lineHeightRange.contains(
                settings.lineHeightMultiplier
            ) {
                return SettingsValidationFailure(
                    reason: "The line height is outside the supported range."
                )
            }
            if !FontSettings.letterSpacingRange.contains(
                settings.letterSpacing
            ) {
                return SettingsValidationFailure(
                    reason: "The letter spacing is outside the supported range."
                )
            }
            if settings.fallbackFamilies.contains(where: \.isEmpty) {
                return SettingsValidationFailure(
                    reason: "A fallback font family is empty."
                )
            }
            return nil
        }
    )
    private let repository: CodableSettingsRepository

    public init(repository: CodableSettingsRepository) {
        self.repository = repository
    }

    public var quarantine: SettingsQuarantine {
        repository.quarantine
    }

    public func load(
    ) throws(SettingsRepositoryError) -> SettingsLoadOutcome<FontSettings> {
        try repository.read(Self.setting)
    }

    public func save(
        _ settings: FontSettings
    ) throws(SettingsRepositoryError) {
        try repository.write(settings, to: Self.setting)
    }

    public func reset() throws(SettingsRepositoryError) {
        try repository.remove(Self.setting)
    }

    public func observeChanges(
        _ observer: @escaping @Sendable (SettingsChange) -> Void
    ) -> SettingsObservation {
        repository.observe(Self.setting, observer)
    }
}
