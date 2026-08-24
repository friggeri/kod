import AppKit
import Foundation
import LanguageAdapters
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

    func testApplicationLaunchDispatchesFullLanguageStatusRefresh() async throws {
        let repository = CodableSettingsRepository(
            store: InMemorySettingsKeyValueStore()
        )
        let overrideStore = LanguageServerOverrideStore(
            repository: repository
        )
        let profileStore = try LanguageProfileStore(
            defaultProfiles: [
                DefaultLanguageProfiles.swift,
                DefaultLanguageProfiles.markdown
            ],
            repository: repository,
            overrideStore: overrideStore
        )
        let recorder = LockedLanguageIdentifiers()
        let service = LanguageSupportService(
            profileStore: profileStore,
            overrideStore: overrideStore,
            statusCacheStore: LanguageServerStatusCacheStore(
                repository: repository
            ),
            discovery: { profile, _ in
                recorder.append(profile.identifier)
                return DiscoveredExecutable(
                    url: URL(fileURLWithPath: "/usr/bin/true"),
                    arguments: [],
                    version: nil,
                    source: .loginShellPath
                )
            }
        )
        let environment = try AppEnvironment.testing(
            settingsRepository: repository,
            languageSupportService: service
        )
        let delegate = AppDelegate(environment: environment)

        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        await delegate.languageStatusRefreshTask?.value

        XCTAssertEqual(
            Set(recorder.values),
            Set(["swift", "markdown"])
        )
        delegate.welcomeWindowController?.close()
    }

    func testTerminationWaitsForLaunchLanguageRefresh() async throws {
        let repository = CodableSettingsRepository(
            store: InMemorySettingsKeyValueStore()
        )
        let overrideStore = LanguageServerOverrideStore(
            repository: repository
        )
        let gate = DispatchSemaphore(value: 0)
        let service = LanguageSupportService(
            profileStore: try LanguageProfileStore(
                defaultProfiles: [DefaultLanguageProfiles.swift],
                repository: repository,
                overrideStore: overrideStore
            ),
            overrideStore: overrideStore,
            discovery: { _, _ in
                gate.wait()
                return DiscoveredExecutable(
                    url: URL(fileURLWithPath: "/usr/bin/true"),
                    arguments: [],
                    version: nil,
                    source: .loginShellPath
                )
            }
        )
        let environment = try AppEnvironment.testing(
            settingsRepository: repository,
            languageSupportService: service
        )
        let delegate = AppDelegate(environment: environment)
        let replyState = MainActorBoolean()

        delegate.startLanguageStatusRefresh()
        try await Task.sleep(for: .milliseconds(50))
        let termination = delegate.beginTermination {
            replyState.value = true
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertFalse(replyState.value)

        gate.signal()
        await termination.value
        XCTAssertTrue(replyState.value)
    }
}

private final class LockedLanguageIdentifiers: @unchecked Sendable {
    private let lock = NSLock()
    private var identifiers: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return identifiers
    }

    func append(_ identifier: String) {
        lock.lock()
        identifiers.append(identifier)
        lock.unlock()
    }
}

@MainActor
private final class MainActorBoolean {
    var value = false
}
