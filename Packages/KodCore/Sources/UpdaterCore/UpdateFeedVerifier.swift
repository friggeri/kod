import CryptoKit
import Foundation
import ManagedLanguageServers

/// Verifies a `SignedUpdateFeedDocument` against an
/// `UpdateFeedTrustRoot` before ever handing back a usable `UpdateFeed`
/// (mirroring `ManagedLanguageServers.CatalogVerifier`'s "verify
/// signature before reading entries" contract). This is the single
/// choke point every update-check code path must go through.
public enum UpdateFeedVerifier {
    public static func verify(
        _ document: SignedUpdateFeedDocument,
        trustRoot: UpdateFeedTrustRoot
    ) throws -> UpdateFeed {
        guard !trustRoot.pinned.isEmpty else {
            throw UpdateFeedVerificationError.noTrustedKeyConfigured
        }

        // As with `CatalogVerifier`, the signed key ID is looked up only
        // to select which pinned public key's raw bytes to hand to
        // CryptoKit — the actual trust decision is the signature check
        // immediately below, using that key's real public-key bytes.
        let preliminaryFeed = try UpdateFeedCanonicalization.decode(document.canonicalBytes)
        guard let trustedKey = trustRoot.key(id: document.signingKeyID, generatedAt: preliminaryFeed.generatedAt) else {
            throw UpdateFeedVerificationError.unknownSigningKeyID(document.signingKeyID)
        }

        let publicKey = try trustedKey.publicKey()
        guard publicKey.isValidSignature(document.signature, for: document.canonicalBytes) else {
            throw UpdateFeedVerificationError.signatureInvalid
        }

        guard preliminaryFeed.feedFormatVersion == 1 else {
            throw UpdateFeedVerificationError.feedFormatVersionUnsupported(preliminaryFeed.feedFormatVersion)
        }

        let survivingEntries = preliminaryFeed.entries.filter { !trustRoot.revokedVersions.contains($0.version.description) }
        return UpdateFeed(
            feedFormatVersion: preliminaryFeed.feedFormatVersion,
            generatedAt: preliminaryFeed.generatedAt,
            entries: survivingEntries
        )
    }

    /// The newest compatible entry strictly newer than
    /// `currentVersion`, or `nil` if Kod is already current. Never
    /// returns an entry below `minimumSystemVersion` for
    /// `currentSystemVersion`, and never returns an architecture
    /// mismatch (see `UpdateFeedEntry.isCompatible`).
    public static func availableUpdate(
        in feed: UpdateFeed,
        currentVersion: SemanticVersion,
        currentSystemVersion: SemanticVersion,
        runningArchitecture: ManagedInstallArchitecture
    ) -> UpdateFeedEntry? {
        feed.entries
            .filter { $0.version > currentVersion }
            .filter { $0.minimumSystemVersion <= currentSystemVersion }
            .filter { $0.isCompatible(withRunningArchitecture: runningArchitecture) }
            .max { $0.version < $1.version }
    }

    /// The newest entry strictly older than `currentVersion` that the
    /// release process explicitly marked `isRollbackTarget`, compatible
    /// with the running architecture and system version — used only
    /// when the currently-installed update is found broken after
    /// launch and the user (or an automated post-update health check)
    /// asks to revert. An entry that is not marked as a rollback target
    /// is never returned here even if it is otherwise a perfectly
    /// valid, signature-verified older release — rollback is always an
    /// explicit release-curated allowlist, never "any older signed
    /// version," so a version pulled for a since-discovered
    /// vulnerability can be permanently excluded from rollback by
    /// simply never marking it (or a later feed update removing the
    /// flag from) `isRollbackTarget`.
    public static func rollbackCandidate(
        in feed: UpdateFeed,
        currentVersion: SemanticVersion,
        currentSystemVersion: SemanticVersion,
        runningArchitecture: ManagedInstallArchitecture
    ) -> UpdateFeedEntry? {
        feed.entries
            .filter { $0.isRollbackTarget }
            .filter { $0.version < currentVersion }
            .filter { $0.minimumSystemVersion <= currentSystemVersion }
            .filter { $0.isCompatible(withRunningArchitecture: runningArchitecture) }
            .max { $0.version < $1.version }
    }

    /// Verifies a downloaded update archive's SHA-256 against the
    /// entry's `sha256Hex` before it is ever extracted or executed —
    /// the update-feed analog of `ManagedLanguageServers.Digest`'s
    /// pre-extraction digest check. A mismatch throws rather than
    /// silently proceeding.
    public static func verifyDownloadedArtifact(at fileURL: URL, matches entry: UpdateFeedEntry) throws {
        let data = try Data(contentsOf: fileURL)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == entry.sha256Hex else {
            throw UpdateFeedVerificationError.downloadedArtifactDigestMismatch(
                expectedSha256Hex: entry.sha256Hex,
                actualSha256Hex: actual
            )
        }
    }
}
