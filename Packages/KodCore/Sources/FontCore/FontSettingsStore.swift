import DiagnosticsCore
import Foundation

/// Persists global font settings outside any workspace, in `UserDefaults`
/// under the Application Support-backed suite Kod already uses for other
/// external metadata (recent workspaces, layout restoration). Fonts are a
/// global preference, not a per-workspace one, so unlike
/// `WorkspaceLayoutStore` there is a single fixed key.
///
/// A corrupt/undecodable stored value is never silently discarded as if it
/// had simply never existed (SPEC 15: "Corrupt Kod metadata is quarantined
/// and rebuilt"): it is removed from the live key (via
/// `CorruptStateQuarantine`, so it cannot keep failing to decode on every
/// future launch) and recorded in `quarantine.ledger()` so a diagnostics/
/// support-bundle UI can surface that a preference reset happened, rather
/// than the reset looking indistinguishable from "first launch defaults."
@MainActor
public final class FontSettingsStore {
    private let defaults: UserDefaults
    private let key = "kod.font-settings"
    public let quarantine: CorruptStateQuarantine

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.quarantine = CorruptStateQuarantine(defaults: defaults)
    }

    public func load() -> FontSettings {
        switch quarantine.decode(FontSettings.self, forKey: key) {
        case .restored(let settings):
            return settings
        case .absent, .quarantined:
            return .default
        }
    }

    public func save(_ settings: FontSettings) {
        guard let data = try? JSONEncoder().encode(settings) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    public func reset() {
        defaults.removeObject(forKey: key)
    }
}
