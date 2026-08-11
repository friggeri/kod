import CryptoKit
import Foundation
import XCTest
@testable import UpdaterCore

/// Offline coverage for Kod's signed update-feed mechanism: sign/verify
/// round trips, available-update and rollback-candidate selection, and
/// hostile-input rejection (tampered bytes, unknown key, wrong key,
/// expired/not-yet-valid key window, unsupported format version, empty
/// trust root, revoked version, digest-mismatched downloaded artifact).
/// Everything here runs fully offline against `FixtureUpdateSigningKey`
/// — the production signing key never exists in this repository or
/// environment (SPEC 13.2).
final class UpdaterCoreTests: XCTestCase {
    private func makeEntry(
        version: SemanticVersion,
        architecture: ReleaseArchitecture? = nil,
        minimumSystemVersion: SemanticVersion = SemanticVersion(major: 14, minor: 0, patch: 0),
        isRollbackTarget: Bool = false,
        isCriticalSecurityUpdate: Bool = false
    ) -> UpdateFeedEntry {
        UpdateFeedEntry(
            version: version,
            minimumSystemVersion: minimumSystemVersion,
            architecture: architecture,
            downloadURL: URL(string: "https://example.invalid/Kod-\(version).zip")!,
            sha256Hex: String(repeating: "a", count: 64),
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            releaseNotesURL: nil,
            isCriticalSecurityUpdate: isCriticalSecurityUpdate,
            isRollbackTarget: isRollbackTarget
        )
    }

    private func sign(_ feed: UpdateFeed) throws -> SignedUpdateFeedDocument {
        try UpdateFeedSigner.sign(feed, privateKey: FixtureUpdateSigningKey.privateKey, signingKeyID: FixtureUpdateSigningKey.keyID)
    }

    // MARK: - Updater-owned value types

    func testSemanticVersionPreservesParsingDescriptionComparisonAndCoding() throws {
        let version = try XCTUnwrap(SemanticVersion(parsing: "12.34.56"))

        XCTAssertEqual(version.description, "12.34.56")
        XCTAssertLessThan(version, SemanticVersion(major: 12, minor: 35, patch: 0))
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(version), as: UTF8.self), #""12.34.56""#)
        XCTAssertEqual(try JSONDecoder().decode(SemanticVersion.self, from: Data(#""12.34.56""#.utf8)), version)
        XCTAssertNil(SemanticVersion(parsing: "12.34"))
    }

    func testReleaseArchitecturePreservesSerializedRawValues() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        XCTAssertEqual(String(decoding: try encoder.encode(ReleaseArchitecture.arm64), as: UTF8.self), #""arm64""#)
        XCTAssertEqual(String(decoding: try encoder.encode(ReleaseArchitecture.x86_64), as: UTF8.self), #""x86_64""#)
        XCTAssertEqual(try decoder.decode(ReleaseArchitecture.self, from: Data(#""arm64""#.utf8)), .arm64)
        XCTAssertEqual(try decoder.decode(ReleaseArchitecture.self, from: Data(#""x86_64""#.utf8)), .x86_64)
    }

    // MARK: - Round trip

    func testSignedFeedVerifiesAndRoundTripsThroughEnvelope() throws {
        let feed = UpdateFeed(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            entries: [makeEntry(version: SemanticVersion(major: 1, minor: 0, patch: 0))]
        )
        let signed = try sign(feed)
        let envelopeData = try signed.encodedEnvelope()
        let decoded = try SignedUpdateFeedDocument.decodeEnvelope(envelopeData)

        let verified = try UpdateFeedVerifier.verify(decoded, trustRoot: FixtureUpdateSigningKey.trustRoot())
        XCTAssertEqual(verified.entries.count, 1)
        XCTAssertEqual(verified.entries.first?.version, SemanticVersion(major: 1, minor: 0, patch: 0))
    }

    // MARK: - Hostile-input rejection

    func testTamperedCanonicalBytesFailSignatureVerification() throws {
        let feed = UpdateFeed(generatedAt: Date(), entries: [makeEntry(version: SemanticVersion(major: 1, minor: 0, patch: 0))])
        let signed = try sign(feed)

        // Flip one ASCII digit within the signed JSON payload (e.g. a
        // digit in the ISO-8601 `generatedAt` string) rather than an
        // arbitrary byte: an arbitrary flip can produce invalid UTF-8 or
        // break JSON syntax outright, which would be rejected at the
        // decode stage (`.malformedFeedDocument`) before ever reaching
        // the signature check this test means to exercise. A single
        // still-valid-JSON digit substitution isolates exactly the
        // "content changed, signature must now fail" case.
        var tamperedBytes = signed.canonicalBytes
        guard let digitIndex = tamperedBytes.firstIndex(where: { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else {
            return XCTFail("expected at least one ASCII digit in the canonical JSON payload")
        }
        let originalDigit = tamperedBytes[digitIndex]
        let replacementDigit = originalDigit == UInt8(ascii: "0") ? UInt8(ascii: "1") : UInt8(ascii: "0")
        tamperedBytes[digitIndex] = replacementDigit

        let tampered = SignedUpdateFeedDocument(
            canonicalBytes: tamperedBytes,
            signature: signed.signature,
            signingKeyID: signed.signingKeyID
        )

        XCTAssertThrowsError(try UpdateFeedVerifier.verify(tampered, trustRoot: FixtureUpdateSigningKey.trustRoot())) { error in
            XCTAssertEqual(error as? UpdateFeedVerificationError, .signatureInvalid)
        }
    }

    func testTamperedSignatureFailsVerification() throws {
        let feed = UpdateFeed(generatedAt: Date(), entries: [makeEntry(version: SemanticVersion(major: 1, minor: 0, patch: 0))])
        let signed = try sign(feed)

        var tamperedSignature = signed.signature
        tamperedSignature[tamperedSignature.startIndex] ^= 0xFF
        let tampered = SignedUpdateFeedDocument(
            canonicalBytes: signed.canonicalBytes,
            signature: tamperedSignature,
            signingKeyID: signed.signingKeyID
        )

        XCTAssertThrowsError(try UpdateFeedVerifier.verify(tampered, trustRoot: FixtureUpdateSigningKey.trustRoot())) { error in
            XCTAssertEqual(error as? UpdateFeedVerificationError, .signatureInvalid)
        }
    }

    func testUnknownSigningKeyIDIsRejected() throws {
        let feed = UpdateFeed(generatedAt: Date(), entries: [])
        let signed = try sign(feed)
        let relabeled = SignedUpdateFeedDocument(
            canonicalBytes: signed.canonicalBytes,
            signature: signed.signature,
            signingKeyID: "not-a-pinned-key"
        )

        XCTAssertThrowsError(try UpdateFeedVerifier.verify(relabeled, trustRoot: FixtureUpdateSigningKey.trustRoot())) { error in
            XCTAssertEqual(error as? UpdateFeedVerificationError, .unknownSigningKeyID("not-a-pinned-key"))
        }
    }

    func testDifferentKeyPairSignatureIsRejectedByFixtureTrustRoot() throws {
        let attackerKey = Curve25519.Signing.PrivateKey()
        let feed = UpdateFeed(generatedAt: Date(), entries: [])
        let signedByAttacker = try UpdateFeedSigner.sign(feed, privateKey: attackerKey, signingKeyID: FixtureUpdateSigningKey.keyID)

        XCTAssertThrowsError(try UpdateFeedVerifier.verify(signedByAttacker, trustRoot: FixtureUpdateSigningKey.trustRoot())) { error in
            XCTAssertEqual(error as? UpdateFeedVerificationError, .signatureInvalid)
        }
    }

    func testEmptyTrustRootRejectsEveryFeed() throws {
        let feed = UpdateFeed(generatedAt: Date(), entries: [])
        let signed = try sign(feed)

        XCTAssertThrowsError(try UpdateFeedVerifier.verify(signed, trustRoot: .production)) { error in
            XCTAssertEqual(error as? UpdateFeedVerificationError, .noTrustedKeyConfigured)
        }
    }

    func testKeyOutsideValidityWindowIsRejected() throws {
        let feed = UpdateFeed(generatedAt: Date(timeIntervalSince1970: 2_000_000_000), entries: [])
        let signed = try sign(feed)

        let expiredTrustRoot = UpdateFeedTrustRoot(pinned: [
            TrustedUpdateSigningKey(
                id: FixtureUpdateSigningKey.keyID,
                publicKeyBase64: FixtureUpdateSigningKey.trustedKey.publicKeyBase64,
                validFrom: Date(timeIntervalSince1970: 0),
                validUntil: Date(timeIntervalSince1970: 1_000_000_000)
            )
        ])

        XCTAssertThrowsError(try UpdateFeedVerifier.verify(signed, trustRoot: expiredTrustRoot)) { error in
            XCTAssertEqual(error as? UpdateFeedVerificationError, .unknownSigningKeyID(FixtureUpdateSigningKey.keyID))
        }
    }

    func testUnsupportedFeedFormatVersionIsRejected() throws {
        let feed = UpdateFeed(feedFormatVersion: 2, generatedAt: Date(), entries: [])
        let signed = try sign(feed)

        XCTAssertThrowsError(try UpdateFeedVerifier.verify(signed, trustRoot: FixtureUpdateSigningKey.trustRoot())) { error in
            XCTAssertEqual(error as? UpdateFeedVerificationError, .feedFormatVersionUnsupported(2))
        }
    }

    func testMalformedEnvelopeBase64IsRejected() {
        let envelope = SignedUpdateFeedDocument.Envelope(
            canonicalBytesBase64: "not-valid-base64!!",
            signatureBase64: "also-not-valid!!",
            signingKeyID: FixtureUpdateSigningKey.keyID
        )
        XCTAssertThrowsError(try SignedUpdateFeedDocument(envelope: envelope)) { error in
            XCTAssertEqual(error as? UpdateFeedVerificationError, .malformedFeedDocument)
        }
    }

    // MARK: - Revocation

    func testRevokedVersionIsFilteredOutAfterVerification() throws {
        let feed = UpdateFeed(
            generatedAt: Date(),
            entries: [
                makeEntry(version: SemanticVersion(major: 1, minor: 0, patch: 0)),
                makeEntry(version: SemanticVersion(major: 1, minor: 1, patch: 0))
            ]
        )
        let signed = try sign(feed)
        let verified = try UpdateFeedVerifier.verify(
            signed,
            trustRoot: FixtureUpdateSigningKey.trustRoot(revokedVersions: ["1.1.0"])
        )
        XCTAssertEqual(verified.entries.map(\.version.description), ["1.0.0"])
    }

    // MARK: - Available-update selection

    func testAvailableUpdateSelectsNewestCompatibleNewerEntry() {
        let feed = UpdateFeed(generatedAt: Date(), entries: [
            makeEntry(version: SemanticVersion(major: 1, minor: 0, patch: 0)),
            makeEntry(version: SemanticVersion(major: 1, minor: 2, patch: 0)),
            makeEntry(version: SemanticVersion(major: 1, minor: 1, patch: 0))
        ])
        let update = UpdateFeedVerifier.availableUpdate(
            in: feed,
            currentVersion: SemanticVersion(major: 1, minor: 0, patch: 0),
            currentSystemVersion: SemanticVersion(major: 14, minor: 0, patch: 0),
            runningArchitecture: .arm64
        )
        XCTAssertEqual(update?.version, SemanticVersion(major: 1, minor: 2, patch: 0))
    }

    func testAvailableUpdateReturnsNilWhenAlreadyCurrent() {
        let feed = UpdateFeed(generatedAt: Date(), entries: [
            makeEntry(version: SemanticVersion(major: 1, minor: 0, patch: 0))
        ])
        let update = UpdateFeedVerifier.availableUpdate(
            in: feed,
            currentVersion: SemanticVersion(major: 1, minor: 0, patch: 0),
            currentSystemVersion: SemanticVersion(major: 14, minor: 0, patch: 0),
            runningArchitecture: .arm64
        )
        XCTAssertNil(update)
    }

    func testAvailableUpdateExcludesEntryBelowMinimumSystemVersion() {
        let feed = UpdateFeed(generatedAt: Date(), entries: [
            makeEntry(version: SemanticVersion(major: 2, minor: 0, patch: 0), minimumSystemVersion: SemanticVersion(major: 15, minor: 0, patch: 0))
        ])
        let update = UpdateFeedVerifier.availableUpdate(
            in: feed,
            currentVersion: SemanticVersion(major: 1, minor: 0, patch: 0),
            currentSystemVersion: SemanticVersion(major: 14, minor: 0, patch: 0),
            runningArchitecture: .arm64
        )
        XCTAssertNil(update)
    }

    func testAvailableUpdateExcludesIncompatibleArchitecture() {
        let feed = UpdateFeed(generatedAt: Date(), entries: [
            makeEntry(version: SemanticVersion(major: 2, minor: 0, patch: 0), architecture: .x86_64)
        ])
        let update = UpdateFeedVerifier.availableUpdate(
            in: feed,
            currentVersion: SemanticVersion(major: 1, minor: 0, patch: 0),
            currentSystemVersion: SemanticVersion(major: 14, minor: 0, patch: 0),
            runningArchitecture: .arm64
        )
        XCTAssertNil(update)
    }

    func testAvailableUpdateAcceptsUniversalArtifactOnEitherArchitecture() {
        let feed = UpdateFeed(generatedAt: Date(), entries: [
            makeEntry(version: SemanticVersion(major: 2, minor: 0, patch: 0), architecture: nil)
        ])
        for architecture in ReleaseArchitecture.allCases {
            let update = UpdateFeedVerifier.availableUpdate(
                in: feed,
                currentVersion: SemanticVersion(major: 1, minor: 0, patch: 0),
                currentSystemVersion: SemanticVersion(major: 14, minor: 0, patch: 0),
                runningArchitecture: architecture
            )
            XCTAssertNotNil(update, "universal artifact must be offered on \(architecture)")
        }
    }

    // MARK: - Rollback

    func testRollbackCandidateOnlyReturnsExplicitlyMarkedEntries() {
        let feed = UpdateFeed(generatedAt: Date(), entries: [
            makeEntry(version: SemanticVersion(major: 1, minor: 0, patch: 0), isRollbackTarget: false),
            makeEntry(version: SemanticVersion(major: 0, minor: 9, patch: 0), isRollbackTarget: true)
        ])
        let rollback = UpdateFeedVerifier.rollbackCandidate(
            in: feed,
            currentVersion: SemanticVersion(major: 1, minor: 1, patch: 0),
            currentSystemVersion: SemanticVersion(major: 14, minor: 0, patch: 0),
            runningArchitecture: .arm64
        )
        XCTAssertEqual(rollback?.version, SemanticVersion(major: 0, minor: 9, patch: 0))
    }

    func testRollbackCandidateIsNilWhenNoEntryIsMarkedAsRollbackTarget() {
        let feed = UpdateFeed(generatedAt: Date(), entries: [
            makeEntry(version: SemanticVersion(major: 1, minor: 0, patch: 0), isRollbackTarget: false),
            makeEntry(version: SemanticVersion(major: 0, minor: 9, patch: 0), isRollbackTarget: false)
        ])
        let rollback = UpdateFeedVerifier.rollbackCandidate(
            in: feed,
            currentVersion: SemanticVersion(major: 1, minor: 1, patch: 0),
            currentSystemVersion: SemanticVersion(major: 14, minor: 0, patch: 0),
            runningArchitecture: .arm64
        )
        XCTAssertNil(rollback)
    }

    func testRollbackCandidateNeverReturnsAVersionNewerThanCurrent() {
        let feed = UpdateFeed(generatedAt: Date(), entries: [
            makeEntry(version: SemanticVersion(major: 2, minor: 0, patch: 0), isRollbackTarget: true)
        ])
        let rollback = UpdateFeedVerifier.rollbackCandidate(
            in: feed,
            currentVersion: SemanticVersion(major: 1, minor: 0, patch: 0),
            currentSystemVersion: SemanticVersion(major: 14, minor: 0, patch: 0),
            runningArchitecture: .arm64
        )
        XCTAssertNil(rollback, "rollback must never select a version newer than the currently-installed one")
    }

    func testRollbackCandidateSelectsNewestMarkedVersionBelowCurrent() {
        let feed = UpdateFeed(generatedAt: Date(), entries: [
            makeEntry(version: SemanticVersion(major: 0, minor: 8, patch: 0), isRollbackTarget: true),
            makeEntry(version: SemanticVersion(major: 0, minor: 9, patch: 0), isRollbackTarget: true)
        ])
        let rollback = UpdateFeedVerifier.rollbackCandidate(
            in: feed,
            currentVersion: SemanticVersion(major: 1, minor: 0, patch: 0),
            currentSystemVersion: SemanticVersion(major: 14, minor: 0, patch: 0),
            runningArchitecture: .arm64
        )
        XCTAssertEqual(rollback?.version, SemanticVersion(major: 0, minor: 9, patch: 0))
    }

    // MARK: - Downloaded-artifact digest verification

    func testVerifyDownloadedArtifactAcceptsMatchingDigest() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fileURL = temporaryDirectory.appendingPathComponent("update.zip")
        let payload = Data("fixture update archive bytes".utf8)
        try payload.write(to: fileURL)

        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let entry = makeEntry(version: SemanticVersion(major: 1, minor: 0, patch: 0))
        let entryWithMatchingDigest = UpdateFeedEntry(
            version: entry.version,
            minimumSystemVersion: entry.minimumSystemVersion,
            architecture: entry.architecture,
            downloadURL: entry.downloadURL,
            sha256Hex: digest,
            publishedAt: entry.publishedAt,
            releaseNotesURL: entry.releaseNotesURL,
            isCriticalSecurityUpdate: entry.isCriticalSecurityUpdate,
            isRollbackTarget: entry.isRollbackTarget
        )

        XCTAssertNoThrow(try UpdateFeedVerifier.verifyDownloadedArtifact(at: fileURL, matches: entryWithMatchingDigest))
    }

    func testVerifyDownloadedArtifactRejectsDigestMismatch() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fileURL = temporaryDirectory.appendingPathComponent("update.zip")
        try Data("fixture update archive bytes".utf8).write(to: fileURL)

        let entry = makeEntry(version: SemanticVersion(major: 1, minor: 0, patch: 0))
        XCTAssertThrowsError(try UpdateFeedVerifier.verifyDownloadedArtifact(at: fileURL, matches: entry)) { error in
            guard case .downloadedArtifactDigestMismatch = error as? UpdateFeedVerificationError else {
                return XCTFail("expected a digest-mismatch error, got \(error)")
            }
        }
    }
}
