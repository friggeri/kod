import CryptoKit
import Foundation
@testable import ManagedLanguageServers

/// A fixed, deterministic, **non-secret** Ed25519 key pair used only to
/// sign fixture catalogs in `ManagedLanguageServersTests`. This is not
/// how `CatalogSigner`/`CatalogTrustRoot` are meant to be used in a real
/// release — see `Scripts/managed-install-signing/README.md` for that
/// process, which never generates or stores a real private key in this
/// repository. This key exists purely so install/verification logic has
/// full offline test coverage; it must never appear in
/// `CatalogTrustRoot.production`.
enum FixtureSigningKey {
    /// Not a secret: a fixed 32-byte seed, deterministic across test
    /// runs so fixture catalogs are reproducible byte-for-byte.
    private static let seed = Data((0..<32).map { UInt8($0 * 7 + 1) })

    static let privateKey = try! Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    static let keyID = "fixture-2026-08"

    static var trustedKey: TrustedSigningKey {
        TrustedSigningKey(
            id: keyID,
            publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            validFrom: Date(timeIntervalSince1970: 0)
        )
    }

    static func trustRoot(revokedArtifactDigestsHex: Set<String> = []) -> CatalogTrustRoot {
        CatalogTrustRoot(pinned: [trustedKey], revokedArtifactDigestsHex: revokedArtifactDigestsHex)
    }
}
