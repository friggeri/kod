import Foundation
import ManagedLanguageServers

/// One published Kod release as it appears in the signed update feed
/// (SPEC 13.3: "Network activity is attributable in the UI to app
/// update ..."; SPEC 17 M4: "Signed/notarized distribution, updater").
///
/// `architecture` is `nil` for a universal (arm64 + x86_64) build
/// artifact and a specific `ManagedInstallArchitecture` for an
/// architecture-specific one — mirroring
/// `ManagedServerArtifact`'s own per-architecture modeling in
/// `ManagedLanguageServers`, since Kod ships Apple-silicon-first with
/// Intel best-effort (SPEC "Architecture priority").
///
/// `isRollbackTarget` is the *only* thing that makes an older,
/// already-signed entry usable as a rollback destination
/// (`UpdateFeedVerifier.rollbackCandidate`): an entry the release
/// process never marked this way can never be offered as a rollback,
/// even though it remains a perfectly valid, signature-verifiable
/// historical entry in the feed. This keeps "roll back to a previous
/// version" an explicit, curated release decision rather than an
/// automatic "pick any older signed version" policy that could be
/// abused to downgrade past a since-patched vulnerability.
public struct UpdateFeedEntry: Codable, Sendable, Equatable {
    public let version: SemanticVersion
    public let minimumSystemVersion: SemanticVersion
    public let architecture: ManagedInstallArchitecture?
    public let downloadURL: URL
    public let sha256Hex: String
    public let publishedAt: Date
    public let releaseNotesURL: URL?
    public let isCriticalSecurityUpdate: Bool
    public let isRollbackTarget: Bool

    public init(
        version: SemanticVersion,
        minimumSystemVersion: SemanticVersion,
        architecture: ManagedInstallArchitecture? = nil,
        downloadURL: URL,
        sha256Hex: String,
        publishedAt: Date,
        releaseNotesURL: URL? = nil,
        isCriticalSecurityUpdate: Bool = false,
        isRollbackTarget: Bool = false
    ) {
        self.version = version
        self.minimumSystemVersion = minimumSystemVersion
        self.architecture = architecture
        self.downloadURL = downloadURL
        self.sha256Hex = sha256Hex
        self.publishedAt = publishedAt
        self.releaseNotesURL = releaseNotesURL
        self.isCriticalSecurityUpdate = isCriticalSecurityUpdate
        self.isRollbackTarget = isRollbackTarget
    }

    /// Whether this entry's artifact can run on `runningArchitecture`:
    /// a universal entry (`architecture == nil`) runs anywhere; an
    /// architecture-specific entry only matches its own architecture
    /// (there is deliberately no Rosetta-translation assumption here —
    /// an x86_64-only entry is never offered as an update on arm64 even
    /// though Rosetta could technically run it, since Kod always
    /// prefers offering the native arm64 or universal artifact first).
    public func isCompatible(withRunningArchitecture runningArchitecture: ManagedInstallArchitecture) -> Bool {
        guard let architecture else {
            return true
        }
        return architecture == runningArchitecture
    }
}

/// The full signed update feed: every published entry Kod's release
/// process has ever signed, oldest and newest alike (older, non-rollback
/// entries simply remain present for historical/audit purposes and are
/// never offered by `UpdateFeedVerifier`).
public struct UpdateFeed: Codable, Sendable, Equatable {
    public let feedFormatVersion: Int
    public let generatedAt: Date
    public let entries: [UpdateFeedEntry]

    public init(feedFormatVersion: Int = 1, generatedAt: Date, entries: [UpdateFeedEntry]) {
        self.feedFormatVersion = feedFormatVersion
        self.generatedAt = generatedAt
        self.entries = entries
    }
}
