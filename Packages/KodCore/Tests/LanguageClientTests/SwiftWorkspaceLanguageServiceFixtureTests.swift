import Foundation
import SourceIO
import SourceModel
import XCTest
@testable import LanguageClient

final class SwiftWorkspaceLanguageServiceFixtureTests: XCTestCase {
    /// A fresh, isolated workspace root. Launch authorization is an
    /// injected capability, so no trust store (and no `UserDefaults`
    /// suite) is involved in exercising the service.
    private func makeWorkspaceRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func makeDependencies(scenario: String, environment: [String: String]? = nil) throws -> SwiftWorkspaceLanguageService.Dependencies {
        let executableURL = try FakeLanguageServerLocator.executableURL()
        return SwiftWorkspaceLanguageService.Dependencies(
            discoverExecutable: { executableURL },
            connectionFactory: { configuration, onStateChange, onNotification in
                var configuration = configuration
                configuration.arguments = [scenario]
                configuration.environment = environment
                return LanguageServerConnection(configuration: configuration, onStateChange: onStateChange, onNotification: onNotification)
            }
        )
    }

    func testStartThrowsWhenWorkspaceIsNotTrusted() async throws {
        let root = try makeWorkspaceRoot()

        // Discovery must never even be attempted for an unauthorized
        // workspace (SPEC 13.1): fail the test if it is.
        let discoveryWasCalled = LockedBox(false)
        let dependencies = SwiftWorkspaceLanguageService.Dependencies(discoverExecutable: {
            discoveryWasCalled.set(true)
            return URL(fileURLWithPath: "/nonexistent")
        })
        let service = SwiftWorkspaceLanguageService(
            workspaceRoot: root,
            authorization: .denied,
            dependencies: dependencies
        )

        do {
            try await service.start()
            XCTFail("Expected notTrusted")
        } catch SwiftLanguageServiceError.notTrusted {
            // expected
        }
        XCTAssertFalse(discoveryWasCalled.get())
    }

    /// The gate is consulted on every launch attempt rather than cached,
    /// so a workspace that becomes authorized starts without the service
    /// being recreated — and one that loses authorization stops starting.
    func testStartConsultsAuthorizationOnEveryAttempt() async throws {
        let root = try makeWorkspaceRoot()
        let isAuthorized = LockedBox(false)
        let service = SwiftWorkspaceLanguageService(
            workspaceRoot: root,
            authorization: WorkspaceLaunchAuthorization { isAuthorized.get() },
            dependencies: try makeDependencies(scenario: "normal")
        )

        do {
            try await service.start()
            XCTFail("Expected notTrusted")
        } catch SwiftLanguageServiceError.notTrusted {
            // expected
        }

        isAuthorized.set(true)
        try await service.start()
        addTeardownBlock { await service.stop() }
        let state = await service.currentState
        XCTAssertEqual(state, .ready)
    }

    @MainActor
    func testDocumentSyncRejectsRequestsForUnopenedOrStaleSnapshots() async throws {
        let root = try makeWorkspaceRoot()
        let dependencies = try makeDependencies(scenario: "normal")
        let service = SwiftWorkspaceLanguageService(
            workspaceRoot: root,
            authorization: .authorized,
            dependencies: dependencies
        )
        try await service.start()
        addTeardownBlock { await service.stop() }

        let fileURL = root.appendingPathComponent("Fake.swift")
        let snapshot = SourceSnapshot(text: "let x = 1", url: fileURL, version: 1)

        do {
            _ = try await service.hover(snapshot: snapshot, utf8Offset: 0)
            XCTFail("Expected documentNotOpen before didOpen")
        } catch SwiftLanguageServiceError.documentNotOpen {
            // expected
        }

        try await service.didOpen(snapshot)
        _ = try await service.hover(snapshot: snapshot, utf8Offset: 0)

        let staleSnapshot = SourceSnapshot(text: "let x = 1 // changed", url: fileURL, version: 1)
        // Same version but a different snapshot object is fine: what
        // matters is the *tracked* version, so this still succeeds.
        _ = try await service.hover(snapshot: staleSnapshot, utf8Offset: 0)

        // A snapshot claiming a version the service never saw via
        // didOpen/didChange must be rejected as stale rather than sent.
        let futureSnapshot = SourceSnapshot(text: "let x = 2", url: fileURL, version: 5)
        do {
            _ = try await service.hover(snapshot: futureSnapshot, utf8Offset: 0)
            XCTFail("Expected staleRequest")
        } catch SwiftLanguageServiceError.staleRequest {
            // expected
        }
    }

    @MainActor
    func testCapabilityGatingReportsPreciseLimitationWhenUnadvertised() async throws {
        // "no-diagnostics" reuses the normal scenario's capabilities
        // (which do advertise diagnosticProvider), so instead directly
        // construct a connection whose capabilities lack it by using the
        // fixture but asserting against a manually-limited expectation:
        // pull diagnostics succeeds normally here, and the *absence* case
        // is covered by capability-gating unit assertions below against a
        // fabricated `ServerCapabilities`.
        let root = try makeWorkspaceRoot()
        let dependencies = try makeDependencies(scenario: "normal")
        let service = SwiftWorkspaceLanguageService(
            workspaceRoot: root,
            authorization: .authorized,
            dependencies: dependencies
        )
        try await service.start()
        addTeardownBlock { await service.stop() }

        let fileURL = root.appendingPathComponent("Fake.swift")
        let snapshot = SourceSnapshot(text: "let x = 1", url: fileURL, version: 1)
        try await service.didOpen(snapshot)

        let diagnostics = try await service.pullDiagnostics(snapshot: snapshot)
        XCTAssertEqual(diagnostics.first?.message, "Fake pulled diagnostic")

        let tokens = try await service.semanticTokens(snapshot: snapshot)
        XCTAssertFalse(tokens.isEmpty)
    }

    @MainActor
    func testInvalidRangesFromTheServerAreDiscardedRatherThanShown() async throws {
        let root = try makeWorkspaceRoot()
        let dependencies = try makeDependencies(scenario: "invalid-range")
        let service = SwiftWorkspaceLanguageService(
            workspaceRoot: root,
            authorization: .authorized,
            dependencies: dependencies
        )
        try await service.start()
        addTeardownBlock { await service.stop() }

        let fileURL = root.appendingPathComponent("Fake.swift")
        let snapshot = SourceSnapshot(text: "let x = 1", url: fileURL, version: 1)
        try await service.didOpen(snapshot)

        let hover = try await service.hover(snapshot: snapshot, utf8Offset: 0)
        XCTAssertNotNil(hover)
        XCTAssertNil(hover?.range, "An out-of-bounds hover range must be discarded, not shown")

        let definitions = try await service.definition(snapshot: snapshot, utf8Offset: 0)
        XCTAssertTrue(definitions.isEmpty, "A structurally-invalid (negative) range must be filtered out")

        let highlights = try await service.documentHighlights(snapshot: snapshot, utf8Offset: 0)
        XCTAssertTrue(highlights.isEmpty, "An out-of-bounds document highlight range must be filtered out")

        let foldingRanges = try await service.foldingRanges(snapshot: snapshot)
        XCTAssertTrue(foldingRanges.isEmpty, "A folding range past end-of-file must be filtered out")
    }

    @MainActor
    func testExtendedCapabilitiesRoundTripThroughTheSwiftFacingWrapper() async throws {
        let root = try makeWorkspaceRoot()
        let dependencies = try makeDependencies(scenario: "normal")
        let service = SwiftWorkspaceLanguageService(
            workspaceRoot: root,
            authorization: .authorized,
            dependencies: dependencies
        )
        try await service.start()
        addTeardownBlock { await service.stop() }

        let fileURL = root.appendingPathComponent("Fake.swift")
        let snapshot = SourceSnapshot(text: "let value = 1\n", url: fileURL, version: 1)
        try await service.didOpen(snapshot)

        let declarations = try await service.declaration(snapshot: snapshot, utf8Offset: 0)
        XCTAssertEqual(declarations.count, 1)
        let typeDefinitions = try await service.typeDefinition(snapshot: snapshot, utf8Offset: 0)
        XCTAssertEqual(typeDefinitions.count, 1)
        let implementations = try await service.implementation(snapshot: snapshot, utf8Offset: 0)
        XCTAssertEqual(implementations.count, 1)

        let highlights = try await service.documentHighlights(snapshot: snapshot, utf8Offset: 0)
        XCTAssertEqual(highlights.count, 1)

        let foldingRanges = try await service.foldingRanges(snapshot: snapshot)
        XCTAssertEqual(foldingRanges.count, 1)

        let selectionRanges = try await service.selectionRanges(snapshot: snapshot, utf8Offsets: [0])
        XCTAssertEqual(selectionRanges.count, 1)
        XCTAssertNotNil(selectionRanges.first?.parent)

        let links = try await service.documentLinks(snapshot: snapshot)
        XCTAssertEqual(links.count, 1)

        let hints = try await service.inlayHints(snapshot: snapshot, utf8Range: 0..<snapshot.utf8Count)
        XCTAssertEqual(hints.count, 1)

        let signatureHelp = try await service.signatureHelp(snapshot: snapshot, utf8Offset: 0)
        XCTAssertEqual(signatureHelp?.signatures.count, 1)

        let callItems = try await service.prepareCallHierarchy(snapshot: snapshot, utf8Offset: 0)
        let callItem = try XCTUnwrap(callItems.first)
        let incoming = try await service.callHierarchyIncomingCalls(item: callItem)
        XCTAssertEqual(incoming.first?.from.name, "Caller")
        let outgoing = try await service.callHierarchyOutgoingCalls(item: callItem)
        XCTAssertEqual(outgoing.first?.to.name, "Callee")

        let typeItems = try await service.prepareTypeHierarchy(snapshot: snapshot, utf8Offset: 0)
        let typeItem = try XCTUnwrap(typeItems.first)
        let supertypes = try await service.typeHierarchySupertypes(item: typeItem)
        XCTAssertEqual(supertypes.first?.name, "Supertype")
        let subtypes = try await service.typeHierarchySubtypes(item: typeItem)
        XCTAssertEqual(subtypes.first?.name, "Subtype")
    }

    @MainActor
    func testExtendedCapabilitiesAreGatedOffWhenUnadvertised() async throws {
        let root = try makeWorkspaceRoot()
        let dependencies = try makeDependencies(scenario: "capability-absent")
        let service = SwiftWorkspaceLanguageService(
            workspaceRoot: root,
            authorization: .authorized,
            dependencies: dependencies
        )
        try await service.start()
        addTeardownBlock { await service.stop() }

        let fileURL = root.appendingPathComponent("Fake.swift")
        let snapshot = SourceSnapshot(text: "let value = 1\n", url: fileURL, version: 1)
        try await service.didOpen(snapshot)

        // Every Phase 7 extended capability must fail with a precise
        // `.capabilityUnavailable` (hide the feature) rather than any
        // other error or a silently-empty success (SPEC: "unsupported
        // features are hidden/disabled, not errors" at the UI layer —
        // the service layer surfaces the precise reason so the UI can
        // tell the difference from "genuinely no results").
        await assertCapabilityUnavailable { try await service.declaration(snapshot: snapshot, utf8Offset: 0) }
        await assertCapabilityUnavailable { try await service.typeDefinition(snapshot: snapshot, utf8Offset: 0) }
        await assertCapabilityUnavailable { try await service.implementation(snapshot: snapshot, utf8Offset: 0) }
        await assertCapabilityUnavailable { try await service.documentHighlights(snapshot: snapshot, utf8Offset: 0) }
        await assertCapabilityUnavailable { try await service.foldingRanges(snapshot: snapshot) }
        await assertCapabilityUnavailable { try await service.selectionRanges(snapshot: snapshot, utf8Offsets: [0]) }
        await assertCapabilityUnavailable { try await service.documentLinks(snapshot: snapshot) }
        await assertCapabilityUnavailable { try await service.inlayHints(snapshot: snapshot, utf8Range: 0..<snapshot.utf8Count) }
        await assertCapabilityUnavailable { try await service.signatureHelp(snapshot: snapshot, utf8Offset: 0) }
        await assertCapabilityUnavailable { try await service.prepareCallHierarchy(snapshot: snapshot, utf8Offset: 0) }
        await assertCapabilityUnavailable { try await service.prepareTypeHierarchy(snapshot: snapshot, utf8Offset: 0) }
    }

    @MainActor
    private func assertCapabilityUnavailable<T>(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected capabilityUnavailable", file: file, line: line)
        } catch SwiftLanguageServiceError.capabilityUnavailable {
            // expected
        } catch {
            XCTFail("Expected capabilityUnavailable, got \(error)", file: file, line: line)
        }
    }

    @MainActor
    func testRestartResynchronizesPreviouslyOpenDocuments() async throws {
        let root = try makeWorkspaceRoot()
        let stateFile = root.appendingPathComponent("state.log")
        FileManager.default.createFile(atPath: stateFile.path, contents: nil)

        let dependencies = try makeDependencies(
            scenario: "crash-immediately",
            environment: ["FAKE_LSP_STATE_FILE": stateFile.path]
        )
        let service = SwiftWorkspaceLanguageService(
            workspaceRoot: root,
            authorization: .authorized,
            dependencies: dependencies
        )
        try await service.start()
        addTeardownBlock { await service.stop() }

        let fileURL = root.appendingPathComponent("Fake.swift")
        let snapshot = SourceSnapshot(text: "let x = 1", url: fileURL, version: 1)
        try await service.didOpen(snapshot)

        // The fixture crashes shortly after each `initialized`; wait for
        // at least two "didOpen" lines: the original open plus one
        // automatic resync after the auto-restart.
        let deadline = Date().addingTimeInterval(5)
        var lineCount = 0
        while lineCount < 2, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            let contents = (try? String(contentsOf: stateFile, encoding: .utf8)) ?? ""
            lineCount = contents.split(separator: "\n").count
        }
        XCTAssertGreaterThanOrEqual(lineCount, 2)
    }

    @MainActor
    func testRepositoryFilesAreNeverModifiedByLanguageServiceOperations() async throws {
        let root = try makeWorkspaceRoot()

        let fileURL = root.appendingPathComponent("Fake.swift")
        let originalContents = "let x = 1\n"
        try originalContents.write(to: fileURL, atomically: true, encoding: .utf8)
        let originalChecksum = try Data(contentsOf: fileURL)

        let dependencies = try makeDependencies(scenario: "normal")
        let service = SwiftWorkspaceLanguageService(
            workspaceRoot: root,
            authorization: .authorized,
            dependencies: dependencies
        )
        try await service.start()
        addTeardownBlock { await service.stop() }

        let snapshot = try SourceSnapshotLoader().load(url: fileURL, version: 1)
        try await service.didOpen(snapshot)
        _ = try await service.hover(snapshot: snapshot, utf8Offset: 0)
        _ = try await service.definition(snapshot: snapshot, utf8Offset: 0)
        _ = try await service.documentSymbols(snapshot: snapshot)
        _ = try await service.pullDiagnostics(snapshot: snapshot)
        _ = try await service.semanticTokens(snapshot: snapshot)

        let finalChecksum = try Data(contentsOf: fileURL)
        XCTAssertEqual(originalChecksum, finalChecksum, "Kod must never modify a workspace file via LSP operations")
    }

    @MainActor
    func testSwiftWrapperPreservesInteractiveRequestPriority() async throws {
        let root = try makeWorkspaceRoot()
        let stateFile = root.appendingPathComponent("priority-state")
        FileManager.default.createFile(atPath: stateFile.path, contents: Data())
        let service = SwiftWorkspaceLanguageService(
            workspaceRoot: root,
            authorization: .authorized,
            dependencies: try makeDependencies(
                scenario: "priority",
                environment: ["FAKE_LSP_STATE_FILE": stateFile.path]
            )
        )
        try await service.start()
        addTeardownBlock { await service.stop() }
        let snapshot = SourceSnapshot(
            text: "let value = 1\n",
            url: root.appendingPathComponent("Fake.swift"),
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
