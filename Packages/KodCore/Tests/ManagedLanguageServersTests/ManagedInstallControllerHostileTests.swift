import Security
import XCTest
@testable import ManagedLanguageServers

/// Controller-level hostile-path coverage: every explicit refusal
/// `ManagedInstallController.install` must make before touching the
/// network or disk, plus cancellation cleanup, concurrent-install
/// locking, and full workspace immutability.
final class ManagedInstallControllerHostileTests: XCTestCase {
    private var root: URL!
    private var workspaceRoot: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ManagedInstallControllerHostileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        workspaceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("FakeWorkspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        try Data("original source".utf8).write(to: workspaceRoot.appendingPathComponent("main.swift"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: workspaceRoot)
    }

    private func makeController() throws -> ManagedInstallController {
        try ManagedInstallController(paths: ManagedInstallPaths(root: root))
    }

    private func makeEntryAndServer(
        architecture: ManagedInstallArchitecture = .current,
        revoked: Bool = false,
        privateRuntime: ManagedPrivateRuntimeRequirement? = nil,
        digestOverride: String? = nil
    ) throws -> (entry: ManagedServerCatalogEntry, server: LocalHTTPTestServer, archiveBytes: Data) {
        let archive = try GzipCodec.compress(TarWriter.write([
            .init(name: "bin/tool", type: .regularFile, mode: 0o755, body: Data("fake-binary".utf8))
        ]))
        let server = try LocalHTTPTestServer(responses: ["/artifact.tar.gz": archive])
        server.start()

        let artifact = ManagedServerArtifact(
            architecture: architecture,
            url: server.url(forPath: "/artifact.tar.gz"),
            sha256Hex: digestOverride ?? Digest.sha256Hex(of: archive),
            maxDownloadBytes: archive.count + 4096,
            maxDecompressedBytes: 4096,
            archiveFormat: .tarGz,
            expectedRelativePaths: ["bin/tool"],
            executableRelativePath: "bin/tool"
        )
        let entry = ManagedServerCatalogEntry(
            serverID: "hostile-test-server",
            language: "test",
            version: SemanticVersion(major: 1, minor: 0, patch: 0),
            minimumKodVersion: SemanticVersion(major: 1, minor: 0, patch: 0),
            revoked: revoked,
            revocationReason: revoked ? "test revocation" : nil,
            artifacts: [artifact],
            privateRuntime: privateRuntime
        )
        return (entry, server, archive)
    }

    func testRevokedEntryRejected() async throws {
        let controller = try makeController()
        let (entry, server, _) = try makeEntryAndServer(revoked: true)
        defer { server.stop() }

        try await controller.grantConsent(serverID: entry.serverID, version: entry.version, architecture: .current)
        do {
            _ = try await controller.install(entry: entry, architecture: .current, trustRoot: FixtureSigningKey.trustRoot())
            XCTFail("expected revokedEntry")
        } catch let error as ManagedInstallError {
            guard case .revokedEntry = error else {
                XCTFail("expected revokedEntry, got \(error)")
                return
            }
        }
    }

    func testUnsupportedArchitectureRejected() async throws {
        let controller = try makeController()
        let otherArchitecture: ManagedInstallArchitecture = ManagedInstallArchitecture.current == .arm64 ? .x86_64 : .arm64
        let (entry, server, _) = try makeEntryAndServer(architecture: otherArchitecture)
        defer { server.stop() }

        try await controller.grantConsent(serverID: entry.serverID, version: entry.version, architecture: .current)
        do {
            _ = try await controller.install(entry: entry, architecture: .current, trustRoot: FixtureSigningKey.trustRoot())
            XCTFail("expected unsupportedArchitecture")
        } catch let error as ManagedInstallError {
            guard case .unsupportedArchitecture = error else {
                XCTFail("expected unsupportedArchitecture, got \(error)")
                return
            }
        }
    }

    func testDigestMismatchRejected() async throws {
        let controller = try makeController()
        let (entry, server, _) = try makeEntryAndServer(digestOverride: String(repeating: "0", count: 64))
        defer { server.stop() }

        try await controller.grantConsent(serverID: entry.serverID, version: entry.version, architecture: .current)
        do {
            _ = try await controller.install(entry: entry, architecture: .current, trustRoot: FixtureSigningKey.trustRoot())
            XCTFail("expected digestMismatch")
        } catch let error as ManagedInstallError {
            guard case .digestMismatch = error else {
                XCTFail("expected digestMismatch, got \(error)")
                return
            }
        }
        // A failed install must never leave a partially-activated version behind.
        let installed = try await controller.installedRecord(serverID: entry.serverID)
        XCTAssertNil(installed)
    }

    func testRevokedArtifactDigestRejected() async throws {
        let controller = try makeController()
        let (entry, server, archive) = try makeEntryAndServer()
        defer { server.stop() }

        try await controller.grantConsent(serverID: entry.serverID, version: entry.version, architecture: .current)
        let trustRoot = CatalogTrustRoot(pinned: [FixtureSigningKey.trustedKey], revokedArtifactDigestsHex: [Digest.sha256Hex(of: archive)])
        do {
            _ = try await controller.install(entry: entry, architecture: .current, trustRoot: trustRoot)
            XCTFail("expected artifactDigestRevoked")
        } catch let error as ManagedInstallError {
            guard case .artifactDigestRevoked = error else {
                XCTFail("expected artifactDigestRevoked, got \(error)")
                return
            }
        }
    }

    func testMissingPrivateRuntimeRejected() async throws {
        let controller = try makeController()
        let (entry, server, _) = try makeEntryAndServer(privateRuntime: ManagedPrivateRuntimeRequirement(runtimeServerID: "node-runtime", runtimeExecutableRelativePath: "bin/node"))
        defer { server.stop() }

        try await controller.grantConsent(serverID: entry.serverID, version: entry.version, architecture: .current)
        do {
            _ = try await controller.install(entry: entry, architecture: .current, trustRoot: FixtureSigningKey.trustRoot())
            XCTFail("expected missingPrivateRuntime")
        } catch let error as ManagedInstallError {
            guard case .missingPrivateRuntime(let runtimeServerID) = error else {
                XCTFail("expected missingPrivateRuntime, got \(error)")
                return
            }
            XCTAssertEqual(runtimeServerID, "node-runtime")
        }
    }

    func testInsecureNonLoopbackHTTPRejected() async throws {
        let controller = try makeController()
        let archive = try GzipCodec.compress(TarWriter.write([.init(name: "bin/tool", mode: 0o755, body: Data("x".utf8))]))
        let artifact = ManagedServerArtifact(
            architecture: .current,
            url: URL(string: "http://93.184.216.34/artifact.tar.gz")!, // a real routable (non-loopback) address, never contacted
            sha256Hex: Digest.sha256Hex(of: archive),
            maxDownloadBytes: 4096, maxDecompressedBytes: 4096, archiveFormat: .tarGz,
            expectedRelativePaths: ["bin/tool"], executableRelativePath: "bin/tool"
        )
        let entry = ManagedServerCatalogEntry(
            serverID: "insecure-test-server", language: "test", version: SemanticVersion(major: 1, minor: 0, patch: 0),
            minimumKodVersion: SemanticVersion(major: 1, minor: 0, patch: 0), artifacts: [artifact]
        )
        try await controller.grantConsent(serverID: entry.serverID, version: entry.version, architecture: .current)
        do {
            _ = try await controller.install(entry: entry, architecture: .current, trustRoot: FixtureSigningKey.trustRoot())
            XCTFail("expected insecureArtifactURL")
        } catch let error as ManagedInstallError {
            guard case .insecureArtifactURL = error else {
                XCTFail("expected insecureArtifactURL, got \(error)")
                return
            }
        }
    }

    func testConcurrentInstallsForSameServerAreCoalesced() async throws {
        let controller = try makeController()
        let (entry, server, _) = try makeEntryAndServer()
        defer { server.stop() }

        try await controller.grantConsent(serverID: entry.serverID, version: entry.version, architecture: .current)

        async let first = controller.install(entry: entry, architecture: .current, trustRoot: FixtureSigningKey.trustRoot())
        async let second = controller.install(entry: entry, architecture: .current, trustRoot: FixtureSigningKey.trustRoot())
        let (firstRecord, secondRecord) = try await (first, second)

        XCTAssertEqual(firstRecord, secondRecord)
        let installed = try await controller.installedRecord(serverID: entry.serverID)
        XCTAssertEqual(installed, firstRecord)
    }

    func testCancellationLeavesNoStagingOrDownloadArtifacts() async throws {
        let controller = try makeController()
        var randomBody = Data(count: 3_000_000)
        randomBody.withUnsafeMutableBytes { buffer in
            _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        let bigArchive = try GzipCodec.compress(TarWriter.write([
            .init(name: "bin/tool", mode: 0o755, body: randomBody)
        ]))
        let server = try LocalHTTPTestServer(responses: ["/artifact.tar.gz": bigArchive], chunkDelayNanoseconds: 15_000_000)
        server.start()
        defer { server.stop() }

        let artifact = ManagedServerArtifact(
            architecture: .current, url: server.url(forPath: "/artifact.tar.gz"),
            sha256Hex: Digest.sha256Hex(of: bigArchive), maxDownloadBytes: bigArchive.count + 4096,
            maxDecompressedBytes: 8 << 20, archiveFormat: .tarGz,
            expectedRelativePaths: ["bin/tool"], executableRelativePath: "bin/tool"
        )
        let entry = ManagedServerCatalogEntry(
            serverID: "cancel-test-server", language: "test", version: SemanticVersion(major: 1, minor: 0, patch: 0),
            minimumKodVersion: SemanticVersion(major: 1, minor: 0, patch: 0), artifacts: [artifact]
        )
        try await controller.grantConsent(serverID: entry.serverID, version: entry.version, architecture: .current)

        let token = ManagedDownloadCancellationToken()
        let installTask = Task {
            try await controller.install(entry: entry, architecture: .current, trustRoot: FixtureSigningKey.trustRoot(), cancellationToken: token)
        }
        try await Task.sleep(nanoseconds: 60_000_000)
        token.cancel()

        do {
            _ = try await installTask.value
            XCTFail("expected cancellation to propagate")
        } catch {
            // expected — any thrown error here means the pipeline stopped rather than completing.
        }

        let paths = ManagedInstallPaths(root: root)
        let stagingContents = (try? FileManager.default.contentsOfDirectory(at: paths.stagingDirectory, includingPropertiesForKeys: nil)) ?? []
        let downloadsContents = (try? FileManager.default.contentsOfDirectory(at: paths.downloadsDirectory, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(stagingContents.isEmpty, "cancelled install must not leave staging content: \(stagingContents)")
        XCTAssertTrue(downloadsContents.isEmpty, "cancelled install must not leave download content: \(downloadsContents)")
        let installed = try await controller.installedRecord(serverID: entry.serverID)
        XCTAssertNil(installed)
    }

    func testFullWorkspaceImmutability() async throws {
        let controller = try makeController()
        let (entry, server, _) = try makeEntryAndServer()
        defer { server.stop() }

        let beforeContents = try FileManager.default.contentsOfDirectory(atPath: workspaceRoot.path)
        let beforeMainSwift = try Data(contentsOf: workspaceRoot.appendingPathComponent("main.swift"))

        try await controller.grantConsent(serverID: entry.serverID, version: entry.version, architecture: .current)
        _ = try await controller.install(entry: entry, architecture: .current, trustRoot: FixtureSigningKey.trustRoot())
        // A rollback attempt with no previous version is expected to
        // fail — still exercised here to prove even a failing operation
        // touches nothing under the workspace.
        _ = try? await controller.rollback(serverID: entry.serverID)
        try await controller.remove(serverID: entry.serverID)

        let afterContents = try FileManager.default.contentsOfDirectory(atPath: workspaceRoot.path)
        let afterMainSwift = try Data(contentsOf: workspaceRoot.appendingPathComponent("main.swift"))
        XCTAssertEqual(beforeContents.sorted(), afterContents.sorted())
        XCTAssertEqual(beforeMainSwift, afterMainSwift)

        // No Kod metadata directory of any kind under the workspace root.
        let hasHiddenKodDirectory = FileManager.default.fileExists(atPath: workspaceRoot.appendingPathComponent(".kod").path)
        XCTAssertFalse(hasHiddenKodDirectory)
    }
}
