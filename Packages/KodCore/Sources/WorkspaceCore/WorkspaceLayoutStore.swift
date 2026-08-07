import DiagnosticsCore
import Foundation

/// Persists and restores a workspace window's split layout, tabs, selection,
/// navigation history, and word-wrap preference outside the opened
/// repository, keyed by the workspace's canonicalized identity — following
/// the same `UserDefaults`-backed, external-metadata pattern already used by
/// `WorkspaceTrustStore` and `RecentWorkspaceStore`.
///
/// Corrupt layout metadata is quarantined and rebuilt (SPEC 15) rather than
/// silently falling back to "no saved layout" with no trace: see
/// `FontCore.FontSettingsStore`'s doc comment for the identical rationale.
@MainActor
public final class WorkspaceLayoutStore {
    private let defaults: UserDefaults
    private let keyPrefix = "workspace-layout."
    public let quarantine: CorruptStateQuarantine

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.quarantine = CorruptStateQuarantine(defaults: defaults)
    }

    public func load(for identity: WorkspaceIdentity) -> WorkspaceLayoutState? {
        switch quarantine.decode(WorkspaceLayoutState.self, forKey: key(for: identity)) {
        case .restored(let state):
            return state
        case .absent, .quarantined:
            return nil
        }
    }

    public func save(_ state: WorkspaceLayoutState, for identity: WorkspaceIdentity) {
        guard let data = try? JSONEncoder().encode(state) else {
            return
        }
        defaults.set(data, forKey: key(for: identity))
    }

    public func clear(for identity: WorkspaceIdentity) {
        defaults.removeObject(forKey: key(for: identity))
    }

    private func key(for identity: WorkspaceIdentity) -> String {
        keyPrefix + identity.persistenceKey
    }
}
