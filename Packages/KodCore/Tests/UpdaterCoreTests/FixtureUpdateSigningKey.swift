import CryptoKit
import Foundation
@testable import UpdaterCore

/// A fixed, deterministic, **non-secret** Ed25519 key pair used only to
/// sign fixture update feeds in `UpdaterCoreTests` — the update-feed
/// analog of `ManagedLanguageServersTests.FixtureSigningKey`. This is
/// not how `UpdateFeedSigner`/`UpdateFeedTrustRoot` are meant to be used
/// in a real release — see `Scripts/release/README.md` for that
/// process, which never generates or stores a real private key in this
/// repository. This key exists purely so update/rollback verification
/// logic has full offline test coverage; it must never appear in
/// `UpdateFeedTrustRoot.production`.
enum FixtureUpdateSigningKey {
    /// Not a secret: a fixed 32-byte seed, deterministic across test
    /// runs so fixture feeds are reproducible byte-for-byte. Uses a
    /// different byte pattern than `ManagedLanguageServersTests`'s
    /// fixture catalog key so the two fixture key pairs are never
    /// accidentally interchangeable.
    private static let seed = Data((0..<32).map { UInt8(($0 * 11 + 3) % 256) })

    static let privateKey: Curve25519.Signing.PrivateKey = {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
            preconditionFailure("Fixed 32-byte fixture seed must always produce a valid Ed25519 key")
        }
        return key
    }()

    static let keyID = "fixture-update-2026-08"

    static var trustedKey: TrustedUpdateSigningKey {
        TrustedUpdateSigningKey(
            id: keyID,
            publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            validFrom: Date(timeIntervalSince1970: 0)
        )
    }

    static func trustRoot(revokedVersions: Set<String> = []) -> UpdateFeedTrustRoot {
        UpdateFeedTrustRoot(pinned: [trustedKey], revokedVersions: revokedVersions)
    }
}
