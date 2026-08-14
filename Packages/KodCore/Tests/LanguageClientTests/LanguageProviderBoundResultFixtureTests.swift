import Foundation
import SourceModel
import XCTest
@testable import LanguageClient

private actor ProviderResultValidationGate {
    private var armed = false
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func arm() {
        armed = true
        entered = false
    }

    func suspendWhenArmed() async {
        guard armed else {
            return
        }
        armed = false
        entered = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

/// Exercises provider binding end-to-end against the deterministic
/// `FakeLanguageServer` fixture: every cross-file result is stamped with
/// the producing provider, its connection generation, and that
/// connection's negotiated position encoding, and a follow-up request is
/// accepted only by that exact provider generation.
final class LanguageProviderBoundResultFixtureTests: XCTestCase {
    /// A fresh, isolated workspace root. Launch authorization is an
    /// injected capability now, so no trust store (and no `UserDefaults`
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

    private func makeService(
        workspaceRoot: URL,
        scenario: String,
        languageId: String,
        providerID: LanguageProviderID,
        providerResultValidationYield: @escaping @Sendable () async -> Void = {}
    ) throws -> LanguageWorkspaceService {
        let executableURL = try FakeLanguageServerLocator.executableURL()
        return LanguageWorkspaceService(
            workspaceRoot: workspaceRoot,
            authorization: .authorized,
            configuration: LanguageWorkspaceService.Configuration(languageId: languageId),
            dependencies: LanguageWorkspaceService.Dependencies(
                discoverExecutable: { executableURL },
                connectionFactory: { configuration, onStateChange, onNotification in
                    var configuration = configuration
                    configuration.arguments = [scenario]
                    return LanguageServerConnection(
                        configuration: configuration,
                        onStateChange: onStateChange,
                        onNotification: onNotification
                    )
                }
            ),
            providerID: providerID,
            diagnosticNormalizationYield: {},
            providerResultValidationYield: providerResultValidationYield
        )
    }

    /// Two providers for the same workspace can negotiate different
    /// position encodings. A cross-file target must be converted with the
    /// encoding of the provider that produced it — converting it with the
    /// target file's owner instead lands on the wrong bytes.
    @MainActor
    func testCrossProfileTargetsCarryTheirOwnProvidersNegotiatedEncoding() async throws {
        let root = try makeWorkspaceRoot()
        let swiftProviderID = LanguageProviderID(profileIdentifier: "swift")
        let typescriptProviderID = LanguageProviderID(profileIdentifier: "typescript")
        let utf8Service = try makeService(
            workspaceRoot: root,
            scenario: "normal",
            languageId: "swift",
            providerID: swiftProviderID
        )
        let utf16Service = try makeService(
            workspaceRoot: root,
            scenario: "normal-utf16",
            languageId: "typescript",
            providerID: typescriptProviderID
        )
        try await utf8Service.start()
        addTeardownBlock { await utf8Service.stop() }
        try await utf16Service.start()
        addTeardownBlock { await utf16Service.stop() }

        let swiftURL = root.appendingPathComponent("Greeter.swift")
        let swiftSnapshot = SourceSnapshot(text: "éabcd\n", url: swiftURL, version: 1)
        try await utf8Service.didOpen(swiftSnapshot)
        let typescriptURL = root.appendingPathComponent("greeter.ts")
        let typescriptSnapshot = SourceSnapshot(text: "éabcd\n", url: typescriptURL, version: 1)
        try await utf16Service.didOpen(typescriptSnapshot)

        let swiftTargets = try await utf8Service.definition(
            snapshot: swiftSnapshot,
            utf8Offset: 0
        )
        let swiftTarget = try XCTUnwrap(swiftTargets.first)
        let typescriptTargets = try await utf16Service.definition(
            snapshot: typescriptSnapshot,
            utf8Offset: 0
        )
        let typescriptTarget = try XCTUnwrap(typescriptTargets.first)

        XCTAssertEqual(swiftTarget.provider.providerID, swiftProviderID)
        XCTAssertEqual(swiftTarget.provider.positionEncoding, .utf8)
        XCTAssertEqual(typescriptTarget.provider.providerID, typescriptProviderID)
        XCTAssertEqual(typescriptTarget.provider.positionEncoding, .utf16)

        // Same wire range, same target text: only the originating
        // provider's encoding distinguishes them.
        XCTAssertEqual(swiftTarget.range, typescriptTarget.range)
        XCTAssertEqual(swiftTarget.location.utf8Range(in: typescriptSnapshot), 0..<4)
        XCTAssertEqual(
            typescriptTarget.location.utf8Range(in: typescriptSnapshot),
            0..<5
        )
    }

    @MainActor
    func testWorkspaceSymbolsAndHierarchyItemsAreBoundToTheProducingProvider() async throws {
        let root = try makeWorkspaceRoot()
        let providerID = LanguageProviderID(profileIdentifier: "typescript")
        let service = try makeService(
            workspaceRoot: root,
            scenario: "normal",
            languageId: "typescript",
            providerID: providerID
        )
        try await service.start()
        addTeardownBlock { await service.stop() }

        let snapshot = SourceSnapshot(
            text: "class Greeter {}\n",
            url: root.appendingPathComponent("Fake.ts"),
            version: 1
        )
        try await service.didOpen(snapshot)

        let binding = await service.currentProviderBinding()
        // The fake's workspace symbols deliberately fall outside the
        // workspace root, so the read-only workspace allow-list still
        // drops them — provider binding does not widen what is surfaced.
        let symbols = try await service.workspaceSymbols(query: "Greeter")
        XCTAssertTrue(symbols.isEmpty)
        for symbol in symbols {
            XCTAssertEqual(symbol.provider, binding)
        }
        let items = try await service.prepareCallHierarchy(snapshot: snapshot, utf8Offset: 0)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.provider, binding)
        XCTAssertEqual(item.provider.generation, binding.generation)
    }

    /// Normal same-provider behavior: a follow-up on the provider that
    /// produced the item succeeds and its results are bound to the same
    /// provider generation.
    @MainActor
    func testHierarchyFollowUpOnTheOriginatingProviderSucceeds() async throws {
        let root = try makeWorkspaceRoot()
        let providerID = LanguageProviderID(profileIdentifier: "typescript")
        let service = try makeService(
            workspaceRoot: root,
            scenario: "normal",
            languageId: "typescript",
            providerID: providerID
        )
        try await service.start()
        addTeardownBlock { await service.stop() }

        let snapshot = SourceSnapshot(
            text: "class Greeter {}\n",
            url: root.appendingPathComponent("Fake.ts"),
            version: 1
        )
        try await service.didOpen(snapshot)

        let preparedCalls = try await service.prepareCallHierarchy(
            snapshot: snapshot,
            utf8Offset: 0
        )
        let item = try XCTUnwrap(preparedCalls.first)
        let incoming = try await service.callHierarchyIncomingCalls(item: item)
        let outgoing = try await service.callHierarchyOutgoingCalls(item: item)
        XCTAssertEqual(incoming.first?.from.provider, item.provider)
        XCTAssertEqual(outgoing.first?.to.provider, item.provider)

        let preparedTypes = try await service.prepareTypeHierarchy(
            snapshot: snapshot,
            utf8Offset: 0
        )
        let typeItem = try XCTUnwrap(preparedTypes.first)
        let supertypes = try await service.typeHierarchySupertypes(item: typeItem)
        XCTAssertEqual(supertypes.first?.provider, typeItem.provider)
    }

    /// A handle produced before a restart names a server generation that
    /// no longer exists: its opaque `data` means nothing to the relaunched
    /// process, so the follow-up is rejected rather than sent.
    @MainActor
    func testHierarchyFollowUpIsRejectedAfterARestartChangesTheGeneration() async throws {
        let root = try makeWorkspaceRoot()
        let providerID = LanguageProviderID(profileIdentifier: "typescript")
        let service = try makeService(
            workspaceRoot: root,
            scenario: "normal",
            languageId: "typescript",
            providerID: providerID
        )
        try await service.start()
        addTeardownBlock { await service.stop() }

        let snapshot = SourceSnapshot(
            text: "class Greeter {}\n",
            url: root.appendingPathComponent("Fake.ts"),
            version: 1
        )
        try await service.didOpen(snapshot)
        let preparedItems = try await service.prepareCallHierarchy(
            snapshot: snapshot,
            utf8Offset: 0
        )
        let item = try XCTUnwrap(preparedItems.first)
        let staleGeneration = item.provider.generation

        try await service.restart()
        let currentGeneration = await service.currentGeneration
        XCTAssertNotEqual(staleGeneration, currentGeneration)

        do {
            _ = try await service.callHierarchyIncomingCalls(item: item)
            XCTFail("Expected a stale provider result error")
        } catch let error as LanguageProviderRoutingError {
            XCTAssertEqual(
                error,
                .staleProviderResult(
                    providerID: providerID,
                    resultGeneration: staleGeneration,
                    currentGeneration: currentGeneration
                )
            )
        }
        do {
            _ = try await service.typeHierarchySubtypes(item: item)
            XCTFail("Expected a stale provider result error")
        } catch let error as LanguageProviderRoutingError {
            guard case .staleProviderResult = error else {
                return XCTFail("Expected .staleProviderResult, got \(error)")
            }
        }
    }

    /// Opaque hierarchy data must never be handed to a different server,
    /// even one that happens to own the item's file.
    @MainActor
    func testHierarchyFollowUpIsRejectedByADifferentProvider() async throws {
        let root = try makeWorkspaceRoot()
        let producingID = LanguageProviderID(profileIdentifier: "swift")
        let otherID = LanguageProviderID(profileIdentifier: "typescript")
        let producing = try makeService(
            workspaceRoot: root,
            scenario: "normal",
            languageId: "swift",
            providerID: producingID
        )
        let other = try makeService(
            workspaceRoot: root,
            scenario: "normal",
            languageId: "typescript",
            providerID: otherID
        )
        try await producing.start()
        addTeardownBlock { await producing.stop() }
        try await other.start()
        addTeardownBlock { await other.stop() }

        let snapshot = SourceSnapshot(
            text: "class Greeter {}\n",
            url: root.appendingPathComponent("Fake.swift"),
            version: 1
        )
        try await producing.didOpen(snapshot)
        let preparedItems = try await producing.prepareCallHierarchy(
            snapshot: snapshot,
            utf8Offset: 0
        )
        let item = try XCTUnwrap(preparedItems.first)

        do {
            _ = try await other.callHierarchyIncomingCalls(item: item)
            XCTFail("Expected a provider mismatch error")
        } catch let error as LanguageProviderRoutingError {
            XCTAssertEqual(
                error,
                .providerMismatch(expected: otherID, actual: producingID)
            )
        }
    }

    @MainActor
    func testNavigationResultIsRejectedWhenProviderChangesBeforeBinding() async throws {
        let root = try makeWorkspaceRoot()
        let providerID = LanguageProviderID(profileIdentifier: "typescript")
        let gate = ProviderResultValidationGate()
        let service = try makeService(
            workspaceRoot: root,
            scenario: "normal",
            languageId: "typescript",
            providerID: providerID,
            providerResultValidationYield: { await gate.suspendWhenArmed() }
        )
        try await service.start()
        addTeardownBlock { await service.stop() }

        let snapshot = SourceSnapshot(
            text: "class Greeter {}\n",
            url: root.appendingPathComponent("NavigationRace.ts"),
            version: 1
        )
        try await service.didOpen(snapshot)
        let requestGeneration = await service.currentGeneration

        await gate.arm()
        let resultTask = Task {
            try await service.definition(snapshot: snapshot, utf8Offset: 0)
        }
        await gate.waitUntilEntered()
        await service.stop()
        let currentGeneration = await service.currentGeneration
        await gate.release()

        do {
            let targets = try await resultTask.value
            XCTFail(
                "Stale response returned \(targets.count) targets carrying generation "
                    + "\(targets.first?.provider.generation.description ?? "none")"
            )
        } catch let error as LanguageProviderRoutingError {
            XCTAssertEqual(
                error,
                .staleProviderResult(
                    providerID: providerID,
                    resultGeneration: requestGeneration,
                    currentGeneration: currentGeneration
                )
            )
        }
    }

    @MainActor
    func testHierarchyFollowUpResultIsRejectedWhenProviderChangesWhileAwaited() async throws {
        let root = try makeWorkspaceRoot()
        let providerID = LanguageProviderID(profileIdentifier: "typescript")
        let gate = ProviderResultValidationGate()
        let service = try makeService(
            workspaceRoot: root,
            scenario: "normal",
            languageId: "typescript",
            providerID: providerID,
            providerResultValidationYield: { await gate.suspendWhenArmed() }
        )
        try await service.start()
        addTeardownBlock { await service.stop() }

        let snapshot = SourceSnapshot(
            text: "class Greeter {}\n",
            url: root.appendingPathComponent("HierarchyRace.ts"),
            version: 1
        )
        try await service.didOpen(snapshot)
        let preparedItems = try await service.prepareCallHierarchy(
            snapshot: snapshot,
            utf8Offset: 0
        )
        let item = try XCTUnwrap(preparedItems.first)

        await gate.arm()
        let resultTask = Task {
            try await service.callHierarchyIncomingCalls(item: item)
        }
        await gate.waitUntilEntered()
        await service.stop()
        let currentGeneration = await service.currentGeneration
        await gate.release()

        do {
            let calls = try await resultTask.value
            XCTFail(
                "Stale follow-up returned \(calls.count) calls carrying generation "
                    + "\(calls.first?.provider.generation.description ?? "none")"
            )
        } catch let error as LanguageProviderRoutingError {
            XCTAssertEqual(
                error,
                .staleProviderResult(
                    providerID: providerID,
                    resultGeneration: item.provider.generation,
                    currentGeneration: currentGeneration
                )
            )
        }
    }
}
