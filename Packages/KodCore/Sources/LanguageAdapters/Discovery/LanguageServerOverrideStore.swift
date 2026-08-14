import Foundation
import SettingsCore
import WorkspaceCore

public struct LanguageServerOverride: Sendable, Equatable {
    public let url: URL
    public let arguments: [String]

    public init(url: URL, arguments: [String]) {
        self.url = url
        self.arguments = arguments
    }
}

/// Explicit Kod-owned executable overrides for a language server, at
/// global scope or scoped to one trusted workspace. Both use the injected
/// SettingsCore repository — the same "external metadata that never writes
/// into the opened workspace" mechanism `WorkspaceTrustStore` and
/// `RecentWorkspaceStore` use (SPEC 6.5). Kod never reads or writes any
/// repository-provided configuration file to determine these.
///
/// Not `@MainActor`-isolated (unlike `WorkspaceTrustStore`): discovery
/// (including override lookup) happens on a background thread as part of
/// `LanguageServerDiscoveryEngine.resolve(profile:...)`, which mirrors
/// Phase 6's synchronous, blocking
/// `SourceKitLSPDiscovery.discoverExecutableURL()` contract.
/// SettingsCore's repositories are synchronous and thread-safe, so no
/// actor isolation is required here.
public final class LanguageServerOverrideStore: @unchecked Sendable {
    private struct StoredOverride: Codable, Sendable {
        let path: String
        let arguments: [String]
    }

    private let globalKeyPrefix = "language-server-override.global."
    private let workspaceKeyPrefix = "language-server-override.workspace."
    private let repository: CodableSettingsRepository

    public init(repository: CodableSettingsRepository) {
        self.repository = repository
    }

    public func globalOverride(
        languageKey: String
    ) throws(SettingsRepositoryError) -> SettingsLoadOutcome<LanguageServerOverride> {
        try decoded(forKey: globalKeyPrefix + languageKey)
    }

    public func setGlobalOverride(
        url: URL,
        arguments: [String],
        languageKey: String
    ) throws(SettingsRepositoryError) {
        try encode(
            url: url,
            arguments: arguments,
            forKey: globalKeyPrefix + languageKey
        )
    }

    public func clearGlobalOverride(
        languageKey: String
    ) throws(SettingsRepositoryError) {
        try repository.remove(setting(forKey: globalKeyPrefix + languageKey))
    }

    public func workspaceOverride(
        languageKey: String,
        identity: WorkspaceIdentity
    ) throws(SettingsRepositoryError) -> SettingsLoadOutcome<LanguageServerOverride> {
        try decoded(
            forKey: workspaceKeyPrefix + languageKey + "."
                + identity.persistenceKey
        )
    }

    public func setWorkspaceOverride(
        url: URL,
        arguments: [String],
        languageKey: String,
        identity: WorkspaceIdentity
    ) throws(SettingsRepositoryError) {
        try encode(
            url: url,
            arguments: arguments,
            forKey: workspaceKeyPrefix + languageKey + "."
                + identity.persistenceKey
        )
    }

    public func clearWorkspaceOverride(
        languageKey: String,
        identity: WorkspaceIdentity
    ) throws(SettingsRepositoryError) {
        try repository.remove(
            setting(
                forKey: workspaceKeyPrefix + languageKey + "."
                    + identity.persistenceKey
            )
        )
    }

    public func observeChanges(
        languageKey: String,
        identity: WorkspaceIdentity? = nil,
        _ observer: @escaping @Sendable (SettingsChange) -> Void
    ) -> SettingsObservation {
        if let identity {
            return repository.observe(
                setting(
                    forKey: workspaceKeyPrefix + languageKey + "."
                        + identity.persistenceKey
                ),
                observer
            )
        }
        return repository.observe(
            setting(forKey: globalKeyPrefix + languageKey),
            observer
        )
    }

    private func decoded(
        forKey key: String
    ) throws(SettingsRepositoryError) -> SettingsLoadOutcome<LanguageServerOverride> {
        switch try repository.read(setting(forKey: key)) {
        case .absent:
            return .absent
        case .value(let stored, let provenance):
            return .value(
                LanguageServerOverride(
                    url: URL(fileURLWithPath: stored.path),
                    arguments: stored.arguments
                ),
                provenance: provenance
            )
        case .quarantined(let record):
            return .quarantined(record)
        }
    }

    private func encode(
        url: URL,
        arguments: [String],
        forKey key: String
    ) throws(SettingsRepositoryError) {
        let stored = StoredOverride(path: url.standardizedFileURL.path, arguments: arguments)
        try repository.write(stored, to: setting(forKey: key))
    }

    private func setting(
        forKey key: String
    ) -> CodableSetting<StoredOverride> {
        CodableSetting(
            key: key,
            currentVersion: 1,
            migrations: [
                .unversionedCodable(StoredOverride.self) { $0 }
            ]
        )
    }
}
