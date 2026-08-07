import CryptoKit
import Foundation

/// Signs a `ManagedServerCatalog` with an Ed25519 private key. This is
/// **release/test tooling only** — nothing in the shipped Kod app links
/// against a code path that calls this with a real private key. It
/// exists so:
///
/// - `Scripts/managed-install-signing`'s offline release process (run
///   on a machine that holds the real private key, never in CI, never
///   in this repository) can call it via `ManagedCatalogTool`.
/// - `ManagedLanguageServersTests` can produce a signed *fixture*
///   catalog from a fixed, clearly-labeled, non-secret test key
///   (`FixtureSigningKey`), so install/verification logic has full
///   offline test coverage without ever touching a production key.
///
/// See `Scripts/managed-install-signing/README.md` for the full
/// key-rotation and release-signing process this type is one piece of.
public enum CatalogSigner {
    public static func sign(
        _ catalog: ManagedServerCatalog,
        privateKey: Curve25519.Signing.PrivateKey,
        signingKeyID: String
    ) throws -> SignedCatalogDocument {
        let canonicalBytes = try CatalogCanonicalization.encode(catalog)
        let signature = try privateKey.signature(for: canonicalBytes)
        return SignedCatalogDocument(canonicalBytes: canonicalBytes, signature: signature, signingKeyID: signingKeyID)
    }
}
