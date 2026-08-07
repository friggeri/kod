import Foundation
import LanguageClient
import XCTest
@testable import ManagedLanguageServers

/// Full offline lifecycle coverage for `ManagedInstallController`:
/// install, launching the installed executable as a real child process
/// and speaking real LSP framing to it, upgrade, rollback, remove, and
/// recovery from a simulated interrupted install — all against a
/// signed fixture catalog and a `LocalHTTPTestServer` loopback
/// artifact host, never any external network.
final class ManagedInstallLifecycleTests: XCTestCase {
    private var root: URL!
    private var server: LocalHTTPTestServer!
    private var built: FixtureCatalog.Built!
    private var v1: SemanticVersion!
    private var v2: SemanticVersion!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ManagedInstallLifecycleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        v1 = SemanticVersion(major: 1, minor: 0, patch: 0)
        v2 = SemanticVersion(major: 1, minor: 1, patch: 0)

        // Build archives first (without knowing the server's port yet),
        // start the server keyed by version path, then rebuild the
        // catalog with real per-version URLs pointing at it.
        let preliminary = try FixtureCatalog.build { version in
            URL(string: "http://127.0.0.1:1/\(version).tar.gz")!
        }
        server = try LocalHTTPTestServer(responses: [
            "/\(v1!).tar.gz": preliminary.archives[v1]!,
            "/\(v2!).tar.gz": preliminary.archives[v2]!
        ])
        server.start()

        built = try FixtureCatalog.build { [server] version in
            server!.url(forPath: "/\(version).tar.gz")
        }
    }

    override func tearDownWithError() throws {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func makeController() throws -> ManagedInstallController {
        try ManagedInstallController(paths: ManagedInstallPaths(root: root))
    }

    private func verifiedCatalog() throws -> ManagedServerCatalog {
        try CatalogVerifier.verify(built.signedDocument, trustRoot: FixtureSigningKey.trustRoot())
    }

    func testInstallThenLaunchRealProcess() async throws {
        let controller = try makeController()
        let catalog = try verifiedCatalog()
        let entry = try XCTUnwrap(catalog.entry(serverID: FixtureCatalog.serverID))

        try await controller.grantConsent(serverID: entry.serverID, version: entry.version, architecture: .current)

        let stagesBox = LockedBoxValue<[ManagedInstallStage]>([])
        let record = try await controller.install(entry: entry, architecture: .current, trustRoot: FixtureSigningKey.trustRoot()) { stage in
            stagesBox.set(stagesBox.get() + [stage])
        }
        let stages = stagesBox.get()

        XCTAssertEqual(record.version, v1)
        XCTAssertTrue(stages.contains { if case .extracting = $0 { return true } else { return false } })
        XCTAssertTrue(stages.contains { if case .activating = $0 { return true } else { return false } })

        let paths = ManagedInstallPaths(root: root)
        let executableURL = paths.versionDirectory(serverID: entry.serverID, version: v1)
            .appendingPathComponent(record.executableRelativePath)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executableURL.path))

        // Launch the real, installed FakeLanguageServer and speak one
        // real `initialize` request/response over stdio — proving this
        // is a genuinely runnable server, not just correctly-shaped
        // bytes on disk.
        let initializeResult = try await Self.launchAndInitialize(executableURL: executableURL, arguments: record.adapterArguments)
        XCTAssertNotNil(initializeResult)
    }

    func testUpgradeThenRollback() async throws {
        let controller = try makeController()
        let catalog = try verifiedCatalog()
        let entry1 = try XCTUnwrap(catalog.entry(serverID: FixtureCatalog.serverID))
        let entry2 = try XCTUnwrap(catalog.entries.first { $0.version == v2 })

        try await controller.grantConsent(serverID: entry1.serverID, version: entry1.version, architecture: .current)
        _ = try await controller.install(entry: entry1, architecture: .current, trustRoot: FixtureSigningKey.trustRoot())

        try await controller.grantConsent(serverID: entry2.serverID, version: entry2.version, architecture: .current)
        let upgraded = try await controller.install(entry: entry2, architecture: .current, trustRoot: FixtureSigningKey.trustRoot())
        XCTAssertEqual(upgraded.version, v2)

        let activeAfterUpgrade = try await controller.installedRecord(serverID: entry1.serverID)
        XCTAssertEqual(activeAfterUpgrade?.version, v2)

        let rolledBack = try await controller.rollback(serverID: entry1.serverID)
        XCTAssertEqual(rolledBack.version, v1)

        let activeAfterRollback = try await controller.installedRecord(serverID: entry1.serverID)
        XCTAssertEqual(activeAfterRollback?.version, v1)
    }

    func testRemoveClearsInstalledState() async throws {
        let controller = try makeController()
        let catalog = try verifiedCatalog()
        let entry = try XCTUnwrap(catalog.entry(serverID: FixtureCatalog.serverID))

        try await controller.grantConsent(serverID: entry.serverID, version: entry.version, architecture: .current)
        _ = try await controller.install(entry: entry, architecture: .current, trustRoot: FixtureSigningKey.trustRoot())
        let installed = try await controller.installedRecord(serverID: entry.serverID)
        XCTAssertNotNil(installed)

        try await controller.remove(serverID: entry.serverID)
        let afterRemoval = try await controller.installedRecord(serverID: entry.serverID)
        XCTAssertNil(afterRemoval)

        let paths = ManagedInstallPaths(root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.serverVersionsDirectory(serverID: entry.serverID).path))
    }

    func testInstallWithoutConsentIsRejected() async throws {
        let controller = try makeController()
        let catalog = try verifiedCatalog()
        let entry = try XCTUnwrap(catalog.entry(serverID: FixtureCatalog.serverID))

        do {
            _ = try await controller.install(entry: entry, architecture: .current, trustRoot: FixtureSigningKey.trustRoot())
            XCTFail("expected consentRequired")
        } catch let error as ManagedInstallError {
            guard case .consentRequired = error else {
                XCTFail("expected consentRequired, got \(error)")
                return
            }
        }
    }

    func testInterruptedInstallRecoveryCleansStagingAndDownloads() async throws {
        let paths = ManagedInstallPaths(root: root)
        try paths.ensureLayoutExists()

        // Simulate a crash mid-install: leftover staging directory with
        // partial extracted content, and a leftover partial download
        // file — neither ever cleaned up because the process "died"
        // before reaching the atomic activation step.
        let staleStaging = paths.newStagingDirectory(serverID: "some-server")
        try FileManager.default.createDirectory(at: staleStaging, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: staleStaging.appendingPathComponent("partial-file"))

        let staleDownload = paths.newDownloadFileURL(serverID: "some-server")
        try FileManager.default.createDirectory(at: staleDownload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("partial-download-bytes".utf8).write(to: staleDownload)

        let controller = try makeController()
        try await controller.recoverInterruptedOperations()

        let stagingContents = try FileManager.default.contentsOfDirectory(at: paths.stagingDirectory, includingPropertiesForKeys: nil)
        let downloadsContents = try FileManager.default.contentsOfDirectory(at: paths.downloadsDirectory, includingPropertiesForKeys: nil)
        XCTAssertTrue(stagingContents.isEmpty)
        XCTAssertTrue(downloadsContents.isEmpty)

        // A fresh install afterward still works cleanly.
        let catalog = try verifiedCatalog()
        let entry = try XCTUnwrap(catalog.entry(serverID: FixtureCatalog.serverID))
        try await controller.grantConsent(serverID: entry.serverID, version: entry.version, architecture: .current)
        let record = try await controller.install(entry: entry, architecture: .current, trustRoot: FixtureSigningKey.trustRoot())
        XCTAssertEqual(record.version, v1)
    }

    // MARK: - Real process launch helper

    private static func launchAndInitialize(executableURL: URL, arguments: [String]) async throws -> JSONValue? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            process.terminate()
        }

        let request = JSONRPCMessage(kind: .request(id: .number(1), method: "initialize", params: .object(["capabilities": .object([:])])))
        let data = try request.encoded()
        stdinPipe.fileHandleForWriting.write(JSONRPCFramingEncoder.frame(data))

        var decoder = JSONRPCFramingDecoder()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let available = stdoutPipe.fileHandleForReading.availableData
            if available.isEmpty {
                try await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            for messageData in try decoder.consume(available) {
                if let message = try? JSONRPCMessage.decode(from: messageData),
                   case .response(_, let result, _) = message.kind {
                    return result
                }
            }
        }
        return nil
    }
}
