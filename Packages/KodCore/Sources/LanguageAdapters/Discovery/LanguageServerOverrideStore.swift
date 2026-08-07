import Foundation
import WorkspaceCore

/// Explicit Kod-owned executable overrides for a language server, at
/// global scope or scoped to one trusted workspace. Both are stored in
/// `UserDefaults` — the same "external metadata that never writes into
/// the opened workspace" mechanism `WorkspaceTrustStore`/
/// `RecentWorkspaceStore` already use (SPEC 6.5: "explicit ... override
/// stored outside the repository"). Kod never reads or writes any
/// repository-provided configuration file to determine these.
///
/// Not `@MainActor`-isolated (unlike `WorkspaceTrustStore`): discovery
/// (including override lookup) happens on a background thread as part
/// of `LanguageAdapter.discover`, which mirrors Phase 6's synchronous,
/// blocking `SourceKitLSPDiscovery.discoverExecutableURL()` contract.
/// `UserDefaults` itself is documented thread-safe, so no additional
/// isolation is needed for correctness.
public final class LanguageServerOverrideStore: @unchecked Sendable {
    private struct StoredOverride: Codable {
        let path: String
        let arguments: [String]
    }

    private let defaults: UserDefaults
    private let globalKeyPrefix = "language-server-override.global."
    private let workspaceKeyPrefix = "language-server-override.workspace."

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func globalOverride(languageKey: String) -> (url: URL, arguments: [String])? {
        decoded(forKey: globalKeyPrefix + languageKey)
    }

    public func setGlobalOverride(url: URL, arguments: [String], languageKey: String) {
        encode(url: url, arguments: arguments, forKey: globalKeyPrefix + languageKey)
    }

    public func clearGlobalOverride(languageKey: String) {
        defaults.removeObject(forKey: globalKeyPrefix + languageKey)
    }

    public func workspaceOverride(languageKey: String, identity: WorkspaceIdentity) -> (url: URL, arguments: [String])? {
        decoded(forKey: workspaceKeyPrefix + languageKey + "." + identity.persistenceKey)
    }

    public func setWorkspaceOverride(url: URL, arguments: [String], languageKey: String, identity: WorkspaceIdentity) {
        encode(url: url, arguments: arguments, forKey: workspaceKeyPrefix + languageKey + "." + identity.persistenceKey)
    }

    public func clearWorkspaceOverride(languageKey: String, identity: WorkspaceIdentity) {
        defaults.removeObject(forKey: workspaceKeyPrefix + languageKey + "." + identity.persistenceKey)
    }

    private func decoded(forKey key: String) -> (url: URL, arguments: [String])? {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode(StoredOverride.self, from: data) else {
            return nil
        }
        return (URL(fileURLWithPath: stored.path), stored.arguments)
    }

    private func encode(url: URL, arguments: [String], forKey key: String) {
        let stored = StoredOverride(path: url.standardizedFileURL.path, arguments: arguments)
        guard let data = try? JSONEncoder().encode(stored) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}
