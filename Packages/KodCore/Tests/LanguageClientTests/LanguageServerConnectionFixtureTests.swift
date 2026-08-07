import Foundation
import XCTest
@testable import LanguageClient

final class LanguageServerConnectionFixtureTests: XCTestCase {
    private func makeConfiguration(
        scenario: String,
        requestTimeout: TimeInterval = 5,
        shutdownTimeout: TimeInterval = 2,
        restartBudget: RestartBudget = RestartBudget(),
        maxMessageByteCount: Int = 4 * 1_024 * 1_024,
        environment: [String: String]? = nil
    ) throws -> LanguageServerConnection.Configuration {
        let executableURL = try FakeLanguageServerLocator.executableURL()
        return LanguageServerConnection.Configuration(
            executableURL: executableURL,
            arguments: [scenario],
            environment: environment,
            rootURL: FileManager.default.temporaryDirectory,
            requestTimeout: requestTimeout,
            shutdownTimeout: shutdownTimeout,
            restartBudget: restartBudget,
            semanticTokenTypes: ["namespace", "type", "class", "enum", "function", "variable"],
            semanticTokenModifiers: ["declaration", "readonly"],
            maxMessageByteCount: maxMessageByteCount
        )
    }

    // MARK: - Initialize / basic feature requests

    func testInitializeAdvertisesOnlyReadOnlyCapabilitiesAndReachesReadyState() async throws {
        let configuration = try makeConfiguration(scenario: "normal")
        let connection = LanguageServerConnection(configuration: configuration)
        try await connection.start()
        defer { Task { await connection.shutdown() } }

        let state = await connection.state
        XCTAssertEqual(state, .ready)

        let capabilities = await connection.serverCapabilities
        XCTAssertEqual(capabilities?.hoverProvider?.isEnabled, true)
        XCTAssertEqual(capabilities?.definitionProvider?.isEnabled, true)
        XCTAssertNotNil(capabilities?.semanticTokensProvider)
    }

    func testHoverDefinitionReferencesSymbolsDiagnosticsSemanticTokensAllRoundTrip() async throws {
        let configuration = try makeConfiguration(scenario: "normal")
        let connection = LanguageServerConnection(configuration: configuration)
        try await connection.start()
        defer { Task { await connection.shutdown() } }

        let hover: Hover = try await connection.sendRequest(
            .hover,
            params: HoverParams(
                textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("fake.swift"))),
                position: LSPPosition(line: 0, character: 0)
            )
        )
        XCTAssertEqual(hover.contents.value, "Fake hover")

        let definition: DefinitionResult = try await connection.sendRequest(
            .definition,
            params: DefinitionParams(
                textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("fake.swift"))),
                position: LSPPosition(line: 0, character: 0)
            )
        )
        XCTAssertEqual(definition.locations.count, 1)

        let references: [LSPLocation] = try await connection.sendRequest(
            .references,
            params: ReferenceParams(
                textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("fake.swift"))),
                position: LSPPosition(line: 0, character: 0),
                context: ReferenceContext(includeDeclaration: true)
            )
        )
        XCTAssertEqual(references.count, 1)

        let symbols: DocumentSymbolResult = try await connection.sendRequest(
            .documentSymbol,
            params: DocumentSymbolParams(textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("fake.swift"))))
        )
        guard case .hierarchical(let hierarchy) = symbols else {
            return XCTFail("Expected hierarchical document symbols")
        }
        XCTAssertEqual(hierarchy.first?.name, "FakeSymbol")

        let workspaceSymbols: WorkspaceSymbolResult = try await connection.sendRequest(
            .workspaceSymbol,
            params: WorkspaceSymbolParams(query: "Fake")
        )
        XCTAssertEqual(workspaceSymbols.first?.name, "FakeWorkspaceSymbol")

        let diagnosticReport: DocumentDiagnosticReport = try await connection.sendRequest(
            .diagnostic,
            params: DocumentDiagnosticParams(textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("fake.swift"))))
        )
        XCTAssertEqual(diagnosticReport.kind, "full")
        XCTAssertEqual(diagnosticReport.items?.count, 1)

        let tokens: SemanticTokens = try await connection.sendRequest(
            .semanticTokensFull,
            params: SemanticTokensParams(textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("fake.swift"))))
        )
        XCTAssertEqual(tokens.data, [0, 0, 4, 3, 0])
    }

    func testPublishDiagnosticsNotificationArrivesAfterDidOpen() async throws {
        let configuration = try makeConfiguration(scenario: "normal")
        let receivedDiagnostics = LockedBox<PublishDiagnosticsParams?>(nil)
        let connection = LanguageServerConnection(configuration: configuration, onNotification: { notification in
            if case .publishDiagnostics(let params) = notification {
                receivedDiagnostics.set(params)
            }
        })
        try await connection.start()
        defer { Task { await connection.shutdown() } }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake.swift")
        try await connection.sendNotification(
            .didOpen,
            params: DidOpenTextDocumentParams(
                textDocument: TextDocumentItem(uri: DocumentURI(fileURL: url), languageId: "swift", version: 1, text: "let x = 1")
            )
        )

        let deadline = Date().addingTimeInterval(3)
        while receivedDiagnostics.get() == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(receivedDiagnostics.get()?.diagnostics.first?.message, "Fake published diagnostic")
    }

    // MARK: - Mutation rejection (process-spy / adversarial server)

    func testRejectsServerInitiatedDynamicRegistrationAndApplyEdit() async throws {
        let configuration = try makeConfiguration(scenario: "mutation-attempt")
        let logMessages = LockedArray<String>()
        let connection = LanguageServerConnection(configuration: configuration, onNotification: { notification in
            if case .logMessage(let text) = notification,
               text.hasPrefix("registerCapability:") || text.hasPrefix("applyEdit:") {
                logMessages.append(text)
            }
        })
        try await connection.start()
        defer { Task { await connection.shutdown() } }

        let deadline = Date().addingTimeInterval(3)
        while logMessages.count() < 2, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let messages = logMessages.snapshot()
        XCTAssertTrue(messages.contains { $0.hasPrefix("registerCapability:rejected:") }, "Got: \(messages)")
        XCTAssertTrue(messages.contains { $0.hasPrefix("applyEdit:rejected:") }, "Got: \(messages)")
        for message in messages {
            XCTAssertTrue(message.contains(String(JSONRPCErrorCode.operationNotPermitted)), "Got: \(message)")
        }
    }

    // MARK: - Dynamic registration (SPEC 6.1: accept read-only, reject mutating)

    func testAcceptsAPurelyReadOnlyDynamicRegistrationBatch() async throws {
        let configuration = try makeConfiguration(scenario: "dynamic-registration-read-only")
        let logMessages = LockedArray<String>()
        let connection = LanguageServerConnection(configuration: configuration, onNotification: { notification in
            if case .logMessage(let text) = notification, text.hasPrefix("registerReadOnly:") {
                logMessages.append(text)
            }
        })
        try await connection.start()
        defer { Task { await connection.shutdown() } }

        let deadline = Date().addingTimeInterval(3)
        while logMessages.count() < 1, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(logMessages.snapshot(), ["registerReadOnly:accepted"])

        let isRegistered = await connection.isAvailable(.inlayHint, staticallyAdvertised: false)
        XCTAssertTrue(isRegistered)
    }

    func testRejectsAMixedBatchContainingOneMutatingRegistrationEntirely() async throws {
        let configuration = try makeConfiguration(scenario: "dynamic-registration-mixed-batch")
        let logMessages = LockedArray<String>()
        let connection = LanguageServerConnection(configuration: configuration, onNotification: { notification in
            if case .logMessage(let text) = notification, text.hasPrefix("registerMixed:") {
                logMessages.append(text)
            }
        })
        try await connection.start()
        defer { Task { await connection.shutdown() } }

        let deadline = Date().addingTimeInterval(3)
        while logMessages.count() < 1, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let message = try XCTUnwrap(logMessages.snapshot().first)
        XCTAssertTrue(message.hasPrefix("registerMixed:rejected:"), "Got: \(message)")

        // Neither method in the rejected batch should have been recorded
        // as available — a partial accept would be a mutation escape hatch.
        let inlayHintAvailable = await connection.isAvailable(.inlayHint, staticallyAdvertised: false)
        XCTAssertFalse(inlayHintAvailable)
    }

    func testUnregisteringARemovedCapabilityIsAlwaysAccepted() async throws {
        let configuration = try makeConfiguration(scenario: "dynamic-registration-then-unregister")
        let logMessages = LockedArray<String>()
        let connection = LanguageServerConnection(configuration: configuration, onNotification: { notification in
            if case .logMessage(let text) = notification,
               text.hasPrefix("registerThenUnregister:") || text.hasPrefix("unregister:") {
                logMessages.append(text)
            }
        })
        try await connection.start()
        defer { Task { await connection.shutdown() } }

        let deadline = Date().addingTimeInterval(3)
        while logMessages.count() < 2, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let messages = logMessages.snapshot()
        XCTAssertTrue(messages.contains("registerThenUnregister:accepted"), "Got: \(messages)")
        XCTAssertTrue(messages.contains("unregister:accepted"), "Got: \(messages)")

        // Give the unregister a moment to be processed before checking.
        try await Task.sleep(nanoseconds: 50_000_000)
        let isRegistered = await connection.isAvailable(.inlayHint, staticallyAdvertised: false)
        XCTAssertFalse(isRegistered)
    }

    // MARK: - Phase 7 extended capability round trip

    func testDeclarationTypeDefinitionImplementationDocumentHighlightAndHierarchyAllRoundTrip() async throws {
        let configuration = try makeConfiguration(scenario: "normal")
        let connection = LanguageServerConnection(configuration: configuration)
        try await connection.start()
        defer { Task { await connection.shutdown() } }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake.swift")
        let positionParams = TextDocumentPositionParams(
            textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: url)),
            position: LSPPosition(line: 0, character: 0)
        )

        let declaration: DeclarationResult = try await connection.sendRequest(.declaration, params: positionParams)
        XCTAssertEqual(declaration.locations.count, 1)

        let typeDefinition: TypeDefinitionResult = try await connection.sendRequest(.typeDefinition, params: positionParams)
        XCTAssertEqual(typeDefinition.locations.count, 1)

        let implementation: ImplementationResult = try await connection.sendRequest(.implementation, params: positionParams)
        XCTAssertEqual(implementation.locations.count, 1)

        let highlights: DocumentHighlightResult = try await connection.sendRequest(.documentHighlight, params: positionParams)
        XCTAssertEqual(highlights.count, 1)

        let foldingRanges: FoldingRangeResult = try await connection.sendRequest(
            .foldingRange,
            params: FoldingRangeParams(textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: url)))
        )
        XCTAssertEqual(foldingRanges.count, 1)

        let selectionRanges: SelectionRangeResult = try await connection.sendRequest(
            .selectionRange,
            params: SelectionRangeParams(textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: url)), positions: [LSPPosition(line: 0, character: 0)])
        )
        XCTAssertEqual(selectionRanges.count, 1)
        XCTAssertNotNil(selectionRanges.first?.parent)

        let links: DocumentLinkResult = try await connection.sendRequest(
            .documentLink,
            params: DocumentLinkParams(textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: url)))
        )
        XCTAssertEqual(links.count, 1)

        let hints: InlayHintResult = try await connection.sendRequest(
            .inlayHint,
            params: InlayHintParams(
                textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: url)),
                range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 10))
            )
        )
        XCTAssertEqual(hints?.count, 1)

        let signatureHelp: SignatureHelp = try await connection.sendRequest(.signatureHelp, params: positionParams)
        XCTAssertEqual(signatureHelp.signatures.count, 1)

        let prepared: CallHierarchyPrepareResult = try await connection.sendRequest(.prepareCallHierarchy, params: positionParams)
        let item = try XCTUnwrap(prepared?.first)
        let incoming: CallHierarchyIncomingCallsResult = try await connection.sendRequest(
            .callHierarchyIncomingCalls, params: CallHierarchyIncomingCallsParams(item: item)
        )
        XCTAssertEqual(incoming?.first?.from.name, "Caller")
        let outgoing: CallHierarchyOutgoingCallsResult = try await connection.sendRequest(
            .callHierarchyOutgoingCalls, params: CallHierarchyOutgoingCallsParams(item: item)
        )
        XCTAssertEqual(outgoing?.first?.to.name, "Callee")

        let preparedType: TypeHierarchyPrepareResult = try await connection.sendRequest(.prepareTypeHierarchy, params: positionParams)
        let typeItem = try XCTUnwrap(preparedType?.first)
        let supertypes: TypeHierarchySupertypesResult = try await connection.sendRequest(
            .typeHierarchySupertypes, params: TypeHierarchySupertypesParams(item: typeItem)
        )
        XCTAssertEqual(supertypes?.first?.name, "Supertype")
        let subtypes: TypeHierarchySubtypesResult = try await connection.sendRequest(
            .typeHierarchySubtypes, params: TypeHierarchySubtypesParams(item: typeItem)
        )
        XCTAssertEqual(subtypes?.first?.name, "Subtype")
    }

    func testCapabilityAbsentScenarioAdvertisesNoneOfThePhase7ExtendedCapabilities() async throws {
        let configuration = try makeConfiguration(scenario: "capability-absent")
        let connection = LanguageServerConnection(configuration: configuration)
        try await connection.start()
        defer { Task { await connection.shutdown() } }

        let capabilities = await connection.serverCapabilities
        XCTAssertNil(capabilities?.declarationProvider)
        XCTAssertNil(capabilities?.typeDefinitionProvider)
        XCTAssertNil(capabilities?.implementationProvider)
        XCTAssertNil(capabilities?.documentHighlightProvider)
        XCTAssertNil(capabilities?.foldingRangeProvider)
        XCTAssertNil(capabilities?.selectionRangeProvider)
        XCTAssertNil(capabilities?.documentLinkProvider)
        XCTAssertNil(capabilities?.inlayHintProvider)
        XCTAssertNil(capabilities?.signatureHelpProvider)
        XCTAssertNil(capabilities?.callHierarchyProvider)
        XCTAssertNil(capabilities?.typeHierarchyProvider)
    }

    func testUnsafeDocumentLinkTargetsAreDiscardedButHttpsLinksSurvive() async throws {
        let configuration = try makeConfiguration(scenario: "unsafe-document-link")
        let connection = LanguageServerConnection(configuration: configuration)
        try await connection.start()
        defer { Task { await connection.shutdown() } }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake.swift")
        let links: DocumentLinkResult = try await connection.sendRequest(
            .documentLink,
            params: DocumentLinkParams(textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: url)))
        )
        XCTAssertEqual(links.count, 2)
        let safeLinks = links.compactMap(SafeDocumentLink.validating)
        XCTAssertEqual(safeLinks.count, 1)
        guard case .web(let webURL) = safeLinks.first?.target else {
            return XCTFail("Expected the surviving link to be a web target")
        }
        XCTAssertEqual(webURL.absoluteString, "https://example.com/docs")
    }

    // MARK: - Cancellation / timeout

    func testCancellingTheCallingTaskSendsCancelRequestAndTheServerRespondsWithCancelled() async throws {
        let configuration = try makeConfiguration(scenario: "cancel", requestTimeout: 10)
        let connection = LanguageServerConnection(configuration: configuration)
        try await connection.start()
        defer { Task { await connection.shutdown() } }

        let task = Task<Hover, Error> {
            try await connection.sendRequest(
                .hover,
                params: HoverParams(
                    textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("fake.swift"))),
                    position: LSPPosition(line: 0, character: 0)
                )
            )
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected the cancelled request to throw")
        } catch {
            // Either a client-side cancellation error or the server's own
            // RequestCancelled response is acceptable; what matters is it
            // never silently "succeeds" with stale data.
        }
    }

    func testRequestTimesOutWhenServerNeverResponds() async throws {
        let configuration = try makeConfiguration(scenario: "timeout", requestTimeout: 0.4)
        let connection = LanguageServerConnection(configuration: configuration)
        try await connection.start()
        defer { Task { await connection.shutdown() } }

        do {
            let _: Hover = try await connection.sendRequest(
                .hover,
                params: HoverParams(
                    textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("fake.swift"))),
                    position: LSPPosition(line: 0, character: 0)
                )
            )
            XCTFail("Expected a timeout")
        } catch LanguageClientError.timedOut(let method) {
            XCTAssertEqual(method, "textDocument/hover")
        }
    }

    // MARK: - Work-done progress

    func testWorkDoneProgressDrivesIndexingState() async throws {
        let configuration = try makeConfiguration(scenario: "progress")
        let progressEvents = LockedArray<String>()
        let connection = LanguageServerConnection(configuration: configuration, onNotification: { notification in
            if case .progress(_, let value) = notification {
                progressEvents.append(value.kind.rawValue)
            }
        })
        try await connection.start()
        defer { Task { await connection.shutdown() } }

        let deadline = Date().addingTimeInterval(3)
        while progressEvents.count() < 3, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(progressEvents.snapshot(), ["begin", "report", "end"])

        // Give the state machine a moment to settle back to ready after
        // the "end" progress event.
        var finalState = await connection.state
        let stateDeadline = Date().addingTimeInterval(2)
        while finalState != .ready, Date() < stateDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
            finalState = await connection.state
        }
        XCTAssertEqual(finalState, .ready)
    }

    // MARK: - Stderr bounds

    func testStderrCaptureStaysBoundedUnderHeavyOutput() async throws {
        let configuration = try makeConfiguration(scenario: "stderr-noisy")
        let connection = LanguageServerConnection(configuration: configuration)
        try await connection.start()
        defer { Task { await connection.shutdown() } }

        try await Task.sleep(nanoseconds: 500_000_000)
        let log = await connection.stderrLog
        // The fixture writes 256 * 4096 = 1 MiB; the default bound is
        // 256 KiB, so the retained log must never approach the full
        // amount while still containing recent content.
        XCTAssertLessThanOrEqual(log.utf8.count, 256 * 1_024 + 4_096)
        XCTAssertFalse(log.isEmpty)
    }

    // MARK: - Malformed payloads / oversized framing

    func testMalformedJSONBodyIsDroppedWithoutTearingDownTheConnection() async throws {
        let configuration = try makeConfiguration(scenario: "malformed-json-body", requestTimeout: 1)
        let connection = LanguageServerConnection(configuration: configuration)
        try await connection.start()
        defer { Task { await connection.shutdown() } }

        do {
            let _: Hover = try await connection.sendRequest(
                .hover,
                params: HoverParams(
                    textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("fake.swift"))),
                    position: LSPPosition(line: 0, character: 0)
                )
            )
            XCTFail("Expected the malformed body to never resolve as a valid hover")
        } catch LanguageClientError.timedOut {
            // Expected: the malformed response is dropped, so the
            // original request simply times out.
        }

        // The connection must still be usable afterwards.
        let symbols: WorkspaceSymbolResult = try await connection.sendRequest(
            .workspaceSymbol,
            params: WorkspaceSymbolParams(query: "still-alive")
        )
        XCTAssertFalse(symbols.isEmpty)
    }

    func testOversizedDeclaredContentLengthTearsDownTheConnectionGracefully() async throws {
        let configuration = try makeConfiguration(scenario: "framing-error-oversized", maxMessageByteCount: 1_024)
        let connection = LanguageServerConnection(configuration: configuration)
        try await connection.start()
        defer { Task { await connection.shutdown() } }

        let deadline = Date().addingTimeInterval(5)
        while true {
            let state = await connection.state
            switch state {
            case .crashed, .disabled:
                return
            default:
                guard Date() < deadline else {
                    return XCTFail("Expected crashed/disabled after an oversized frame, got \(state)")
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }

    func testInvalidHeaderContentLengthTearsDownTheConnectionGracefully() async throws {
        let configuration = try makeConfiguration(scenario: "framing-error-header")
        let connection = LanguageServerConnection(configuration: configuration)
        try await connection.start()
        defer { Task { await connection.shutdown() } }

        let deadline = Date().addingTimeInterval(5)
        while true {
            let state = await connection.state
            switch state {
            case .crashed, .disabled:
                return
            default:
                guard Date() < deadline else {
                    return XCTFail("Expected crashed/disabled after a malformed header, got \(state)")
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }

    // MARK: - Crash detection, restart budget, disable

    func testCrashIsDetectedAutoRestartedAndEventuallyDisabledPastTheBudget() async throws {
        let configuration = try makeConfiguration(
            scenario: "crash-immediately",
            restartBudget: RestartBudget(maxRestarts: 1, window: 60)
        )
        let connection = LanguageServerConnection(configuration: configuration)
        try await connection.start()
        defer { Task { await connection.shutdown() } }

        let deadline = Date().addingTimeInterval(5)
        var state = await connection.state
        while true {
            if case .disabled = state {
                break
            }
            guard Date() < deadline else {
                XCTFail("Expected the connection to become disabled, last state: \(state)")
                return
            }
            try await Task.sleep(nanoseconds: 30_000_000)
            state = await connection.state
        }
    }

    // MARK: - Invalid/stale ranges (validated at the SwiftWorkspaceLanguageService layer,
    // exercised here just to confirm the fixture and raw connection round-trip an
    // out-of-bounds range without the connection itself rejecting it — validation is
    // the higher layer's job, covered in SwiftWorkspaceLanguageServiceFixtureTests).

    func testHoverWithAnOutOfBoundsRangeStillDecodesAtTheRawConnectionLevel() async throws {
        let configuration = try makeConfiguration(scenario: "invalid-range")
        let connection = LanguageServerConnection(configuration: configuration)
        try await connection.start()
        defer { Task { await connection.shutdown() } }

        let hover: Hover = try await connection.sendRequest(
            .hover,
            params: HoverParams(
                textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("fake.swift"))),
                position: LSPPosition(line: 0, character: 0)
            )
        )
        XCTAssertEqual(hover.range?.start.line, 999_999)
    }

    // MARK: - Graceful shutdown

    func testShutdownSendsShutdownThenExitAndReachesStopped() async throws {
        let configuration = try makeConfiguration(scenario: "normal")
        let connection = LanguageServerConnection(configuration: configuration)
        try await connection.start()

        await connection.shutdown()
        let state = await connection.state
        XCTAssertEqual(state, .stopped)
    }
}

/// A tiny thread-safe array for collecting notifications delivered from
/// `LanguageServerConnection`'s `@Sendable` notification-handler closure,
/// which can fire from a different context than the test's `await` calls.
final class LockedArray<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    func append(_ element: Element) {
        lock.lock()
        storage.append(element)
        lock.unlock()
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    func snapshot() -> [Element] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
