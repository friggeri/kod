import Foundation
import LanguageAdapters
import SettingsCore

struct CachedLanguageServerExecutable: Codable, Sendable, Equatable {
    let path: String
    let arguments: [String]
    let version: String?
    let source: ExecutableDiscoverySource

    init(_ executable: DiscoveredExecutable) {
        path = executable.url.standardizedFileURL.path
        arguments = executable.arguments
        version = executable.version
        source = executable.source
    }

    var discoveredExecutable: DiscoveredExecutable {
        DiscoveredExecutable(
            url: URL(fileURLWithPath: path),
            arguments: arguments,
            version: version,
            source: source
        )
    }
}

struct CachedLanguageServerStatus: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case available
        case missing
    }

    let kind: Kind
    let executable: CachedLanguageServerExecutable?
    let profileRevision: Int
    let selectedExecutable: RegisteredLanguageServerExecutable?
    let checkedAt: Date

    static func available(
        _ executable: DiscoveredExecutable,
        profile: LanguageProfile,
        checkedAt: Date = Date()
    ) -> CachedLanguageServerStatus {
        CachedLanguageServerStatus(
            kind: .available,
            executable: CachedLanguageServerExecutable(executable),
            profileRevision: profile.defaultRevision,
            selectedExecutable: profile.languageServer?.selectedExecutable,
            checkedAt: checkedAt
        )
    }

    static func missing(
        profile: LanguageProfile,
        checkedAt: Date = Date()
    ) -> CachedLanguageServerStatus {
        CachedLanguageServerStatus(
            kind: .missing,
            executable: nil,
            profileRevision: profile.defaultRevision,
            selectedExecutable: profile.languageServer?.selectedExecutable,
            checkedAt: checkedAt
        )
    }

    func serverState(
        for profile: LanguageProfile
    ) -> LanguageSupportServerState? {
        guard profile.defaultRevision == profileRevision,
              profile.languageServer?.selectedExecutable
                == selectedExecutable else {
            return nil
        }
        switch kind {
        case .available:
            guard let executable else {
                return nil
            }
            return .available(executable.discoveredExecutable)
        case .missing:
            return .missing(
                String(
                    localized: "No compatible language server was found."
                )
            )
        }
    }
}

private struct LanguageServerStatusCachePayload:
    Codable,
    Sendable,
    Equatable
{
    var entries: [String: CachedLanguageServerStatus]
}

struct LanguageServerStatusCacheStore {
    private static let setting = CodableSetting<LanguageServerStatusCachePayload>(
        key: "kod.language-server-status-cache",
        currentVersion: 1,
        validate: { payload in
            guard payload.entries.count <= 128 else {
                return SettingsValidationFailure(
                    reason: "Language-server status cache exceeds 128 entries."
                )
            }
            for (identifier, entry) in payload.entries {
                guard !identifier.isEmpty, identifier.count <= 128 else {
                    return SettingsValidationFailure(
                        reason: "Language-server status cache contains an invalid profile identifier."
                    )
                }
                if entry.kind == .available,
                   entry.executable == nil {
                    return SettingsValidationFailure(
                        reason: "Available language-server cache entry has no executable."
                    )
                }
                if let executable = entry.executable,
                   (
                       !executable.path.hasPrefix("/")
                           || executable.path.count > 4_096
                           || executable.arguments.count > 64
                   ) {
                    return SettingsValidationFailure(
                        reason: "Language-server status cache contains an invalid executable."
                    )
                }
            }
            return nil
        }
    )

    private let repository: CodableSettingsRepository

    init(repository: CodableSettingsRepository) {
        self.repository = repository
    }

    func load() throws(SettingsRepositoryError)
    -> [String: CachedLanguageServerStatus] {
        switch try repository.read(Self.setting) {
        case .value(let payload, _):
            return payload.entries
        case .absent, .quarantined:
            return [:]
        }
    }

    func save(
        _ entries: [String: CachedLanguageServerStatus]
    ) throws(SettingsRepositoryError) {
        try repository.write(
            LanguageServerStatusCachePayload(entries: entries),
            to: Self.setting
        )
    }
}
