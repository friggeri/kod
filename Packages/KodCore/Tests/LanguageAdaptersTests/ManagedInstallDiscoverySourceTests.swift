import CryptoKit
import Foundation
import ManagedLanguageServers
import XCTest
@testable import LanguageAdapters

/// End-to-end coverage of `ManagedInstallDiscoverySource`: installing a
/// tiny fixture "server" through the real `ManagedInstallController`
/// pipeline, then confirming discovery finds exactly that installed
/// executable — the same bridge every managed-install-capable adapter
/// (TypeScript/JavaScript, HTML, CSS, Python, Rust) wires into
/// `LanguageServerDiscoveryEngine.resolve`'s final tier.
final class ManagedInstallDiscoverySourceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ManagedInstallDiscoverySourceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static let fixtureSeed = Data((0..<32).map { UInt8($0 * 3 + 5) })
    private static let fixturePrivateKey = try! Curve25519.Signing.PrivateKey(rawRepresentation: fixtureSeed)
    private static let fixtureKeyID = "discovery-fixture-key"

    private func trustRoot() -> CatalogTrustRoot {
        CatalogTrustRoot(pinned: [
            TrustedSigningKey(
                id: Self.fixtureKeyID,
                publicKeyBase64: Self.fixturePrivateKey.publicKey.rawRepresentation.base64EncodedString(),
                validFrom: Date(timeIntervalSince1970: 0)
            )
        ])
    }

    func testDiscoversAnActiveManagedInstall() async throws {
        let paths = ManagedInstallPaths(root: root)
        let controller = try ManagedInstallController(paths: paths)

        // A minimal, real, executable script (not a stub file) so
        // `FileManager.isExecutableFile` and (if ever launched) actual
        // execution both genuinely succeed.
        let scriptBody = Data("#!/bin/sh\necho ready\n".utf8)
        let archive = try GzipCodec.compress(TarWriter.write([
            .init(name: "bin/tool", type: .regularFile, mode: 0o755, body: scriptBody)
        ]))
        let server = try LocalHTTPTestServer(responses: ["/artifact.tar.gz": archive])
        server.start()
        defer { server.stop() }

        let artifact = ManagedServerArtifact(
            architecture: .current,
            url: server.url(forPath: "/artifact.tar.gz"),
            sha256Hex: Digest.sha256Hex(of: archive),
            maxDownloadBytes: archive.count + 4096,
            maxDecompressedBytes: 4096,
            archiveFormat: .tarGz,
            expectedRelativePaths: ["bin/tool"],
            executableRelativePath: "bin/tool"
        )
        let version = SemanticVersion(major: 2, minor: 0, patch: 0)
        let entry = ManagedServerCatalogEntry(
            serverID: "discovery-test-server",
            language: "test",
            version: version,
            minimumKodVersion: SemanticVersion(major: 1, minor: 0, patch: 0),
            artifacts: [artifact],
            adapterArguments: ["--stdio"]
        )
        let catalog = ManagedServerCatalog(generatedAt: Date(), entries: [entry])
        let signed = try CatalogSigner.sign(catalog, privateKey: Self.fixturePrivateKey, signingKeyID: Self.fixtureKeyID)
        let verified = try CatalogVerifier.verify(signed, trustRoot: trustRoot())
        let verifiedEntry = try XCTUnwrap(verified.entry(serverID: "discovery-test-server"))

        // Before installing: discovery must cleanly report "nothing here."
        XCTAssertNil(ManagedInstallDiscoverySource.discover(serverID: "discovery-test-server", controller: controller, paths: paths))

        try await controller.grantConsent(serverID: verifiedEntry.serverID, version: verifiedEntry.version, architecture: .current)
        _ = try await controller.install(entry: verifiedEntry, architecture: .current, trustRoot: trustRoot())

        let discovered = try XCTUnwrap(ManagedInstallDiscoverySource.discover(serverID: "discovery-test-server", controller: controller, paths: paths))
        XCTAssertEqual(discovered.source, .managedInstall)
        XCTAssertEqual(discovered.arguments, ["--stdio"])
        XCTAssertTrue(discovered.version?.contains("2.0.0") ?? false)
        XCTAssertEqual(discovered.url, paths.versionDirectory(serverID: "discovery-test-server", version: version).appendingPathComponent("bin/tool"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: discovered.url.path))
    }

    func testNilControllerReportsNilCleanly() {
        XCTAssertNil(ManagedInstallDiscoverySource.discover(serverID: "anything", controller: nil))
    }
}
