import CryptoKit
import XCTest
@testable import ManagedLanguageServers

final class CatalogVerifierTests: XCTestCase {
    private func makeCatalog(minimumKodVersion: SemanticVersion = SemanticVersion(major: 1, minor: 0, patch: 0)) -> ManagedServerCatalog {
        let artifact = ManagedServerArtifact(
            architecture: .arm64,
            url: URL(string: "https://example.invalid/a.tar.gz")!,
            sha256Hex: String(repeating: "a", count: 64),
            maxDownloadBytes: 1024,
            maxDecompressedBytes: 1024,
            archiveFormat: .tarGz,
            expectedRelativePaths: ["bin/tool"],
            executableRelativePath: "bin/tool"
        )
        let entry = ManagedServerCatalogEntry(
            serverID: "test-server",
            language: "test",
            version: SemanticVersion(major: 1, minor: 0, patch: 0),
            minimumKodVersion: minimumKodVersion,
            artifacts: [artifact]
        )
        return ManagedServerCatalog(generatedAt: Date(timeIntervalSince1970: 1_700_000_000), entries: [entry])
    }

    func testValidSignatureVerifies() throws {
        let catalog = makeCatalog()
        let signed = try CatalogSigner.sign(catalog, privateKey: FixtureSigningKey.privateKey, signingKeyID: FixtureSigningKey.keyID)
        let verified = try CatalogVerifier.verify(signed, trustRoot: FixtureSigningKey.trustRoot())
        XCTAssertEqual(verified.entries.count, 1)
    }

    func testTamperedCanonicalBytesRejected() throws {
        let catalog = makeCatalog()
        var signed = try CatalogSigner.sign(catalog, privateKey: FixtureSigningKey.privateKey, signingKeyID: FixtureSigningKey.keyID)
        var tamperedBytes = signed.canonicalBytes
        // Flip a byte inside the JSON text itself (not just padding).
        let flipIndex = tamperedBytes.index(tamperedBytes.startIndex, offsetBy: tamperedBytes.count / 2)
        tamperedBytes[flipIndex] ^= 0xFF
        signed = SignedCatalogDocument(canonicalBytes: tamperedBytes, signature: signed.signature, signingKeyID: signed.signingKeyID)

        XCTAssertThrowsError(try CatalogVerifier.verify(signed, trustRoot: FixtureSigningKey.trustRoot())) { error in
            // Either a decode failure (tampering corrupted the JSON) or an explicit
            // signature failure is acceptable — both mean "not usable," never a
            // silently-accepted tampered catalog.
            XCTAssertTrue(error is CatalogVerificationError, "expected CatalogVerificationError, got \(error)")
        }
    }

    func testTamperedSignatureRejected() throws {
        let catalog = makeCatalog()
        let signed = try CatalogSigner.sign(catalog, privateKey: FixtureSigningKey.privateKey, signingKeyID: FixtureSigningKey.keyID)
        var tamperedSignature = signed.signature
        tamperedSignature[0] ^= 0xFF
        let tampered = SignedCatalogDocument(canonicalBytes: signed.canonicalBytes, signature: tamperedSignature, signingKeyID: signed.signingKeyID)

        XCTAssertThrowsError(try CatalogVerifier.verify(tampered, trustRoot: FixtureSigningKey.trustRoot())) { error in
            guard case CatalogVerificationError.signatureInvalid = error else {
                XCTFail("expected signatureInvalid, got \(error)")
                return
            }
        }
    }

    func testUnknownSigningKeyIDRejected() throws {
        let catalog = makeCatalog()
        let signed = try CatalogSigner.sign(catalog, privateKey: FixtureSigningKey.privateKey, signingKeyID: "some-other-key-id")

        XCTAssertThrowsError(try CatalogVerifier.verify(signed, trustRoot: FixtureSigningKey.trustRoot())) { error in
            guard case CatalogVerificationError.unknownSigningKeyID(let keyID) = error else {
                XCTFail("expected unknownSigningKeyID, got \(error)")
                return
            }
            XCTAssertEqual(keyID, "some-other-key-id")
        }
    }

    func testForgedSignatureWithCorrectKeyIDRejected() throws {
        // An attacker who knows the real key ID string but not the real
        // private key cannot forge a signature that verifies against
        // the real pinned public key.
        let catalog = makeCatalog()
        let impostorKey = Curve25519.Signing.PrivateKey()
        var signed = try CatalogSigner.sign(catalog, privateKey: impostorKey, signingKeyID: FixtureSigningKey.keyID)
        signed = SignedCatalogDocument(canonicalBytes: signed.canonicalBytes, signature: signed.signature, signingKeyID: FixtureSigningKey.keyID)

        XCTAssertThrowsError(try CatalogVerifier.verify(signed, trustRoot: FixtureSigningKey.trustRoot())) { error in
            guard case CatalogVerificationError.signatureInvalid = error else {
                XCTFail("expected signatureInvalid, got \(error)")
                return
            }
        }
    }

    func testExpiredKeyWindowRejected() throws {
        let catalog = makeCatalog()
        let signed = try CatalogSigner.sign(catalog, privateKey: FixtureSigningKey.privateKey, signingKeyID: FixtureSigningKey.keyID)

        // Pin the same key, but with a validity window that ends before
        // the catalog's own `generatedAt` — simulating a rotated-out key
        // being used to backdate-sign a new catalog.
        let expiredKey = TrustedSigningKey(
            id: FixtureSigningKey.keyID,
            publicKeyBase64: FixtureSigningKey.trustedKey.publicKeyBase64,
            validFrom: Date(timeIntervalSince1970: 0),
            validUntil: Date(timeIntervalSince1970: 1_600_000_000)
        )
        let trustRoot = CatalogTrustRoot(pinned: [expiredKey])

        XCTAssertThrowsError(try CatalogVerifier.verify(signed, trustRoot: trustRoot)) { error in
            guard case CatalogVerificationError.unknownSigningKeyID = error else {
                XCTFail("expected unknownSigningKeyID (key not valid for this catalog's generatedAt), got \(error)")
                return
            }
        }
    }

    func testEmptyTrustRootRejectsEverything() throws {
        let catalog = makeCatalog()
        let signed = try CatalogSigner.sign(catalog, privateKey: FixtureSigningKey.privateKey, signingKeyID: FixtureSigningKey.keyID)

        XCTAssertThrowsError(try CatalogVerifier.verify(signed, trustRoot: CatalogTrustRoot.production)) { error in
            guard case CatalogVerificationError.noTrustedKeyConfigured = error else {
                XCTFail("expected noTrustedKeyConfigured, got \(error)")
                return
            }
        }
    }

    func testEntryBelowMinimumKodVersionFilteredOut() throws {
        let catalog = makeCatalog(minimumKodVersion: SemanticVersion(major: 99, minor: 0, patch: 0))
        let signed = try CatalogSigner.sign(catalog, privateKey: FixtureSigningKey.privateKey, signingKeyID: FixtureSigningKey.keyID)

        let verified = try CatalogVerifier.verify(signed, trustRoot: FixtureSigningKey.trustRoot(), runningKodVersion: SemanticVersion(major: 1, minor: 0, patch: 0))
        XCTAssertTrue(verified.entries.isEmpty)
    }

    func testDuplicateArtifactArchitectureRejected() throws {
        let duplicateArtifact1 = ManagedServerArtifact(
            architecture: .arm64, url: URL(string: "https://example.invalid/a.tar.gz")!, sha256Hex: String(repeating: "a", count: 64),
            maxDownloadBytes: 1024, maxDecompressedBytes: 1024, archiveFormat: .tarGz,
            expectedRelativePaths: ["bin/tool"], executableRelativePath: "bin/tool"
        )
        let duplicateArtifact2 = ManagedServerArtifact(
            architecture: .arm64, url: URL(string: "https://example.invalid/b.tar.gz")!, sha256Hex: String(repeating: "b", count: 64),
            maxDownloadBytes: 1024, maxDecompressedBytes: 1024, archiveFormat: .tarGz,
            expectedRelativePaths: ["bin/tool"], executableRelativePath: "bin/tool"
        )
        let entry = ManagedServerCatalogEntry(
            serverID: "test-server", language: "test", version: SemanticVersion(major: 1, minor: 0, patch: 0),
            minimumKodVersion: SemanticVersion(major: 1, minor: 0, patch: 0),
            artifacts: [duplicateArtifact1, duplicateArtifact2]
        )
        let catalog = ManagedServerCatalog(generatedAt: Date(timeIntervalSince1970: 1_700_000_000), entries: [entry])
        let signed = try CatalogSigner.sign(catalog, privateKey: FixtureSigningKey.privateKey, signingKeyID: FixtureSigningKey.keyID)

        XCTAssertThrowsError(try CatalogVerifier.verify(signed, trustRoot: FixtureSigningKey.trustRoot())) { error in
            guard case CatalogVerificationError.duplicateArtifactArchitecture = error else {
                XCTFail("expected duplicateArtifactArchitecture, got \(error)")
                return
            }
        }
    }
}
