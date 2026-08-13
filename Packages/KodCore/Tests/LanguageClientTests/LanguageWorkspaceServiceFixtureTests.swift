import Foundation
import SourceModel
import WorkspaceCore
import XCTest
@testable import LanguageClient

private actor DiagnosticNormalizationGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
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

private actor FirstDiagnosticNormalizationGate {
    private var callCount = 0
    private var firstEntered = false
    private var firstContinuation: CheckedContinuation<Void, Never>?

    func suspendFirst() async {
        callCount += 1
        guard callCount == 1 else {
            return
        }
        firstEntered = true
        await withCheckedContinuation { continuation in
            firstContinuation = continuation
        }
    }

    func waitUntilFirstEntered() async {
        while !firstEntered {
            await Task.yield()
        }
    }

    func releaseFirst() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

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
    func testPublishedDiagnosticsNormalizeNegotiatedUTF8RangesAndClearOnClose() async throws {
        let (identity, store, root) = try makeTrustedIdentity()
        let received = LockedArray<[NormalizedDiagnostic]>()
        let raw = LockedArray<[Diagnostic]>()
        let service = LanguageWorkspaceService(
            identity: identity,
            trustStore: store,
            configuration: LanguageWorkspaceService.Configuration(languageId: "typescript"),
            dependencies: try makeDependencies(scenario: "normal"),
            onDiagnostics: { _, diagnostics in
                raw.append(diagnostics)
            },
            onNormalizedDiagnostics: { _, diagnostics in
                received.append(diagnostics)
            }
        )
        try await service.start()
        defer { Task { await service.stop() } }

        let snapshot = SourceSnapshot(
            text: "éabc\n",
            url: root.appendingPathComponent("UTF8.ts"),
            version: 42
        )
        try await service.didOpen(snapshot)

        let deadline = Date().addingTimeInterval(2)
        while received.snapshot().allSatisfy(\.isEmpty), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let diagnostic = try XCTUnwrap(received.snapshot().first(where: { !$0.isEmpty })?.first)
        XCTAssertEqual(diagnostic.snapshotVersion, 42)
        XCTAssertEqual(diagnostic.utf8Range, 0..<4)
        XCTAssertEqual(try snapshot.text(inUTF8Range: diagnostic.utf8Range), "éab")
        XCTAssertEqual(diagnostic.severity, .warning)

        // The same report reaches the raw workspace-wide callback in wire
        // form, so unopened files and the Problems list stay consistent.
        let rawDiagnostic = try XCTUnwrap(raw.snapshot().first(where: { !$0.isEmpty })?.first)
        XCTAssertEqual(rawDiagnostic.message, diagnostic.message)
        XCTAssertEqual(rawDiagnostic.range.start.character, 0)
        XCTAssertEqual(rawDiagnostic.range.end.character, 4)

        let rawCountBeforeClose = raw.snapshot().count
        try await service.didClose(url: snapshot.url)
        XCTAssertTrue(received.snapshot().last?.isEmpty == true)
        XCTAssertEqual(
            raw.snapshot().count,
            rawCountBeforeClose,
            "Closing a document clears editor markers only; workspace problems survive"
        )
    }

    @MainActor
    func testSynchronizeDistinguishesOpenUnchangedAndReloadedSnapshots() async throws {
        let (identity, store, root) = try makeTrustedIdentity()
        let received = LockedArray<[NormalizedDiagnostic]>()
        let service = LanguageWorkspaceService(
            identity: identity,
            trustStore: store,
            configuration: LanguageWorkspaceService.Configuration(languageId: "typescript"),
            dependencies: try makeDependencies(scenario: "no-diagnostics"),
            onNormalizedDiagnostics: { _, diagnostics in
                received.append(diagnostics)
            }
        )
        try await service.start()
        defer { Task { await service.stop() } }

        let url = root.appendingPathComponent("Reloaded.ts")
        let initial = SourceSnapshot(text: "old\n", url: url, version: 1)
        let opened = try await service.synchronize(initial)
        XCTAssertEqual(opened, .opened)
        let unchanged = try await service.synchronize(initial)
        XCTAssertEqual(unchanged, .unchanged)
        let diagnostic = Diagnostic(
            range: LSPRange(
                start: LSPPosition(line: 0, character: 0),
                end: LSPPosition(line: 0, character: 3)
            ),
            severity: .warning,
            code: nil,
            source: nil,
            message: "Stored"
        )
        let initiallyStored = await service.normalizedStoredDiagnostics(
            [diagnostic],
            for: initial
        )
        XCTAssertEqual(initiallyStored?.first?.utf8Range, 0..<3)

        let reloaded = SourceSnapshot(text: "new\n", url: url, version: 2)
        let changed = try await service.synchronize(reloaded)
        XCTAssertEqual(changed, .changed)
        let unchangedAfterReload = try await service.synchronize(reloaded)
        XCTAssertEqual(unchangedAfterReload, .unchanged)
        let staleStored = await service.normalizedStoredDiagnostics(
            [diagnostic],
            for: reloaded
        )
        XCTAssertNil(
            staleStored,
            "A second editor must not re-stamp pre-reload diagnostics onto the new snapshot"
        )
        XCTAssertTrue(
            received.snapshot().last?.isEmpty == true,
            "Changing snapshots must clear normalized markers until the server republishes"
        )
    }

    @MainActor
    func testMalformedPublishedDiagnosticDoesNotKeepPreviousFileStateStale() async throws {
        let (identity, store, root) = try makeTrustedIdentity()
        let received = LockedArray<[NormalizedDiagnostic]>()
        let raw = LockedArray<[Diagnostic]>()
        let service = LanguageWorkspaceService(
            identity: identity,
            trustStore: store,
            configuration: LanguageWorkspaceService.Configuration(languageId: "typescript"),
            dependencies: try makeDependencies(scenario: "invalid-publish"),
            onDiagnostics: { _, diagnostics in raw.append(diagnostics) },
            onNormalizedDiagnostics: { _, diagnostics in received.append(diagnostics) }
        )
        try await service.start()
        defer { Task { await service.stop() } }

        let snapshot = SourceSnapshot(
            text: "valid\n",
            url: root.appendingPathComponent("InvalidPublish.ts"),
            version: 1
        )
        try await service.didOpen(snapshot)
        let deadline = Date().addingTimeInterval(2)
        while received.snapshot().allSatisfy(\.isEmpty), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        let diagnostics = try XCTUnwrap(received.snapshot().first(where: { !$0.isEmpty }))
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics.first?.message, "Fake published diagnostic")
        XCTAssertEqual(diagnostics.first?.utf8Range, 0..<4)

        // The out-of-bounds range is dropped from editor markers only:
        // the raw workspace report is forwarded exactly as published.
        let rawDiagnostics = try XCTUnwrap(raw.snapshot().first(where: { !$0.isEmpty }))
        XCTAssertEqual(rawDiagnostics.count, 2)
        XCTAssertEqual(rawDiagnostics.first?.message, "Invalid diagnostic")
    }

    @MainActor
    func testDidCloseWhileDiagnosticNormalizationIsSuspendedCannotResurrectDiagnostics() async throws {
        let (identity, store, root) = try makeTrustedIdentity()
        let gate = DiagnosticNormalizationGate()
        let received = LockedArray<[NormalizedDiagnostic]>()
        let service = LanguageWorkspaceService(
            identity: identity,
            trustStore: store,
            configuration: LanguageWorkspaceService.Configuration(languageId: "typescript"),
            dependencies: try makeDependencies(scenario: "normal"),
            onStateChange: { _ in },
            onNormalizedDiagnostics: { _, diagnostics in received.append(diagnostics) },
            diagnosticNormalizationYield: { await gate.suspend() }
        )
        try await service.start()
        defer { Task { await service.stop() } }

        let snapshot = SourceSnapshot(
            text: "value\n",
            url: root.appendingPathComponent("DiagnosticRace.ts"),
            version: 7
        )
        try await service.didOpen(snapshot)
        await gate.waitUntilEntered()
        try await service.didClose(url: snapshot.url)
        await gate.release()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(received.snapshot().isEmpty)
        XCTAssertTrue(received.snapshot().allSatisfy(\.isEmpty))
    }

    @MainActor
    func testNewerSameVersionDiagnosticPublishWinsWhenOlderNormalizationResumesLast() async throws {
        let (identity, store, root) = try makeTrustedIdentity()
        let gate = FirstDiagnosticNormalizationGate()
        let received = LockedArray<[NormalizedDiagnostic]>()
        let service = LanguageWorkspaceService(
            identity: identity,
            trustStore: store,
            configuration: LanguageWorkspaceService.Configuration(languageId: "typescript"),
            dependencies: try makeDependencies(scenario: "no-diagnostics"),
            onStateChange: { _ in },
            onNormalizedDiagnostics: { _, diagnostics in received.append(diagnostics) },
            diagnosticNormalizationYield: { await gate.suspendFirst() }
        )
        try await service.start()
        defer { Task { await service.stop() } }
        let snapshot = SourceSnapshot(
            text: "value\n",
            url: root.appendingPathComponent("DiagnosticOrder.ts"),
            version: 12
        )
        try await service.didOpen(snapshot)

        func notification(_ diagnostics: [Diagnostic]) -> ServerNotification {
            .publishDiagnostics(PublishDiagnosticsParams(
                uri: DocumentURI(fileURL: snapshot.url),
                version: snapshot.version,
                diagnostics: diagnostics
            ))
        }
        let older = Task {
            await service.handleServerNotificationForTesting(notification([
                Diagnostic(
                    range: LSPRange(
                        start: LSPPosition(line: 0, character: 0),
                        end: LSPPosition(line: 0, character: 5)
                    ),
                    severity: .warning,
                    code: nil,
                    source: nil,
                    message: "Older"
                )
            ]))
        }
        await gate.waitUntilFirstEntered()
        await service.handleServerNotificationForTesting(notification([]))
        await gate.releaseFirst()
        await older.value

        XCTAssertEqual(received.snapshot().count, 1)
        XCTAssertTrue(received.snapshot().first?.isEmpty == true)
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

    @MainActor
    func testAcceptsUnopenedWorkspacePushAndRejectsOutsideAndNonFilePushes() async throws {
        let (identity, store, root) = try makeTrustedIdentity()
        let messages = LockedArray<String>()
        let normalizedURLs = LockedArray<URL>()
        let service = LanguageWorkspaceService(
            identity: identity,
            trustStore: store,
            configuration: LanguageWorkspaceService.Configuration(languageId: "swift"),
            dependencies: try makeDependencies(scenario: "workspace-push"),
            onDiagnostics: { _, diagnostics in
                for diagnostic in diagnostics {
                    messages.append(diagnostic.message)
                }
            },
            onNormalizedDiagnostics: { url, _ in normalizedURLs.append(url) }
        )
        try await service.start()
        defer { Task { await service.stop() } }

        let deadline = ContinuousClock.now + .seconds(3)
        while messages.snapshot().isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(messages.snapshot(), ["Unopened workspace diagnostic"])
        XCTAssertTrue(
            normalizedURLs.snapshot().isEmpty,
            "A file Kod has never opened has no snapshot to normalize against"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Unopened.swift").path))
    }

    /// The shared conversion helper Problems/definition navigation uses
    /// must honor the negotiated position encoding instead of assuming
    /// UTF-16: the same wire range resolves to different UTF-8 byte
    /// ranges under the two encodings.
    @MainActor
    func testNegotiatedRangeConversionUsesTheServerPositionEncoding() async throws {
        let (identity, store, root) = try makeTrustedIdentity()
        let snapshot = SourceSnapshot(
            text: "lét value\n",
            url: root.appendingPathComponent("Encoding.ts"),
            version: 1
        )
        let range = LSPRange(
            start: LSPPosition(line: 0, character: 0),
            end: LSPPosition(line: 0, character: 4)
        )

        let utf8Service = try makeService(identity: identity, trustStore: store, scenario: "normal")
        try await utf8Service.start()
        defer { Task { await utf8Service.stop() } }
        let utf8Range = await utf8Service.utf8Range(for: range, in: snapshot)
        XCTAssertEqual(utf8Range, 0..<4)
        XCTAssertEqual(try snapshot.text(inUTF8Range: try XCTUnwrap(utf8Range)), "lét")

        let utf16Service = try makeService(identity: identity, trustStore: store, scenario: "normal-utf16")
        try await utf16Service.start()
        defer { Task { await utf16Service.stop() } }
        let utf16Range = await utf16Service.utf8Range(for: range, in: snapshot)
        XCTAssertEqual(utf16Range, 0..<5)

        // Converting an arbitrary snapshot never adopts it as live state.
        let unopened = await utf8Service.normalizedDiagnostics(
            [Diagnostic(range: range, severity: .error, code: nil, source: nil, message: "Converted")],
            for: snapshot
        )
        XCTAssertEqual(unopened.first?.utf8Range, 0..<4)
        XCTAssertEqual(unopened.first?.snapshotVersion, 1)
        do {
            _ = try await utf8Service.documentSymbols(snapshot: snapshot)
            XCTFail("Converting a range must not register the snapshot as open")
        } catch LanguageWorkspaceServiceError.documentNotOpen {
            // Expected.
        }
    }

    @MainActor
    func testWorkspaceDiagnosticsAreCapabilityGated() async throws {
        let (identity, store, root) = try makeTrustedIdentity()
        let stateFile = root.appendingPathComponent("workspace-diagnostics-state")
        FileManager.default.createFile(atPath: stateFile.path, contents: Data())
        let service = try makeService(
            identity: identity,
            trustStore: store,
            scenario: "normal",
            environment: ["FAKE_LSP_STATE_FILE": stateFile.path]
        )
        try await service.start()
        defer { Task { await service.stop() } }
        try await Task.sleep(for: .milliseconds(200))

        let state = try String(contentsOf: stateFile, encoding: .utf8)
        XCTAssertFalse(state.contains("request:workspace/diagnostic"))
    }

    @MainActor
    func testWorkspaceDiagnosticsFullUnchangedResultIDsAndRefreshCoalescing() async throws {
        let (identity, store, root) = try makeTrustedIdentity()
        let stateFile = root.appendingPathComponent("workspace-diagnostics-state")
        FileManager.default.createFile(atPath: stateFile.path, contents: Data())
        let messages = LockedArray<String>()
        let service = LanguageWorkspaceService(
            identity: identity,
            trustStore: store,
            configuration: LanguageWorkspaceService.Configuration(languageId: "swift"),
            dependencies: try makeDependencies(
                scenario: "workspace-diagnostics-refresh",
                environment: ["FAKE_LSP_STATE_FILE": stateFile.path]
            ),
            onDiagnostics: { _, diagnostics in
                for diagnostic in diagnostics {
                    messages.append(diagnostic.message)
                }
            }
        )
        try await service.start()
        defer { Task { await service.stop() } }

        let deadline = ContinuousClock.now + .seconds(3)
        var state = ""
        while ContinuousClock.now < deadline {
            state = try String(contentsOf: stateFile, encoding: .utf8)
            if state.contains("workspaceDiagnostic:2"),
               state.contains("workspacePreviousResult:accepted") {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(200))
        state = try String(contentsOf: stateFile, encoding: .utf8)

        XCTAssertTrue(state.contains("workspaceRefreshSupport"), "Got:\n\(state)")
        XCTAssertTrue(state.contains("workspaceDiagnostic:2"), "Got:\n\(state)")
        XCTAssertFalse(state.contains("workspaceDiagnostic:3"), "Refresh requests should coalesce. Got:\n\(state)")
        XCTAssertTrue(state.contains("workspacePreviousResult:accepted"), "Got:\n\(state)")
        XCTAssertEqual(
            messages.snapshot(),
            ["Workspace pulled diagnostic"],
            "An unchanged report must preserve the full report without republishing or clearing it"
        )
    }

    @MainActor
    func testWorkspacePullDiagnosticsForAnOpenDocumentAlsoProduceNormalizedMarkers() async throws {
        let (identity, store, root) = try makeTrustedIdentity()
        let messages = LockedArray<String>()
        let normalized = LockedArray<[NormalizedDiagnostic]>()
        let service = LanguageWorkspaceService(
            identity: identity,
            trustStore: store,
            configuration: LanguageWorkspaceService.Configuration(languageId: "swift"),
            dependencies: try makeDependencies(scenario: "workspace-diagnostics-slow"),
            onDiagnostics: { _, diagnostics in
                for diagnostic in diagnostics {
                    messages.append(diagnostic.message)
                }
            },
            onNormalizedDiagnostics: { _, diagnostics in normalized.append(diagnostics) }
        )
        try await service.start()
        defer { Task { await service.stop() } }

        // "lét" is 4 UTF-8 bytes but 3 UTF-16 code units, so a report of
        // characters 0..<4 on line 1 can only normalize to 14..<18 when
        // the negotiated UTF-8 encoding is honored.
        let snapshot = SourceSnapshot(
            text: "let first = 1\nlét value = 2\n",
            url: root.appendingPathComponent("WorkspaceOnly.swift"),
            version: 5
        )
        try await service.didOpen(snapshot)

        func pulled(_ batches: [[NormalizedDiagnostic]]) -> NormalizedDiagnostic? {
            batches
                .flatMap { $0 }
                .first { $0.message == "Workspace pulled diagnostic" }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while pulled(normalized.snapshot()) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        // Both the didOpen push and the workspace pull reach the raw
        // callback; only the pull is asserted on here.
        XCTAssertTrue(messages.snapshot().contains("Workspace pulled diagnostic"))
        let diagnostic = try XCTUnwrap(pulled(normalized.snapshot()))
        XCTAssertEqual(diagnostic.snapshotVersion, 5)
        XCTAssertEqual(diagnostic.startLine, 1)
        XCTAssertEqual(diagnostic.utf8Range, 14..<18)
        XCTAssertEqual(try snapshot.text(inUTF8Range: diagnostic.utf8Range), "lét")
    }

    @MainActor
    func testStoppingInvalidatesAnInFlightWorkspaceDiagnosticGeneration() async throws {
        let (identity, store, root) = try makeTrustedIdentity()
        let stateFile = root.appendingPathComponent("workspace-diagnostics-state")
        FileManager.default.createFile(atPath: stateFile.path, contents: Data())
        let messages = LockedArray<String>()
        let failures = LockedArray<String>()
        let service = LanguageWorkspaceService(
            identity: identity,
            trustStore: store,
            configuration: LanguageWorkspaceService.Configuration(languageId: "swift"),
            dependencies: try makeDependencies(
                scenario: "workspace-diagnostics-slow",
                environment: ["FAKE_LSP_STATE_FILE": stateFile.path]
            ),
            onDiagnostics: { _, diagnostics in
                for diagnostic in diagnostics {
                    messages.append(diagnostic.message)
                }
            },
            onWorkspaceDiagnosticsFailure: { failures.append($0) }
        )
        try await service.start()
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            let state = try String(contentsOf: stateFile, encoding: .utf8)
            if state.contains("workspaceDiagnostic:1") {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        await service.stop()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(messages.snapshot().isEmpty)
        XCTAssertTrue(failures.snapshot().isEmpty)
    }

    @MainActor
    func testWorkspaceDiagnosticFailureUsesExplicitCallback() async throws {
        let (identity, store, _) = try makeTrustedIdentity()
        let failures = LockedArray<String>()
        let service = LanguageWorkspaceService(
            identity: identity,
            trustStore: store,
            configuration: LanguageWorkspaceService.Configuration(languageId: "swift"),
            dependencies: try makeDependencies(scenario: "workspace-diagnostics-failure"),
            onWorkspaceDiagnosticsFailure: { failures.append($0) }
        )
        try await service.start()
        defer { Task { await service.stop() } }

        let deadline = ContinuousClock.now + .seconds(3)
        while failures.snapshot().isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(
            failures.snapshot().first?.contains("Workspace diagnostics failed") == true,
            "Got: \(failures.snapshot())"
        )
    }
}
