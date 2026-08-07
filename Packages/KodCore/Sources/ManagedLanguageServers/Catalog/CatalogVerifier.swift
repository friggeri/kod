import CryptoKit
import Foundation

/// Verifies a `SignedCatalogDocument` against a `CatalogTrustRoot`
/// before ever handing back a usable `ManagedServerCatalog` (SPEC 6.5:
/// "Verify signature before reading entries"). This is the single
/// choke point every managed-install code path must go through — there
/// is no other way to obtain a `ManagedServerCatalog` from raw bytes in
/// this target.
public enum CatalogVerifier {
    /// The running Kod app's own version, used to filter out any entry
    /// whose `minimumKodVersion` this build doesn't meet. Defaults to
    /// Kod 1.0 (SPEC "Target: Kod 1.0"). Callers pass their own bundle
    /// version explicitly (rather than this being mutable global state,
    /// which Swift's strict concurrency checking rightly rejects for a
    /// `nonisolated static var`) if that ever diverges.
    public static let defaultRunningKodVersion = SemanticVersion(major: 1, minor: 0, patch: 0)

    /// Verifies `document`'s Ed25519 signature over its own
    /// `canonicalBytes` using whichever key in `trustRoot.pinned` both
    /// matches `document.signingKeyID` and is valid (per its
    /// `validFrom`/`validUntil` window) as of the decoded catalog's own
    /// `generatedAt` timestamp — not "now", so a catalog signed while a
    /// key was current keeps verifying after that key's later
    /// rotation/expiry, while a signature purporting to be from a
    /// not-yet-valid or already-expired key window is rejected even if
    /// the raw cryptographic check would otherwise pass.
    ///
    /// Only after the signature check passes is `canonicalBytes` ever
    /// handed to the JSON decoder. Entries below `runningKodVersion`'s
    /// `minimumKodVersion` gate, or with more than one artifact for the
    /// same architecture, are rejected as malformed rather than
    /// silently dropped.
    public static func verify(
        _ document: SignedCatalogDocument,
        trustRoot: CatalogTrustRoot,
        runningKodVersion: SemanticVersion = CatalogVerifier.defaultRunningKodVersion
    ) throws -> ManagedServerCatalog {
        guard !trustRoot.pinned.isEmpty else {
            throw CatalogVerificationError.noTrustedKeyConfigured
        }

        // The signed key ID is looked up first purely to select which
        // public key's raw bytes to hand to CryptoKit; the actual trust
        // decision is the signature check immediately below, using that
        // key's real public-key bytes — an attacker naming a bogus
        // `signingKeyID` gains nothing, since `key(id:generatedAt:)`
        // only ever returns a key already pinned in `trustRoot`.
        let preliminaryCatalog = try CatalogCanonicalization.decode(document.canonicalBytes)
        guard let trustedKey = trustRoot.key(id: document.signingKeyID, generatedAt: preliminaryCatalog.generatedAt) else {
            throw CatalogVerificationError.unknownSigningKeyID(document.signingKeyID)
        }

        let publicKey = try trustedKey.publicKey()
        guard publicKey.isValidSignature(document.signature, for: document.canonicalBytes) else {
            throw CatalogVerificationError.signatureInvalid
        }

        guard preliminaryCatalog.catalogFormatVersion == 1 else {
            throw CatalogVerificationError.catalogFormatVersionUnsupported(preliminaryCatalog.catalogFormatVersion)
        }

        for entry in preliminaryCatalog.entries {
            var seenArchitectures: Set<ManagedInstallArchitecture> = []
            for artifact in entry.artifacts {
                guard seenArchitectures.insert(artifact.architecture).inserted else {
                    throw CatalogVerificationError.duplicateArtifactArchitecture(serverID: entry.serverID, architecture: artifact.architecture)
                }
            }
        }

        let supportedEntries = preliminaryCatalog.entries.filter { $0.minimumKodVersion <= runningKodVersion }
        return ManagedServerCatalog(
            catalogFormatVersion: preliminaryCatalog.catalogFormatVersion,
            generatedAt: preliminaryCatalog.generatedAt,
            entries: supportedEntries
        )
    }
}
