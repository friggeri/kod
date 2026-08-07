import CryptoKit
import Foundation

/// Signs an `UpdateFeed` with an Ed25519 private key. This is
/// **release/test tooling only** — nothing in the shipped Kod app links
/// against a code path that calls this with a real private key. It
/// exists so:
///
/// - `Scripts/release`'s offline update-feed publishing process (run on
///   a machine that holds the real private key, never in CI, never in
///   this repository) can call it via `UpdateFeedTool`.
/// - `UpdaterCoreTests` can produce a signed *fixture* feed from a
///   fixed, clearly-labeled, non-secret test key
///   (`FixtureUpdateSigningKey`), so update/rollback verification logic
///   has full offline test coverage without ever touching a production
///   key.
///
/// See `Scripts/release/README.md` for the full key-handling process
/// this type is one piece of — the same pattern
/// `Scripts/managed-install-signing` already documents for the managed
/// language-server catalog.
public enum UpdateFeedSigner {
    public static func sign(
        _ feed: UpdateFeed,
        privateKey: Curve25519.Signing.PrivateKey,
        signingKeyID: String
    ) throws -> SignedUpdateFeedDocument {
        let canonicalBytes = try UpdateFeedCanonicalization.encode(feed)
        let signature = try privateKey.signature(for: canonicalBytes)
        return SignedUpdateFeedDocument(canonicalBytes: canonicalBytes, signature: signature, signingKeyID: signingKeyID)
    }
}
