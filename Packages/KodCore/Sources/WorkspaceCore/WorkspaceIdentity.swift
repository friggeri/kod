import CryptoKit
import Foundation

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
    private let defaults: UserDefaults
    private let keyPrefix = "trusted-workspace."
    private let trustBannerShownKeyPrefix = "workspace-trust-banner-shown."

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func isTrusted(_ identity: WorkspaceIdentity) -> Bool {
        defaults.bool(forKey: keyPrefix + identity.persistenceKey)
    }

    public func trust(_ identity: WorkspaceIdentity) {
        defaults.set(true, forKey: keyPrefix + identity.persistenceKey)
    }

    public func revoke(_ identity: WorkspaceIdentity) {
        defaults.removeObject(forKey: keyPrefix + identity.persistenceKey)
    }

    /// Returns `true` once for each persisted workspace identity, then
    /// records that the initial trust banner has been presented.
    public func claimInitialTrustBannerPresentation(for identity: WorkspaceIdentity) -> Bool {
        let key = trustBannerShownKeyPrefix + identity.persistenceKey
        guard !defaults.bool(forKey: key) else {
            return false
        }
        defaults.set(true, forKey: key)
        return true
    }
}

@MainActor
public final class RecentWorkspaceStore {
    private let defaults: UserDefaults
    private let key = "recent-workspaces"
    private let limit: Int

    public init(defaults: UserDefaults = .standard, limit: Int = 10) {
        self.defaults = defaults
        self.limit = max(1, limit)
    }

    public var roots: [URL] {
        (defaults.stringArray(forKey: key) ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public func record(_ root: URL) {
        let path = root.standardizedFileURL.path
        var paths = roots.map(\.path)
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        defaults.set(Array(paths.prefix(limit)), forKey: key)
    }

    public func removeAll() {
        defaults.removeObject(forKey: key)
    }
}
