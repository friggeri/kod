import LanguageAdapters
import LanguageClient
import SourceModel
import WorkspaceCore
import XCTest
@testable import Kod

/// Headless coverage for `MultiLanguageServicesCoordinator`'s adapter
/// selection and lazy-start behavior (SPEC 6.2: "one server process
/// shared per workspace, language adapter"). No real language server
/// process is launched here — `service(forURL:)` before any document is
/// opened simply returns `nil`.
@MainActor
final class MultiLanguageServicesCoordinatorTests: XCTestCase {
    private func makeTrustedIdentity() throws -> (WorkspaceIdentity, WorkspaceTrustStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let identity = try WorkspaceIdentity(root: root)
        let suiteName = "MultiLanguageServicesCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        let store = WorkspaceTrustStore(defaults: defaults)
        store.trust(identity)
        return (identity, store)
    }

    func testManagedAdaptersExcludeSwift() {
        XCTAssertFalse(
            MultiLanguageServicesCoordinator.managedAdapters.contains {
                ObjectIdentifier($0) == ObjectIdentifier(SwiftAdapter.self)
            },
            "Swift must keep going through LanguageServicesCoordinator/SwiftWorkspaceLanguageService, not a second, redundant SourceKit-LSP process"
        )
        XCTAssertTrue(MultiLanguageServicesCoordinator.managedAdapters.contains { ObjectIdentifier($0) == ObjectIdentifier(TypeScriptLanguageAdapter.self) })
        XCTAssertTrue(MultiLanguageServicesCoordinator.managedAdapters.contains { ObjectIdentifier($0) == ObjectIdentifier(PythonLanguageAdapter.self) })
        XCTAssertTrue(MultiLanguageServicesCoordinator.managedAdapters.contains { ObjectIdentifier($0) == ObjectIdentifier(RustLanguageAdapter.self) })
        XCTAssertTrue(MultiLanguageServicesCoordinator.managedAdapters.contains { ObjectIdentifier($0) == ObjectIdentifier(HTMLLanguageAdapter.self) })
        XCTAssertTrue(MultiLanguageServicesCoordinator.managedAdapters.contains { ObjectIdentifier($0) == ObjectIdentifier(CSSLanguageAdapter.self) })
    }

    func testServiceForURLIsNilBeforeAnyDocumentIsOpened() throws {
        let (identity, store) = try makeTrustedIdentity()
        let coordinator = MultiLanguageServicesCoordinator(identity: identity, trustStore: store)
        XCTAssertNil(coordinator.service(forURL: URL(fileURLWithPath: "/workspace/main.ts")))
    }

    func testServiceForURLReturnsNilForAnUnrecognizedExtension() throws {
        let (identity, store) = try makeTrustedIdentity()
        let coordinator = MultiLanguageServicesCoordinator(identity: identity, trustStore: store)
        XCTAssertNil(coordinator.service(forURL: URL(fileURLWithPath: "/workspace/README.md")))
    }

    func testHandleDocumentReadyIsANoOpForAnUntrustedWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let identity = try WorkspaceIdentity(root: root)
        let suiteName = "MultiLanguageServicesCoordinatorTests.Untrusted.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        let untrustedStore = WorkspaceTrustStore(defaults: defaults)
        let coordinator = MultiLanguageServicesCoordinator(identity: identity, trustStore: untrustedStore)

        let fileURL = root.appendingPathComponent("main.ts")
        try "class Foo {}".write(to: fileURL, atomically: true, encoding: .utf8)
        let snapshot = try SourceSnapshotLoader().load(url: fileURL, version: 1)
        coordinator.handleDocumentReady(url: fileURL, snapshot: snapshot)

        // Give any (incorrectly) started async work a moment to run.
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(coordinator.service(forURL: fileURL), "No service may start for an untrusted workspace")
    }
}
