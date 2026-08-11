import Foundation
import SourceModel
import WorkspaceCore
import XCTest
@testable import LanguageClient

/// Exercises `LanguageWorkspaceService` directly — the language-agnostic
/// engine every non-Swift adapter (TypeScript/JavaScript, HTML, CSS,
/// Python, Rust) uses as-is via `LanguageProfileServiceFactory` —
/// against the deterministic `FakeLanguageServer` fixture, independent
/// of `SwiftWorkspaceLanguageService`'s thin wrapper. This proves the
/// crash/restart, capability-gating, and invalid-range-discard
/// guarantees `SwiftWorkspaceLanguageServiceFixtureTests` already
/// verifies through the Swift-facing wrapper hold for every other
/// adapter too, since they all share this exact implementation rather
/// than a per-language reimplementation.
final class LanguageWorkspaceServiceFixtureTests: XCTestCase {
    @MainActor
    private func makeTrustedIdentity() throws -> (WorkspaceIdentity, WorkspaceTrustStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let identity = try WorkspaceIdentity(root: root)
        let suiteName = "LanguageWorkspaceServiceFixtureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        let store = WorkspaceTrustStore(defaults: defaults)
        store.trust(identity)
        return (identity, store, root)
    }

    private func makeDependencies(scenario: String, environment: [String: String]? = nil) throws -> LanguageWorkspaceService.Dependencies {
        let executableURL = try FakeLanguageServerLocator.executableURL()
        return LanguageWorkspaceService.Dependencies(
            discoverExecutable: { executableURL },
            connectionFactory: { configuration, onStateChange, onNotification in
                var configuration = configuration
                configuration.arguments = [scenario]
                configuration.environment = environment
                return LanguageServerConnection(configuration: configuration, onStateChange: onStateChange, onNotification: onNotification)
            }
        )
    }

    private func makeService(
        identity: WorkspaceIdentity,
        trustStore: WorkspaceTrustStore,
        scenario: String,
        environment: [String: String]? = nil
    ) throws -> LanguageWorkspaceService {
        LanguageWorkspaceService(
            identity: identity,
            trustStore: trustStore,
            configuration: LanguageWorkspaceService.Configuration(
                languageId: "typescript",
                semanticTokenTypes: ["namespace", "type", "class", "enum", "function", "variable"],
                semanticTokenModifiers: ["declaration", "readonly"]
            ),
            dependencies: try makeDependencies(scenario: scenario, environment: environment)
        )
    }

    @MainActor
    func testExtendedCapabilitiesRoundTripForANonSwiftLanguageId() async throws {
        let (identity, store, root) = try makeTrustedIdentity()
        let service = try makeService(identity: identity, trustStore: store, scenario: "normal")
        try await service.start()
        defer { Task { await service.stop() } }

        let fileURL = root.appendingPathComponent("Fake.ts")
        let snapshot = SourceSnapshot(text: "class Greeter {}\n", url: fileURL, version: 1)
        try await service.didOpen(snapshot)

        let declarations = try await service.declaration(snapshot: snapshot, utf8Offset: 0)
        XCTAssertEqual(declarations.count, 1)
        let highlights = try await service.documentHighlights(snapshot: snapshot, utf8Offset: 0)
        XCTAssertEqual(highlights.count, 1)
        let foldingRanges = try await service.foldingRanges(snapshot: snapshot)
        XCTAssertEqual(foldingRanges.count, 1)
        let hints = try await service.inlayHints(snapshot: snapshot, utf8Range: 0..<snapshot.utf8Count)
        XCTAssertEqual(hints.count, 1)
        let items = try await service.prepareCallHierarchy(snapshot: snapshot, utf8Offset: 0)
        XCTAssertEqual(items.count, 1)
    }

    @MainActor
    func testExtendedCapabilitiesAreGatedOffWhenUnadvertisedForANonSwiftLanguageId() async throws {
        let (identity, store, root) = try makeTrustedIdentity()
        let service = try makeService(identity: identity, trustStore: store, scenario: "capability-absent")
        try await service.start()
        defer { Task { await service.stop() } }

        let fileURL = root.appendingPathComponent("Fake.ts")
        let snapshot = SourceSnapshot(text: "class Greeter {}\n", url: fileURL, version: 1)
        try await service.didOpen(snapshot)

        do {
            _ = try await service.declaration(snapshot: snapshot, utf8Offset: 0)
            XCTFail("Expected capabilityUnavailable")
        } catch LanguageWorkspaceServiceError.capabilityUnavailable {
            // expected: hidden, not an error surfaced to the user
        }
        do {
            _ = try await service.prepareCallHierarchy(snapshot: snapshot, utf8Offset: 0)
            XCTFail("Expected capabilityUnavailable")
        } catch LanguageWorkspaceServiceError.capabilityUnavailable {
            // expected
        }
    }

    @MainActor
    func testInvalidDocumentHighlightAndFoldingRangesAreDiscardedForANonSwiftLanguageId() async throws {
        let (identity, store, root) = try makeTrustedIdentity()
        let service = try makeService(identity: identity, trustStore: store, scenario: "invalid-range")
        try await service.start()
        defer { Task { await service.stop() } }

        let fileURL = root.appendingPathComponent("Fake.ts")
        let snapshot = SourceSnapshot(text: "class Greeter {}\n", url: fileURL, version: 1)
        try await service.didOpen(snapshot)

        let highlights = try await service.documentHighlights(snapshot: snapshot, utf8Offset: 0)
        XCTAssertTrue(highlights.isEmpty, "An out-of-bounds document highlight range must be filtered out")

        let foldingRanges = try await service.foldingRanges(snapshot: snapshot)
        XCTAssertTrue(foldingRanges.isEmpty, "A folding range past end-of-file must be filtered out")
    }

    @MainActor
    func testCrashLoopDisablesTheServiceAfterTheRestartBudgetForANonSwiftLanguageId() async throws {
        let (identity, store, _) = try makeTrustedIdentity()
        let states = LockedArray<LanguageServerState>()
        let dependencies = try makeDependencies(scenario: "crash-immediately")
        let service = LanguageWorkspaceService(
            identity: identity,
            trustStore: store,
            configuration: LanguageWorkspaceService.Configuration(languageId: "typescript"),
            dependencies: dependencies,
            onStateChange: { newState in
                states.append(newState)
            }
        )
        try await service.start()
        defer { Task { await service.stop() } }

        let deadline = Date().addingTimeInterval(5)
        func hasDisabled() -> Bool {
            states.snapshot().contains { if case .disabled = $0 { return true } else { return false } }
        }
        while !hasDisabled(), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(hasDisabled(), "Expected the crash-loop budget to eventually disable the service, got: \(states.snapshot())")
    }

    @MainActor
    func testInitializationFailureReportsStartingThenCrashed() async throws {
        let (identity, store, _) = try makeTrustedIdentity()
        let states = LockedArray<LanguageServerState>()
        let service = LanguageWorkspaceService(
            identity: identity,
            trustStore: store,
            configuration: LanguageWorkspaceService.Configuration(languageId: "typescript"),
            dependencies: try makeDependencies(scenario: "initialize-error"),
            onStateChange: { states.append($0) }
        )

        do {
            try await service.start()
            XCTFail("Expected initialization to fail")
        } catch {
            // expected
        }
        try await Task.sleep(for: .milliseconds(50))

        let observedStates = states.snapshot()
        XCTAssertEqual(observedStates.first, .starting)
        guard case .crashed(let reason)? = observedStates.last else {
            return XCTFail("Expected a crashed state, got \(observedStates)")
        }
        XCTAssertTrue(reason.contains("No compatible language runtime was found"))
    }

    @MainActor
    func testManualRestartFinishesInReadyRatherThanAStaleStoppedState() async throws {
        let (identity, store, _) = try makeTrustedIdentity()
        let states = LockedArray<LanguageServerState>()
        let service = LanguageWorkspaceService(
            identity: identity,
            trustStore: store,
            configuration: LanguageWorkspaceService.Configuration(languageId: "typescript"),
            dependencies: try makeDependencies(scenario: "normal"),
            onStateChange: { states.append($0) }
        )
        try await service.start()
        defer { Task { await service.stop() } }

        try await service.restart()
        try await Task.sleep(for: .milliseconds(100))

        let currentState = await service.currentState
        XCTAssertEqual(currentState, .ready)
        XCTAssertEqual(states.snapshot().last, .ready)
    }

    @MainActor
    func testRepositoryFilesAreNeverModifiedForANonSwiftLanguageId() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identity = try WorkspaceIdentity(root: root)
        let suiteName = "LanguageWorkspaceServiceFixtureTests.RepoImmutability.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = WorkspaceTrustStore(defaults: defaults)
        store.trust(identity)
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let fileURL = root.appendingPathComponent("Fake.ts")
        let originalContents = "class Greeter {}\n"
        try originalContents.write(to: fileURL, atomically: true, encoding: .utf8)
        let originalChecksum = try Data(contentsOf: fileURL)

        let service = try makeService(identity: identity, trustStore: store, scenario: "normal")
        try await service.start()
        defer { Task { await service.stop() } }

        let snapshot = try SourceSnapshotLoader().load(url: fileURL, version: 1)
        try await service.didOpen(snapshot)
        _ = try await service.hover(snapshot: snapshot, utf8Offset: 0)
        _ = try await service.declaration(snapshot: snapshot, utf8Offset: 0)
        _ = try await service.documentHighlights(snapshot: snapshot, utf8Offset: 0)
        _ = try await service.foldingRanges(snapshot: snapshot)
        _ = try await service.inlayHints(snapshot: snapshot, utf8Range: 0..<snapshot.utf8Count)
        _ = try await service.prepareCallHierarchy(snapshot: snapshot, utf8Offset: 0)

        let finalChecksum = try Data(contentsOf: fileURL)
        XCTAssertEqual(originalChecksum, finalChecksum, "Kod must never modify a workspace file via LSP operations")
    }

    @MainActor
    func testInteractiveHoverPreemptsAndAllowsReschedulingSemanticTokens() async throws {
        let (identity, store, root) = try makeTrustedIdentity()
        let stateFile = root.appendingPathComponent("priority-state")
        FileManager.default.createFile(atPath: stateFile.path, contents: Data())
        let service = try makeService(
            identity: identity,
            trustStore: store,
            scenario: "priority",
            environment: ["FAKE_LSP_STATE_FILE": stateFile.path]
        )
        try await service.start()
        defer { Task { await service.stop() } }
        let snapshot = SourceSnapshot(
            text: "class Greeter {}\n",
            url: root.appendingPathComponent("Fake.ts"),
            version: 1
        )
        try await service.didOpen(snapshot)

        let semanticTask = Task<[SemanticToken], Error> {
            try await service.semanticTokens(snapshot: snapshot)
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline,
              !((try? String(contentsOf: stateFile, encoding: .utf8)) ?? "")
                .contains("request:textDocument/semanticTokens/full") {
            try await Task.sleep(for: .milliseconds(10))
        }

        let declarations = try await service.declaration(snapshot: snapshot, utf8Offset: 0)
        XCTAssertEqual(declarations.count, 1)
        XCTAssertFalse(
            ((try? String(contentsOf: stateFile, encoding: .utf8)) ?? "").contains("cancel"),
            "Unrelated navigation commands must remain normal priority"
        )

        let hover = try await service.hover(snapshot: snapshot, utf8Offset: 0)
        XCTAssertEqual(hover?.contents.value, "Fake hover")
        do {
            _ = try await semanticTask.value
            XCTFail("Expected hover to preempt the background semantic-token request")
        } catch is CancellationError {
            // expected
        }

        let resumedTokens = try await service.semanticTokens(snapshot: snapshot)
        XCTAssertFalse(resumedTokens.isEmpty)
    }
}
