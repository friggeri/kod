import CryptoKit
import Foundation
import SettingsCore

public enum WorkspaceIdentityError: Error, Equatable {
    case notDirectory(URL)
}

public struct WorkspaceIdentity: Hashable, Sendable {
    public let root: URL
    public let volumeIdentifier: String

    public init(root: URL) throws {
        let canonicalRoot = root
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let values = try canonicalRoot.resourceValues(forKeys: [
            .isDirectoryKey,
            .volumeIdentifierKey
        ])

        guard values.isDirectory == true else {
            throw WorkspaceIdentityError.notDirectory(canonicalRoot)
        }

        self.root = canonicalRoot
        if let volumeIdentifier = values.volumeIdentifier {
            self.volumeIdentifier = String(describing: volumeIdentifier)
        } else {
            self.volumeIdentifier = "unknown-volume"
        }
    }

    public var persistenceKey: String {
        let source = "\(volumeIdentifier)\u{0}\(root.path)"
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
public final class WorkspaceTrustStore {
    private let keyPrefix = "trusted-workspace."
    private let trustBannerShownKeyPrefix = "workspace-trust-banner-shown."
    private let repository: CodableSettingsRepository
    private var sessionRevocations: Set<String> = []
    public private(set) var lastPersistenceError: SettingsRepositoryError?

    public init(repository: CodableSettingsRepository) {
        self.repository = repository
    }

    /// Compatibility with `WorkspaceTrustAuthorizing`'s nonthrowing security
    /// gate. Persistence-backed callers that need to handle storage failure
    /// should call `trustState(_:)`; the gate itself cannot safely authorize
    /// when its persistence contract failed. Such a failure is exposed in
    /// `lastPersistenceError` and fails closed.
    public func isTrusted(_ identity: WorkspaceIdentity) -> Bool {
        do {
            switch try trustState(identity) {
            case .trusted:
                lastPersistenceError = nil
                return true
            case .untrusted, .resetAfterQuarantine:
                lastPersistenceError = nil
                return false
            }
        } catch {
            lastPersistenceError = error
            return false
        }
    }

    public func trustState(
        _ identity: WorkspaceIdentity
    ) throws(SettingsRepositoryError) -> WorkspaceTrustState {
        guard !sessionRevocations.contains(identity.persistenceKey) else {
            return .untrusted
        }
        switch try repository.read(trustSetting(for: identity)) {
        case .absent:
            return .untrusted
        case .value(let trusted, _):
            return trusted ? .trusted : .untrusted
        case .quarantined(let record):
            return .resetAfterQuarantine(record)
        }
    }

    public func trust(
        _ identity: WorkspaceIdentity
    ) throws(SettingsRepositoryError) {
        try repository.write(true, to: trustSetting(for: identity))
        sessionRevocations.remove(identity.persistenceKey)
    }

    public func revoke(
        _ identity: WorkspaceIdentity
    ) throws(SettingsRepositoryError) {
        sessionRevocations.insert(identity.persistenceKey)
        try repository.remove(trustSetting(for: identity))
    }

    /// Returns `true` once for each persisted workspace identity, then
    /// records that the initial trust banner has been presented.
    public func claimInitialTrustBannerPresentation(
        for identity: WorkspaceIdentity
    ) throws(SettingsRepositoryError) -> Bool {
        let setting = trustBannerSetting(for: identity)
        if case .value(true, _) = try repository.read(setting) {
            return false
        }
        try repository.write(true, to: setting)
        return true
    }

    private func trustSetting(
        for identity: WorkspaceIdentity
    ) -> CodableSetting<Bool> {
        booleanSetting(key: keyPrefix + identity.persistenceKey)
    }

    private func trustBannerSetting(
        for identity: WorkspaceIdentity
    ) -> CodableSetting<Bool> {
        booleanSetting(
            key: trustBannerShownKeyPrefix + identity.persistenceKey
        )
    }

    private func booleanSetting(key: String) -> CodableSetting<Bool> {
        CodableSetting(
            key: key,
            currentVersion: 1,
            migrations: [
                .unversionedStoredValue { value in
                    guard case .boolean(let boolean) = value else {
                        return .failure(
                            SettingsMigrationFailure(
                                reason: "Expected a legacy Boolean."
                            )
                        )
                    }
                    return .success(boolean)
                }
            ]
        )
    }
}

public enum WorkspaceTrustState: Sendable, Equatable {
    case untrusted
    case trusted
    case resetAfterQuarantine(SettingsQuarantineRecord)
}

@MainActor
public final class RecentWorkspaceStore {
    private static let setting = CodableSetting<[String]>(
        key: "recent-workspaces",
        currentVersion: 1,
        migrations: [
            .unversionedStoredValue { value in
                guard case .stringArray(let paths) = value else {
                    return .failure(
                        SettingsMigrationFailure(
                            reason: "Expected a legacy string array."
                        )
                    )
                }
                return .success(paths)
            }
        ]
    )
    private let repository: CodableSettingsRepository
    private let limit: Int

    public init(
        repository: CodableSettingsRepository,
        limit: Int = 10
    ) {
        self.repository = repository
        self.limit = max(1, limit)
    }

    public func roots(
    ) throws(SettingsRepositoryError) -> SettingsLoadOutcome<[URL]> {
        switch try repository.read(Self.setting) {
        case .absent:
            return .absent
        case .value(let paths, let provenance):
            return .value(
                paths.map { URL(fileURLWithPath: $0, isDirectory: true) },
                provenance: provenance
            )
        case .quarantined(let record):
            return .quarantined(record)
        }
    }

    public func record(
        _ root: URL
    ) throws(SettingsRepositoryError) {
        let path = root.standardizedFileURL.path
        let existingPaths: [String]
        switch try repository.read(Self.setting) {
        case .value(let paths, _):
            existingPaths = paths
        case .absent, .quarantined:
            existingPaths = []
        }
        var paths = existingPaths
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        try repository.write(
            Array(paths.prefix(limit)),
            to: Self.setting
        )
    }

    public func removeAll() throws(SettingsRepositoryError) {
        try repository.remove(Self.setting)
    }
}
