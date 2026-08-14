import Foundation
import SourceModel

// The language-agnostic engine behind every per-language workspace
// language service (SPEC 6.1's complete read-only LSP surface). One
// instance owns exactly one `LanguageServerConnection` for one
// (workspace, language adapter) pair, and implements SPEC 6.2's
// lifecycle, SPEC 6.3's document synchronization/validation, and every
// capability-gated read-only request. `SwiftWorkspaceLanguageService`
// wraps an instance of this to keep its own public API and error type
// unchanged from Phase 6; every other language adapter (TypeScript/
// JavaScript, HTML/CSS, Python, Rust) uses it directly.
//
// This file is deliberately only the actor's core: lifecycle, restart
// replay, and document synchronization. The state machines it serializes
// live in focused, directly testable neighbours —
// `DocumentSynchronizationLedger` (which documents the server holds),
// `LanguageDiagnosticsCoordinator` (publish sequencing/freshness and
// raw-vs-normalized routing), `LanguageServerReadinessLedger`
// (start/restart/replay readiness), `LanguageProviderRequestValidator`
// (generation/provider currency), `LSPRangeNormalizer` (pure wire →
// UTF-8 conversion) and `WorkspaceRootConfinement` (path confinement) —
// while the request surface itself lives in same-actor extensions
// (`+DocumentRequests`, `+Hierarchy`, `+Diagnostics`). All mutation
// still happens on this one actor, serialized by its isolation.

/// Owns exactly one `LanguageServerConnection` for one (workspace,
/// language) pair, enforcing SPEC 6/13's trust-before-launch rule and
/// SPEC 6.3's document synchronization and response-validation
/// requirements, for the complete SPEC 6.1 read-only capability surface.
public actor LanguageWorkspaceService {
    /// The workspace boundary every server-reported path is checked
    /// against. A plain root URL, never a host workspace-identity or
    /// trust-store type: this module stays platform-neutral.
    let confinement: WorkspaceRootConfinement
    /// The injected trust-before-launch gate, consulted on every
    /// `start()` (SPEC 6/13).
    private let authorization: WorkspaceLaunchAuthorization
    private let configuration: Configuration
    private let dependencies: Dependencies
    /// The logical + instance identity every cross-file result this
    /// service produces is bound to. Non-isolated so routing tables can be
    /// keyed by it without awaiting the actor.
    public nonisolated let providerID: LanguageProviderID
    private let providerValidator: LanguageProviderRequestValidator
    private let onStateChange: @Sendable (LanguageServerState) -> Void
    /// Raw, workspace-wide diagnostics for storage/presentation. Fires for
    /// every accepted report, including push reports for files Kod has not
    /// opened (which therefore have no `SourceSnapshot` to validate against)
    /// and `workspace/diagnostic` pull results.
    let onDiagnostics: @Sendable (URL, [Diagnostic]) -> Void
    /// Snapshot-normalized diagnostics for live editor decorations. Fires
    /// only for documents that are currently open in this service, against
    /// the exact immutable snapshot version that was open when the report
    /// arrived.
    let onNormalizedDiagnostics: @Sendable (URL, [NormalizedDiagnostic]) -> Void
    let onWorkspaceDiagnosticsFailure: @Sendable (String) -> Void
    /// Fires when an automatic-restart document replay could not re-open
    /// every tracked document. The service never claims `.ready` for a
    /// generation whose replay failed, so this is the precise, non-silent
    /// counterpart to that suppressed transition.
    private let onDocumentReplayFailure: @Sendable ([LanguageDocumentReplayFailure]) -> Void
    let diagnosticNormalizationYield: @Sendable () async -> Void
    private let providerResultValidationYield: @Sendable () async -> Void
    /// Injected suspension point taken before each document's replay, so
    /// tests can observe the "relaunched but not resynchronized yet"
    /// window deterministically instead of sleeping.
    private let documentReplayYield: @Sendable () async -> Void
    private let documentReplayAttemptLimit: Int
    private let documentReplayRetryDelay: Duration

    var connection: LanguageServerConnection?
    var connectionGeneration = 0
    /// Which documents this service has told the server about, and at
    /// which exact snapshot.
    var documents = DocumentSynchronizationLedger()
    /// Publish sequencing, freshness, and pull result IDs.
    var diagnosticsCoordinator = LanguageDiagnosticsCoordinator()
    /// Start/restart/replay readiness.
    private var readiness = LanguageServerReadinessLedger()
    var workspaceDiagnosticTask: Task<Void, Never>?
    /// The in-flight automatic-restart document replay, owned so `stop()`
    /// and `restart()` can cancel and await it rather than leaving a
    /// half-finished resynchronization running behind them.
    private var documentReplayTask: Task<[LanguageDocumentReplayFailure], Never>?
    /// The single in-flight `stop()`; concurrent and repeated calls join
    /// it instead of racing a second shutdown.
    private var stopTask: Task<Void, Never>?

    /// Platform-neutral designated entry point: an explicit workspace
    /// root for path confinement plus an injected launch-authorization
    /// capability. Hosts that model workspace trust themselves adapt it
    /// at their own boundary (see `WorkspaceTrustAuthorizing`).
    public init(
        workspaceRoot: URL,
        authorization: WorkspaceLaunchAuthorization,
        configuration: Configuration,
        dependencies: Dependencies,
        providerID: LanguageProviderID? = nil,
        onStateChange: @escaping @Sendable (LanguageServerState) -> Void = { _ in },
        onDiagnostics: @escaping @Sendable (URL, [Diagnostic]) -> Void = { _, _ in },
        onNormalizedDiagnostics: @escaping @Sendable (URL, [NormalizedDiagnostic]) -> Void = { _, _ in },
        onWorkspaceDiagnosticsFailure: @escaping @Sendable (String) -> Void = { _ in },
        onDocumentReplayFailure: @escaping @Sendable ([LanguageDocumentReplayFailure]) -> Void = { _ in }
    ) {
        self.init(
            workspaceRoot: workspaceRoot,
            authorization: authorization,
            configuration: configuration,
            dependencies: dependencies,
            providerID: providerID,
            onStateChange: onStateChange,
            onDiagnostics: onDiagnostics,
            onNormalizedDiagnostics: onNormalizedDiagnostics,
            onWorkspaceDiagnosticsFailure: onWorkspaceDiagnosticsFailure,
            onDocumentReplayFailure: onDocumentReplayFailure,
            diagnosticNormalizationYield: {},
            providerResultValidationYield: {}
        )
    }

    /// Boundary convenience for hosts that already own a workspace
    /// identity value and a main-actor trust store (the app's
    /// `WorkspaceCore` pair): the identity supplies the confinement root
    /// and the store supplies the launch gate, without this module
    /// depending on either type.
    public init<Trust: WorkspaceTrustAuthorizing>(
        identity: Trust.Workspace,
        trustStore: Trust,
        configuration: Configuration,
        dependencies: Dependencies,
        providerID: LanguageProviderID? = nil,
        onStateChange: @escaping @Sendable (LanguageServerState) -> Void = { _ in },
        onDiagnostics: @escaping @Sendable (URL, [Diagnostic]) -> Void = { _, _ in },
        onNormalizedDiagnostics: @escaping @Sendable (URL, [NormalizedDiagnostic]) -> Void = { _, _ in },
        onWorkspaceDiagnosticsFailure: @escaping @Sendable (String) -> Void = { _ in },
        onDocumentReplayFailure: @escaping @Sendable ([LanguageDocumentReplayFailure]) -> Void = { _ in }
    ) {
        self.init(
            workspaceRoot: trustStore.workspaceRoot(of: identity),
            authorization: .trustStore(trustStore, workspace: identity),
            configuration: configuration,
            dependencies: dependencies,
            providerID: providerID,
            onStateChange: onStateChange,
            onDiagnostics: onDiagnostics,
            onNormalizedDiagnostics: onNormalizedDiagnostics,
            onWorkspaceDiagnosticsFailure: onWorkspaceDiagnosticsFailure,
            onDocumentReplayFailure: onDocumentReplayFailure
        )
    }

    /// Test-facing designated initializer: the yield closures inject
    /// deterministic suspension points into diagnostic normalization,
    /// provider-result validation, and automatic-restart document replay.
    init(
        workspaceRoot: URL,
        authorization: WorkspaceLaunchAuthorization,
        configuration: Configuration,
        dependencies: Dependencies,
        providerID: LanguageProviderID? = nil,
        onStateChange: @escaping @Sendable (LanguageServerState) -> Void = { _ in },
        onDiagnostics: @escaping @Sendable (URL, [Diagnostic]) -> Void = { _, _ in },
        onNormalizedDiagnostics: @escaping @Sendable (URL, [NormalizedDiagnostic]) -> Void = { _, _ in },
        onWorkspaceDiagnosticsFailure: @escaping @Sendable (String) -> Void = { _ in },
        onDocumentReplayFailure: @escaping @Sendable ([LanguageDocumentReplayFailure]) -> Void = { _ in },
        diagnosticNormalizationYield: @escaping @Sendable () async -> Void,
        providerResultValidationYield: @escaping @Sendable () async -> Void = {},
        documentReplayYield: @escaping @Sendable () async -> Void = {},
        documentReplayAttemptLimit: Int = 2,
        documentReplayRetryDelay: Duration = .milliseconds(50)
    ) {
        confinement = WorkspaceRootConfinement(root: workspaceRoot)
        self.authorization = authorization
        self.configuration = configuration
        self.dependencies = dependencies
        let resolvedProviderID = providerID
            ?? LanguageProviderID(profileIdentifier: configuration.languageId)
        self.providerID = resolvedProviderID
        providerValidator = LanguageProviderRequestValidator(
            providerID: resolvedProviderID
        )
        self.onStateChange = onStateChange
        self.onDiagnostics = onDiagnostics
        self.onNormalizedDiagnostics = onNormalizedDiagnostics
        self.onWorkspaceDiagnosticsFailure = onWorkspaceDiagnosticsFailure
        self.onDocumentReplayFailure = onDocumentReplayFailure
        self.diagnosticNormalizationYield = diagnosticNormalizationYield
        self.providerResultValidationYield = providerResultValidationYield
        self.documentReplayYield = documentReplayYield
        self.documentReplayAttemptLimit = max(1, documentReplayAttemptLimit)
        self.documentReplayRetryDelay = documentReplayRetryDelay
    }

    public var currentState: LanguageServerState? {
        get async {
            await connection?.state
        }
    }

    /// The generation of the currently running server. Every start,
    /// restart, and stop increments it, so any handle produced by an
    /// earlier generation is detectably stale.
    public var currentGeneration: Int {
        connectionGeneration
    }

    /// The binding every cross-file result produced right now is stamped
    /// with: this provider, its current generation, and the encoding that
    /// generation negotiated.
    public func currentProviderBinding() async -> LanguageProviderBinding {
        providerValidator.binding(
            generation: connectionGeneration,
            positionEncoding: await resolvedPositionEncoding()
        )
    }

    // MARK: - Lifecycle

    public func start() async throws {
        guard await authorization.isAuthorized() else {
            throw LanguageWorkspaceServiceError.notTrusted
        }
        guard connection == nil else {
            return
        }
        readiness.markStarted()

        let executableURL: URL
        do {
            executableURL = try dependencies.discoverExecutable()
        } catch {
            onStateChange(.missing(reason: error.localizedDescription))
            throw error
        }

        let serverConfiguration = LanguageServerConnection.Configuration(
            executableURL: executableURL,
            arguments: configuration.arguments,
            environment: configuration.environment,
            rootURL: confinement.root,
            semanticTokenTypes: configuration.semanticTokenTypes,
            semanticTokenModifiers: configuration.semanticTokenModifiers,
            initializationOptions: configuration.initializationOptions,
            workspaceConfiguration: configuration.workspaceConfiguration
        )
        connectionGeneration += 1
        let generation = connectionGeneration
        let connection = dependencies.connectionFactory(
            serverConfiguration,
            { [weak self] newState in
                guard let self else {
                    return
                }
                Task { await self.handleStateChange(newState, generation: generation) }
            },
            { [weak self] notification in
                guard let self else {
                    return
                }
                Task {
                    await self.handleServerNotification(
                        notification,
                        generation: generation
                    )
                }
            }
        )
        self.connection = connection
        try await connection.start()
    }

    /// Forwards every state change to the caller, and — when a
    /// transition to `.ready` is not the very first one for this
    /// connection instance — re-synchronizes every currently tracked
    /// open document with `didOpen`. A crash/auto-restart cycle produces
    /// exactly this pattern inside the same `LanguageServerConnection`,
    /// and the freshly-relaunched process has no knowledge of any
    /// previously-open document until Kod re-sends it (SPEC 6.2/6.3).
    ///
    /// The relaunched server's `.ready` is deliberately *not* forwarded
    /// until that replay has fully succeeded: a caller that saw `.ready`
    /// would start issuing document requests against a server that does
    /// not hold the documents. A replay that cannot be completed reports
    /// typed per-document failures and a degraded state instead.
    private func handleStateChange(
        _ newState: LanguageServerState,
        generation: Int
    ) async {
        guard generation == connectionGeneration else {
            return
        }
        switch readiness.transition(for: newState) {
        case .forward(let state):
            onStateChange(state)
        case .relaunching:
            cancelWorkspaceDiagnostics(resetResultIDs: true)
            // A relaunching server's previously published markers no
            // longer describe anything; raw workspace problems stay
            // until their owner is cleared by the coordinator.
            clearNormalizedDiagnosticsForOpenDocuments()
            onStateChange(.starting)
        case .firstReady:
            onStateChange(.ready)
            await scheduleWorkspaceDiagnostics(generation: generation)
        case .replayDocumentsThenReady:
            await completeRelaunch(generation: generation)
        }
    }

    /// Resynchronizes a relaunched server before letting anyone see
    /// `.ready`, reporting typed failures and a degraded state when the
    /// documents cannot be restored.
    private func completeRelaunch(generation: Int) async {
        let failures = await replayOpenDocumentsAfterRestart(
            generation: generation
        )
        guard generation == connectionGeneration else {
            return
        }
        guard failures.isEmpty else {
            readiness.markReplayFailed(failures)
            onDocumentReplayFailure(failures)
            onStateChange(
                .crashed(
                    reason: LanguageServerReadinessLedger.replayFailureReason(failures)
                )
            )
            return
        }
        readiness.markReplaySucceeded()
        onStateChange(.ready)
        await scheduleWorkspaceDiagnostics(generation: generation)
    }

    /// The typed failures produced by the most recent automatic-restart
    /// document replay, empty once a replay has fully succeeded.
    public var documentReplayFailures: [LanguageDocumentReplayFailure] {
        readiness.replayFailures
    }

    private func replayOpenDocumentsAfterRestart(
        generation: Int
    ) async -> [LanguageDocumentReplayFailure] {
        documentReplayTask?.cancel()
        let task = Task {
            await self.performDocumentReplay(generation: generation)
        }
        documentReplayTask = task
        let failures = await task.value
        if documentReplayTask == task {
            documentReplayTask = nil
        }
        return failures
    }

    /// Re-sends `didOpen` for every tracked document, retrying a failed
    /// delivery up to `documentReplayAttemptLimit` times before giving
    /// up on that document. A document that could not be replayed is
    /// dropped from the tracked set — the server demonstrably does not
    /// hold it — so a later `synchronize` opens it again instead of
    /// issuing a `didChange` for a document the server never saw.
    private func performDocumentReplay(
        generation: Int
    ) async -> [LanguageDocumentReplayFailure] {
        var failures: [LanguageDocumentReplayFailure] = []
        for snapshot in documents.snapshotsOrderedByPath {
            await documentReplayYield()
            guard !Task.isCancelled, generation == connectionGeneration else {
                return failures
            }
            guard let connection else {
                failures.append(
                    LanguageDocumentReplayFailure(
                        url: snapshot.url,
                        reason: .notConnected,
                        attempts: 0
                    )
                )
                forgetDocument(at: snapshot.url)
                continue
            }
            let params = DidOpenTextDocumentParams(
                textDocument: TextDocumentItem(
                    uri: DocumentURI(fileURL: snapshot.url),
                    languageId: configuration.resolvedLanguageId(for: snapshot.url),
                    version: snapshot.version,
                    text: snapshot.text
                )
            )
            var attempts = 0
            var lastError: Error?
            while attempts < documentReplayAttemptLimit {
                attempts += 1
                do {
                    try await connection.sendNotification(.didOpen, params: params)
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    guard attempts < documentReplayAttemptLimit,
                          !Task.isCancelled,
                          generation == connectionGeneration,
                          self.connection === connection else {
                        break
                    }
                    try? await Task.sleep(for: documentReplayRetryDelay)
                }
            }
            if let lastError {
                failures.append(
                    LanguageDocumentReplayFailure(
                        url: snapshot.url,
                        reason: .notificationFailed(
                            LanguageServerReadinessLedger.transportReason(lastError)
                        ),
                        attempts: attempts
                    )
                )
                forgetDocument(at: snapshot.url)
            }
        }
        return failures
    }

    /// Drops a document Kod can no longer prove the server holds, and
    /// clears its editor markers. Raw workspace problems are untouched,
    /// exactly like a file that was never opened.
    private func forgetDocument(at url: URL) {
        guard let standardizedURL = documents.remove(url: url) else {
            return
        }
        clearNormalizedDiagnostics(for: standardizedURL)
    }

    /// Cancels and awaits an in-flight automatic-restart document replay.
    private func cancelDocumentReplayAwaitingCompletion() async {
        let task = documentReplayTask
        documentReplayTask = nil
        task?.cancel()
        _ = await task?.value
    }

    func handleServerNotificationForTesting(_ notification: ServerNotification) async {
        await handleServerNotification(notification, generation: connectionGeneration)
    }

    /// Test seam: drives the connection state machine directly, so a
    /// crash/auto-restart cycle's `.starting` → `.ready` sequence can be
    /// exercised deterministically without killing a real child process.
    func handleStateChangeForTesting(_ newState: LanguageServerState) async {
        await handleStateChange(newState, generation: connectionGeneration)
    }

    /// Test seam: simulates the transport disappearing between the server
    /// reporting `.ready` and the document replay being issued, which is
    /// what a second crash inside the restart window looks like here.
    func simulateConnectionLossForTesting() {
        connection = nil
    }

    var hasPendingWorkspaceDiagnosticsForTesting: Bool {
        workspaceDiagnosticTask != nil
    }

    var hasPendingDocumentReplayForTesting: Bool {
        documentReplayTask != nil
    }

    var isStoppedForTesting: Bool {
        readiness.hasStopped
    }

    /// Stops the current server (if any) and restarts it from scratch,
    /// clearing all tracked open-document state (SPEC 6.2's manual
    /// Restart action).
    public func restart() async throws {
        guard readiness.beginRestart() else {
            return
        }
        defer { readiness.endRestart() }
        connectionGeneration += 1
        await cancelDocumentReplayAwaitingCompletion()
        await cancelWorkspaceDiagnosticsAwaitingCompletion(resetResultIDs: true)
        let connection = self.connection
        self.connection = nil
        await connection?.shutdown()
        clearNormalizedDiagnosticsForOpenDocuments()
        documents.removeAll()
        readiness.resetForRelaunch()
        try await start()
    }

    /// Explicit, idempotent shutdown. Concurrent and repeated calls join
    /// the single in-flight stop rather than racing a second one, and a
    /// stop after a completed stop is a no-op — in particular it never
    /// advances the provider generation again. `start()`/`restart()`
    /// remain available afterwards.
    public func stop() async {
        if let stopTask {
            await stopTask.value
            return
        }
        guard !readiness.hasStopped else {
            return
        }
        let task = Task {
            await self.performStop()
        }
        stopTask = task
        await task.value
        if stopTask == task {
            stopTask = nil
        }
    }

    private func performStop() async {
        // Advanced first so every callback, replay, and diagnostics
        // continuation that resumes during the awaits below is already
        // stale and cannot mutate state or emit results.
        connectionGeneration += 1
        readiness.markStopping()
        await cancelDocumentReplayAwaitingCompletion()
        await cancelWorkspaceDiagnosticsAwaitingCompletion(resetResultIDs: true)
        let connection = self.connection
        self.connection = nil
        await connection?.shutdown()
        clearNormalizedDiagnosticsForOpenDocuments()
        documents.removeAll()
        readiness.markStopped()
    }

    // MARK: - Document synchronization (SPEC 6.3)

    /// Synchronizes `snapshot` without sending duplicate `didOpen`
    /// notifications. Callers can use the result to avoid projecting raw
    /// diagnostics from a superseded snapshot onto newly loaded content.
    public func synchronize(
        _ snapshot: SourceSnapshot
    ) async throws -> LanguageDocumentSynchronizationResult {
        switch documents.plan(for: snapshot) {
        case .open:
            try await didOpen(snapshot)
            return .opened
        case .unchanged:
            return .unchanged
        case .change:
            try await didChange(snapshot)
            return .changed
        }
    }

    public func didOpen(_ snapshot: SourceSnapshot) async throws {
        guard let connection else {
            throw LanguageWorkspaceServiceError.notStarted
        }
        let params = DidOpenTextDocumentParams(
            textDocument: TextDocumentItem(
                uri: DocumentURI(fileURL: snapshot.url),
                languageId: configuration.resolvedLanguageId(for: snapshot.url),
                version: snapshot.version,
                text: snapshot.text
            )
        )
        try await connection.sendNotification(.didOpen, params: params)
        documents.recordOpen(snapshot)
    }

    /// Called for a newly-loaded snapshot of an already-open document,
    /// e.g. after an external write (SPEC 6.3: "External changes
    /// increment the document version and send `didChange`").
    public func didChange(_ snapshot: SourceSnapshot) async throws {
        guard let connection else {
            throw LanguageWorkspaceServiceError.notStarted
        }
        try documents.requireTracked(snapshot)
        let params = DidChangeTextDocumentParams(
            textDocument: VersionedTextDocumentIdentifier(
                uri: DocumentURI(fileURL: snapshot.url),
                version: snapshot.version
            ),
            contentChanges: [TextDocumentContentChangeEvent(text: snapshot.text)]
        )
        try await connection.sendNotification(.didChange, params: params)
        documents.recordChange(snapshot)
        // Markers validated against the superseded snapshot are dropped
        // immediately; the raw workspace store keeps this file's problems
        // until the server republishes for the new version.
        clearNormalizedDiagnostics(for: snapshot.url.standardizedFileURL)
    }

    public func didClose(url: URL) async throws {
        guard let connection else {
            throw LanguageWorkspaceServiceError.notStarted
        }
        guard let standardizedURL = documents.remove(url: url) else {
            return
        }
        // Only editor markers are cleared here: a closed file's problems
        // stay in the workspace-wide store, exactly like a file that was
        // never opened at all.
        clearNormalizedDiagnostics(for: standardizedURL)
        try await connection.sendNotification(
            .didClose,
            params: DidCloseTextDocumentParams(textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: url)))
        )
    }

    // MARK: - Capability gating

    public func capabilities() async -> ServerCapabilities? {
        await connection?.serverCapabilities
    }

    public func serverStderrLog() async -> String {
        await connection?.stderrLog ?? ""
    }

    func resolvedPositionEncoding() async -> SourcePositionEncoding {
        guard let connection else {
            return .utf16
        }
        return await resolvedPositionEncoding(connection: connection)
    }

    private func resolvedPositionEncoding(
        connection: LanguageServerConnection
    ) async -> SourcePositionEncoding {
        guard let raw = await connection.serverCapabilities?.positionEncoding else {
            return .utf16
        }
        return raw == "utf-8" ? .utf8 : .utf16
    }

    // MARK: - Negotiated-encoding conversion

    /// Converts a raw LSP range (a diagnostic, a definition, a symbol —
    /// anything still in wire form) into a UTF-8 byte range validated
    /// against `snapshot`, using the server-negotiated position encoding
    /// rather than assuming UTF-16.
    ///
    /// `snapshot` is used purely as the coordinate space of the
    /// conversion: it is never recorded as this service's open-document
    /// state, so passing an arbitrary (possibly stale) snapshot here can
    /// never make it the basis of live editor markers.
    public func utf8Range(for range: LSPRange, in snapshot: SourceSnapshot) async -> Range<Int>? {
        let encoding = await resolvedPositionEncoding()
        return LSPRangeNormalizer.utf8Range(range, in: snapshot, encoding: encoding)
    }

    /// Converts raw diagnostics into snapshot-validated normalized values
    /// through the same conversion the push/pull paths use. Diagnostics
    /// whose range does not resolve inside `snapshot` are dropped rather
    /// than shown at the wrong offset (SPEC 6.3).
    public func normalizedDiagnostics(
        _ diagnostics: [Diagnostic],
        for snapshot: SourceSnapshot
    ) async -> [NormalizedDiagnostic] {
        let encoding = await resolvedPositionEncoding()
        return LSPRangeNormalizer.normalizedDiagnostics(
            diagnostics,
            snapshot: snapshot,
            encoding: encoding
        )
    }

    /// Normalizes diagnostics already retained by the workspace store only
    /// when they are known to describe `snapshot`. A changed, closed, or
    /// restarted document remains blocked until a fresh server publish
    /// succeeds, preventing another editor for the same URL from re-stamping
    /// stale wire ranges with the new snapshot version.
    public func normalizedStoredDiagnostics(
        _ diagnostics: [Diagnostic],
        for snapshot: SourceSnapshot
    ) async -> [NormalizedDiagnostic]? {
        let url = snapshot.url.standardizedFileURL
        guard documents.isCurrent(snapshot),
              diagnosticsCoordinator.allowsStoredNormalization(for: url) else {
            return nil
        }
        let publishSequence = diagnosticsCoordinator.currentSequence(for: url)
        let encoding = await resolvedPositionEncoding()
        guard documents.isCurrent(snapshot),
              diagnosticsCoordinator.currentSequence(for: url) == publishSequence,
              diagnosticsCoordinator.allowsStoredNormalization(for: url) else {
            return nil
        }
        return LSPRangeNormalizer.normalizedDiagnostics(
            diagnostics,
            snapshot: snapshot,
            encoding: encoding
        )
    }

    /// Whether `method` is currently usable, per static `initialize`
    /// capabilities (`staticallyAdvertised`) or a subsequent read-only
    /// dynamic registration.
    func isAvailable(_ method: LanguageClientOutboundMethod, staticallyAdvertised: Bool) async -> Bool {
        guard let connection else {
            return false
        }
        return await connection.isAvailable(method, staticallyAdvertised: staticallyAdvertised)
    }

    // MARK: - Helpers

    func connected() throws -> LanguageServerConnection {
        guard let connection else {
            throw LanguageWorkspaceServiceError.notStarted
        }
        return connection
    }

    func captureProviderRequest(
        connection: LanguageServerConnection
    ) async throws -> LanguageProviderRequest<LanguageServerConnection> {
        let generation = connectionGeneration
        let encoding = await resolvedPositionEncoding(connection: connection)
        let request = LanguageProviderRequest(
            connection: connection,
            binding: providerValidator.binding(
                generation: generation,
                positionEncoding: encoding
            )
        )
        try requireCurrentProviderRequest(request)
        return request
    }

    func captureProviderRequest(
        connection: LanguageServerConnection,
        binding: LanguageProviderBinding
    ) throws -> LanguageProviderRequest<LanguageServerConnection> {
        try providerValidator.requireCurrentProvider(
            binding,
            currentGeneration: connectionGeneration
        )
        let request = LanguageProviderRequest(connection: connection, binding: binding)
        try requireCurrentProviderRequest(request)
        return request
    }

    func validateProviderResponse(
        _ request: LanguageProviderRequest<LanguageServerConnection>
    ) async throws {
        await providerResultValidationYield()
        try requireCurrentProviderRequest(request)
    }

    private func requireCurrentProviderRequest(
        _ request: LanguageProviderRequest<LanguageServerConnection>
    ) throws {
        try providerValidator.requireCurrent(
            request,
            currentGeneration: connectionGeneration,
            currentConnection: connection
        )
    }
}
