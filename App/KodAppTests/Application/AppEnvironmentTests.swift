import Foundation
import SettingsCore
import WorkspaceCore
import XCTest
@testable import Kod

@MainActor
final class AppEnvironmentTests: XCTestCase {
    private func makeWorkspaceRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    func testWorkspacesShareAppServicesAndOwnWorkspaceStores() throws {
        let fixture = try KodAppTestEnvironment.make(in: self)
        let first = fixture.environment.makeWorkspaceDependencies()
        let second = fixture.environment.makeWorkspaceDependencies()
        let firstController = WorkspaceViewController(
            identity: try WorkspaceIdentity(
                root: makeWorkspaceRoot()
            ),
            dependencies: first
        )
        let secondController = WorkspaceViewController(
            identity: try WorkspaceIdentity(
                root: makeWorkspaceRoot()
            ),
            dependencies: second
        )

        XCTAssertTrue(
            firstController.diagnosticsLog === secondController.diagnosticsLog
        )
        XCTAssertTrue(
            firstController.languageSupportService
                === secondController.languageSupportService
        )
        XCTAssertTrue(
            firstController.languageSupportService.profileRegistry
                === secondController.languageSupportService.profileRegistry
        )
        XCTAssertTrue(first.appearanceCenter === second.appearanceCenter)
        XCTAssertFalse(
            firstController.trustStore === secondController.trustStore
        )
        XCTAssertFalse(
            firstController.layoutStore === secondController.layoutStore
        )
        XCTAssertFalse(
            firstController.workspaceDiagnosticsStore
                === secondController.workspaceDiagnosticsStore
        )
    }

    func testTestingEnvironmentUsesOnlySuppliedDefaults() throws {
        let first = try KodAppTestEnvironment.make(in: self)
        let second = try KodAppTestEnvironment.make(in: self)
        let marker = "app-environment-test-\(UUID().uuidString)"

        try first.environment.settingsRepository.keyValueStore.setValue(
            .boolean(true),
            forKey: marker
        )

        XCTAssertEqual(
            try first.keyValueStore.value(forKey: marker),
            .boolean(true)
        )
        XCTAssertNil(try second.keyValueStore.value(forKey: marker))
        XCTAssertTrue(
            first.environment.settingsRepository.keyValueStore as AnyObject
                === first.keyValueStore
        )
    }

    func testWorkspaceControllerRequiresExplicitDependencies() throws {
        let fixture = try KodAppTestEnvironment.make(in: self)
        let root = try makeWorkspaceRoot()
        let controller = WorkspaceViewController(
            identity: try WorkspaceIdentity(root: root),
            dependencies: fixture.environment.makeWorkspaceDependencies()
        )

        XCTAssertTrue(
            controller.diagnosticsLog === fixture.environment.diagnosticsLog
        )
        XCTAssertTrue(
            controller.languageSupportService
                === fixture.environment.languageSupportService
        )
    }
}
