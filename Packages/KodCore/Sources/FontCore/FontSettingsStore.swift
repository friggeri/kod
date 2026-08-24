import Foundation
import SettingsCore

private struct FontSettingsV1: Codable, Sendable {
    let familyName: String
    let pointSize: Double
    let weight: FontWeight
    let ligaturesEnabled: Bool
    let lineHeightMultiplier: Double
    let letterSpacing: Double
    let fallbackFamilies: [String]

    func migrated() -> FontSettings {
        var settings = FontSettings()
        settings.familyName = familyName
        settings.pointSize = pointSize
        settings.weight = weight
        settings.ligaturesEnabled = ligaturesEnabled
        settings.lineHeightMultiplier = lineHeightMultiplier
        settings.letterSpacing = letterSpacing
        return settings
    }
}

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
/// support tool can report that a preference reset happened, rather than the
/// reset looking indistinguishable from "first launch defaults."
@MainActor
public final class FontSettingsStore {
    private static let setting = CodableSetting<FontSettings>(
        key: "kod.font-settings",
        currentVersion: 2,
        migrations: [
            .unversionedCodable(FontSettingsV1.self) { $0.migrated() },
            .versioned(from: 1, FontSettingsV1.self) { $0.migrated() }
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
