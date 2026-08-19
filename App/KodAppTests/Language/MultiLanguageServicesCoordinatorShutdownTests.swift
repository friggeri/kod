import AppKit
import CodeViewport
import DiagnosticsCore
import LanguageAdapters
import LanguageClient
import SettingsCore
import SourceModel
import WorkspaceCore
import XCTest
@testable import Kod

/// A continuation the coordinator's document-synchronization operation
/// blocks on until the test releases it — or until shutdown cancels it.
/// Lets a test hold work "in flight" deterministically, with no sleeps.
private final class SynchronizationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isFinished = false
    private var cancelled = false

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if isFinished {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            cancelled = true
            lock.unlock()
            finish()
        }
    }

    func finish() {
        lock.lock()
        isFinished = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}

private enum StubDiscoveryError: Error {
    case noExecutable
}

/// Headless coverage for `MultiLanguageServicesCoordinator`'s explicit
/// shutdown (SPEC 6.2). Every service is built through an injected
/// factory whose discovery always fails, so no language server process
/// is ever launched: what is asserted here is *lifecycle ownership* —
/// that shutdown stops every service exactly once, is idempotent and
/// concurrency-safe, and that no scheduled or in-flight work survives it.
@MainActor
final class MultiLanguageServicesCoordinatorShutdownTests: XCTestCase {
    private final class ServiceRecorder {
        private(set) var services: [String: LanguageWorkspaceService] = [:]

        func record(_ service: LanguageWorkspaceService, for identifier: String) {
            services[identifier] = service
        }
    }

    private func makeTrustedIdentity() throws -> (WorkspaceIdentity, WorkspaceTrustStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let identity = try WorkspaceIdentity(root: root)
        let store = WorkspaceTrustStore(
            repository: CodableSettingsRepository(
                store: InMemorySettingsKeyValueStore()
            )
        )
        try store.trust(identity)
        return (identity, store)
    }

    private func makeRegistry() throws -> LanguageProfileRegistry {
        return LanguageProfileRegistry(
            store: try LanguageProfileStore(
                repository: CodableSettingsRepository(
                    store: InMemorySettingsKeyValueStore()
                )
            )
        )
    }

    private struct Fixture {
        let identity: WorkspaceIdentity
        let coordinator: MultiLanguageServicesCoordinator
        let recorder: ServiceRecorder
    }

    private func makeFixture() throws -> Fixture {
        let (identity, trustStore) = try makeTrustedIdentity()
        let coordinator = MultiLanguageServicesCoordinator(
            identity: identity,
            trustStore: trustStore,
            profileRegistry: try makeRegistry(),
            overrideStore: try KodAppTestEnvironment.makeOverrideStore(in: self),
            diagnosticsLog: BoundedEventLog(),
            diagnosticsStore: WorkspaceDiagnosticsStore()
        )
        let recorder = ServiceRecorder()
        coordinator.makeLanguageService = { profile, binding in
            let service = LanguageWorkspaceService(
                identity: identity,
                trustStore: trustStore,
                configuration: LanguageWorkspaceService.Configuration(
                    languageId: profile.identifier
                ),
                dependencies: LanguageWorkspaceService.Dependencies(
                    discoverExecutable: { throw StubDiscoveryError.noExecutable }
                ),
                providerID: binding.providerID,
                onStateChange: binding.onStateChange,
                onDiagnostics: binding.onDiagnostics,
                onNormalizedDiagnostics: binding.onNormalizedDiagnostics,
                onWorkspaceDiagnosticsFailure: binding.onWorkspaceDiagnosticsFailure,
                onDocumentReplayFailure: binding.onDocumentReplayFailure
            )
            recorder.record(service, for: profile.identifier)
            return service
        }
        return Fixture(
            identity: identity,
            coordinator: coordinator,
            recorder: recorder
        )
    }

    private func openDocument(
        named name: String,
        in fixture: Fixture
    ) async -> CodeDocumentViewController {
        let snapshot = SourceSnapshot(
            text: "let value = 1\n",
            url: fixture.identity.root.appendingPathComponent(name),
            version: 1
        )
        let controller = CodeDocumentViewController(snapshot: snapshot)
        fixture.coordinator.handleDocumentReady(
            relativePath: name,
            controller: controller
        )
        await fixture.coordinator.waitForPendingWork()
        return controller
    }

    func testStopAllStopsEveryServiceAndIsIdempotent() async throws {
        let fixture = try makeFixture()
        let swiftController = await openDocument(named: "Sample.swift", in: fixture)
        let typeScriptController = await openDocument(named: "Sample.ts", in: fixture)

        let swiftService = try XCTUnwrap(fixture.recorder.services["swift"])
        let typeScriptService = try XCTUnwrap(fixture.recorder.services["typescript"])
        XCTAssertNotNil(fixture.coordinator.providerID(forProfileIdentifier: "swift"))
        XCTAssertNotNil(fixture.coordinator.providerID(forProfileIdentifier: "typescript"))
        let swiftGenerationBeforeShutdown = await swiftService.currentGeneration
        let typeScriptGenerationBeforeShutdown = await typeScriptService.currentGeneration

        await fixture.coordinator.stopAll()

        XCTAssertTrue(fixture.coordinator.isShutDown)
        let swiftGeneration = await swiftService.currentGeneration
        let typeScriptGeneration = await typeScriptService.currentGeneration
        XCTAssertEqual(
            swiftGeneration,
            swiftGenerationBeforeShutdown + 1,
            "Every service must be stopped exactly once"
        )
        XCTAssertEqual(typeScriptGeneration, typeScriptGenerationBeforeShutdown + 1)
        XCTAssertNil(
            fixture.coordinator.providerID(forProfileIdentifier: "swift"),
            "Provider routing must not survive shutdown"
        )
        XCTAssertNil(fixture.coordinator.providerID(forProfileIdentifier: "typescript"))
        XCTAssertTrue(fixture.coordinator.states.isEmpty)
        XCTAssertEqual(fixture.coordinator.pendingWorkCount, 0)
        XCTAssertEqual(fixture.coordinator.pendingDocumentCloseCount, 0)
        XCTAssertEqual(fixture.coordinator.inFlightSynchronizationCount, 0)
        XCTAssertTrue(
            fixture.coordinator.liveDocumentControllers(
                forURL: swiftController.snapshot.url
            ).isEmpty,
            "Registrations must be cleared by shutdown"
        )

        await fixture.coordinator.stopAll()
        await fixture.coordinator.stopAll()
        let swiftGenerationAfterRepeat = await swiftService.currentGeneration
        let typeScriptGenerationAfterRepeat = await typeScriptService.currentGeneration
        XCTAssertEqual(swiftGenerationAfterRepeat, swiftGeneration)
        XCTAssertEqual(typeScriptGenerationAfterRepeat, typeScriptGeneration)
        withExtendedLifetime((swiftController, typeScriptController)) {}
    }

    func testConcurrentStopAllCallsJoinOneShutdown() async throws {
        let fixture = try makeFixture()
        let controller = await openDocument(named: "Concurrent.swift", in: fixture)
        let service = try XCTUnwrap(fixture.recorder.services["swift"])
        let generationBeforeShutdown = await service.currentGeneration

        let coordinator = fixture.coordinator
        async let first: Void = coordinator.stopAll()
        async let second: Void = coordinator.stopAll()
        async let third: Void = coordinator.stopAll()
        _ = await (first, second, third)

        let generation = await service.currentGeneration
        XCTAssertEqual(
            generation,
            generationBeforeShutdown + 1,
            "Concurrent shutdowns must join one operation rather than stopping twice"
        )
        XCTAssertTrue(coordinator.isShutDown)
        withExtendedLifetime(controller) {}
    }

    func testScheduledCloseAndInFlightSynchronizationCannotOutliveShutdown() async throws {
        let fixture = try makeFixture()
        let coordinator = fixture.coordinator
        let scheduler = ShutdownCloseSchedulerSpy(installedOn: coordinator)

        let controller = await openDocument(named: "Closing.swift", in: fixture)
        coordinator.handleDocumentClosed(
            relativePath: "Closing.swift",
            controller: controller
        )
        XCTAssertEqual(
            coordinator.pendingDocumentCloseCount,
            1,
            "The close is scheduled but has not fired"
        )

        let gate = SynchronizationGate()
        let synchronizationURL = fixture.identity.root
            .appendingPathComponent("Synchronizing.swift")
        let synchronization = Task { @MainActor in
            await coordinator.synchronizeCoalescing(
                url: synchronizationURL,
                profileIdentifier: "swift",
                version: 1
            ) {
                await gate.wait()
                return .opened
            }
        }
        while coordinator.inFlightSynchronizationCount == 0 {
            await Task.yield()
        }

        await coordinator.stopAll()

        XCTAssertEqual(
            scheduler.cancelCount,
            1,
            "A close still waiting out its grace period must be cancelled by shutdown"
        )
        XCTAssertTrue(
            gate.wasCancelled,
            "An in-flight synchronization must be cancelled by shutdown"
        )
        _ = await synchronization.value
        XCTAssertEqual(coordinator.pendingDocumentCloseCount, 0)
        XCTAssertEqual(coordinator.inFlightSynchronizationCount, 0)
        XCTAssertEqual(coordinator.pendingWorkCount, 0)

        // A timer that fires after shutdown is inert rather than
        // resurrecting a close against a stopped service.
        scheduler.fireAll()
        XCTAssertEqual(coordinator.pendingDocumentCloseCount, 0)
        withExtendedLifetime(controller) {}
    }

    func testDocumentWorkRequestedAfterShutdownIsIgnored() async throws {
        let fixture = try makeFixture()
        await fixture.coordinator.stopAll()

        let snapshot = SourceSnapshot(
            text: "let value = 1\n",
            url: fixture.identity.root.appendingPathComponent("Late.swift"),
            version: 1
        )
        let controller = CodeDocumentViewController(snapshot: snapshot)
        fixture.coordinator.handleDocumentReady(
            relativePath: "Late.swift",
            controller: controller
        )

        XCTAssertEqual(fixture.coordinator.pendingWorkCount, 0)
        XCTAssertTrue(
            fixture.coordinator.liveDocumentControllers(forURL: snapshot.url).isEmpty
        )
        XCTAssertNil(fixture.coordinator.service(forURL: snapshot.url))
        XCTAssertNil(fixture.recorder.services["swift"])
        withExtendedLifetime(controller) {}
    }

    /// The workspace session's explicit, retained shutdown stops language
    /// services without relying on ARC releasing the coordinator.
    func testWorkspaceSessionShutdownCompletesLanguageServiceShutdown() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let identity = try WorkspaceIdentity(root: root)
        let appFixture = try KodAppTestEnvironment.make(in: self)
        let controller = WorkspaceViewController(
            identity: identity,
            dependencies: appFixture.environment.makeWorkspaceDependencies()
        )

        XCTAssertFalse(controller.multiLanguageServicesCoordinator.isShutDown)
        controller.beginLanguageServicesShutdown()
        await controller.shutdownLanguageServices()

        XCTAssertTrue(
            controller.multiLanguageServicesCoordinator.isShutDown,
            "Window close must start a shutdown that actually completes"
        )
    }
}

/// Deterministic stand-in for the grace-period timer behind
/// `MultiLanguageServicesCoordinator.scheduleDocumentClose`, so this
/// suite can hold a close "scheduled but not fired", observe that
/// shutdown cancelled it, and prove a stale fire afterwards is inert.
@MainActor
private final class ShutdownCloseSchedulerSpy {
    private(set) var cancelCount = 0
    private var pendingFires: [@MainActor () -> Void] = []

    init(installedOn coordinator: MultiLanguageServicesCoordinator) {
        coordinator.scheduleDocumentClose = { [weak self] _, fire in
            self?.pendingFires.append(fire)
            return LanguageDocumentCloseSchedule {
                self?.cancelCount += 1
            }
        }
    }

    func fireAll() {
        let fires = pendingFires
        pendingFires.removeAll()
        for fire in fires {
            fire()
        }
    }
}
