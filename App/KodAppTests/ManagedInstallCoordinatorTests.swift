import CryptoKit
import DiagnosticsCore
import Foundation
import ManagedLanguageServers
import XCTest
@testable import Kod

/// Headless coverage for `ManagedInstallCoordinator`: the app-facing
/// surface SPEC 6.5 requires for setup/install/update/rollback/remove
/// state (provenance, version, path, architecture). No real language
/// server executable is required for status-only checks; the full
/// install-drives-status-updates test uses a minimal loopback HTTP
/// fixture server, never any external network.
@MainActor
final class ManagedInstallCoordinatorTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ManagedInstallCoordinatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private static let fixtureSeed = Data((0..<32).map { UInt8(($0 * 11 + 2) % 256) })
    private static let fixturePrivateKey = try! Curve25519.Signing.PrivateKey(rawRepresentation: fixtureSeed)
    private static let fixtureKeyID = "coordinator-fixture-key"

    private func trustRoot() -> CatalogTrustRoot {
        CatalogTrustRoot(pinned: [
            TrustedSigningKey(
                id: Self.fixtureKeyID,
                publicKeyBase64: Self.fixturePrivateKey.publicKey.rawRepresentation.base64EncodedString(),
                validFrom: Date(timeIntervalSince1970: 0)
            )
        ])
    }

    func testStatusIsNotInstalledBeforeAnyInstall() async throws {
        let controller = try ManagedInstallController(paths: ManagedInstallPaths(root: try makeRoot()))
        let coordinator = ManagedInstallCoordinator(controller: controller)

        await coordinator.refreshStatus(serverID: "pyright", language: "python")
        let status = coordinator.status(for: "pyright")
        XCTAssertEqual(status.lifecycle, .notInstalled)
        XCTAssertNil(status.installedVersion)
        XCTAssertNil(status.provenance)
    }

    func testUnsupportedArchitectureReportsWithoutTouchingNetwork() async throws {
        let controller = try ManagedInstallController(paths: ManagedInstallPaths(root: try makeRoot()))
        let coordinator = ManagedInstallCoordinator(controller: controller)
        let otherArchitecture: ManagedInstallArchitecture = ManagedInstallArchitecture.current == .arm64 ? .x86_64 : .arm64

        let artifact = ManagedServerArtifact(
            architecture: otherArchitecture,
            url: URL(string: "https://example.invalid/never-fetched.tar.gz")!,
            sha256Hex: String(repeating: "a", count: 64),
            maxDownloadBytes: 1024, maxDecompressedBytes: 1024, archiveFormat: .tarGz,
            expectedRelativePaths: ["bin/tool"], executableRelativePath: "bin/tool"
        )
        let entry = ManagedServerCatalogEntry(
            serverID: "coordinator-arch-test", language: "test", version: SemanticVersion(major: 1, minor: 0, patch: 0),
            minimumKodVersion: SemanticVersion(major: 1, minor: 0, patch: 0), artifacts: [artifact]
        )

        await coordinator.requestInstall(entry: entry, architecture: .current, trustRoot: trustRoot())
        XCTAssertEqual(coordinator.status(for: "coordinator-arch-test").lifecycle, .unsupportedArchitecture)
    }

    func testRequestInstallDrivesStatusToInstalledThenRemove() async throws {
        let controller = try ManagedInstallController(paths: ManagedInstallPaths(root: try makeRoot()))
        let coordinator = ManagedInstallCoordinator(controller: controller)

        let archive = try GzipCodec.compress(TarWriter.write([
            .init(name: "bin/tool", type: .regularFile, mode: 0o755, body: Data("fixture-binary".utf8))
        ]))
        let server = try CoordinatorTestHTTPServer(responseBody: archive)
        server.start()
        defer { server.stop() }

        let artifact = ManagedServerArtifact(
            architecture: .current,
            url: server.baseURL,
            sha256Hex: Digest.sha256Hex(of: archive),
            maxDownloadBytes: archive.count + 4096, maxDecompressedBytes: 4096, archiveFormat: .tarGz,
            expectedRelativePaths: ["bin/tool"], executableRelativePath: "bin/tool"
        )
        let version = SemanticVersion(major: 3, minor: 1, patch: 4)
        let entry = ManagedServerCatalogEntry(
            serverID: "coordinator-install-test", language: "python", version: version,
            minimumKodVersion: SemanticVersion(major: 1, minor: 0, patch: 0), artifacts: [artifact]
        )

        await coordinator.requestInstall(entry: entry, architecture: .current, trustRoot: trustRoot())

        let installedStatus = coordinator.status(for: "coordinator-install-test")
        XCTAssertEqual(installedStatus.lifecycle, .installed)
        XCTAssertEqual(installedStatus.installedVersion, version)
        XCTAssertEqual(installedStatus.installedArchitecture, .current)
        XCTAssertEqual(installedStatus.provenance, .managedInstall)

        await coordinator.remove(serverID: "coordinator-install-test", language: "python")
        XCTAssertEqual(coordinator.status(for: "coordinator-install-test").lifecycle, .notInstalled)
    }

    /// SPEC 15's "genuine, real, working" diagnostic-event wiring for the
    /// managed-install subsystem: rolling back a server with no active
    /// (or previous) installed version is a real, already-existing
    /// `.failed(message:)` path (`ActiveVersionStoreError.noActiveVersion`),
    /// triggered here the same way `testStatusIsNotInstalledBeforeAnyInstall`
    /// exercises the coordinator, with no fixture server/network involved.
    func testRollbackFailureRecordsAManagedInstallDiagnosticEvent() async throws {
        let controller = try ManagedInstallController(paths: ManagedInstallPaths(root: try makeRoot()))
        let log = BoundedEventLog()
        let coordinator = ManagedInstallCoordinator(controller: controller, diagnosticsLog: log)

        await coordinator.rollback(serverID: "never-installed-server", language: "swift")
        guard case .failed = coordinator.status(for: "never-installed-server").lifecycle else {
            XCTFail("Expected .failed lifecycle after rolling back a server with no active/previous version")
            return
        }

        let events = await log.redactedSnapshot()
        let managedInstallEvents = events.filter { $0.subsystem == .managedInstall }
        XCTAssertFalse(managedInstallEvents.isEmpty, "A failed rollback should record a .managedInstall diagnostic event")
        XCTAssertTrue(managedInstallEvents.allSatisfy { event in
            event.context.first { $0.name == "serverID" }?.value == "<symbol redacted>"
        }, "serverID must be tagged .symbol so it is fully redacted in the event's context")
    }
}

/// A minimal loopback-only single-response HTTP server, duplicated
/// (deliberately, matching this codebase's existing per-test-target
/// locator/helper duplication convention — see e.g.
/// `FakeLanguageServerLocator`) from `ManagedLanguageServersTests`'s
/// `LocalHTTPTestServer` since Xcode's `KodAppTests` bundle cannot share
/// sources with a separate SwiftPM test target.
final class CoordinatorTestHTTPServer: @unchecked Sendable {
    private let listenSocket: Int32
    private let port: UInt16
    private let responseBody: Data
    private var shouldStop = false
    private let stopLock = NSLock()

    init(responseBody: Data) throws {
        self.responseBody = responseBody
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        var reuse: Int32 = 1
        setsockopt(fileDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var assigned = sockaddr_in()
        var assignedLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fileDescriptor, $0, &assignedLength) }
        }
        listen(fileDescriptor, 4)
        listenSocket = fileDescriptor
        port = assigned.sin_port.bigEndian
    }

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    func start() {
        Thread { [weak self] in self?.acceptLoop() }.start()
    }

    func stop() {
        stopLock.lock(); shouldStop = true; stopLock.unlock()
        close(listenSocket)
    }

    private func acceptLoop() {
        while true {
            stopLock.lock(); let stopping = shouldStop; stopLock.unlock()
            if stopping { return }
            let clientSocket = accept(listenSocket, nil, nil)
            if clientSocket < 0 { return }
            var noSigPipe: Int32 = 1
            setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            var requestBuffer = [UInt8](repeating: 0, count: 2048)
            _ = requestBuffer.withUnsafeMutableBytes { recv(clientSocket, $0.baseAddress, $0.count, 0) }
            let header = "HTTP/1.1 200 OK\r\nContent-Length: \(responseBody.count)\r\nConnection: close\r\n\r\n"
            _ = header.withCString { send(clientSocket, $0, strlen($0), 0) }
            _ = responseBody.withUnsafeBytes { send(clientSocket, $0.baseAddress, $0.count, 0) }
            close(clientSocket)
        }
    }
}
