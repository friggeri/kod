import Foundation
import SourceModel
import WorkspaceCore

// The language-agnostic engine behind every per-language workspace
// language service (SPEC 6.1's complete read-only LSP surface). One
// instance owns exactly one `LanguageServerConnection` for one
// (workspace, language adapter) pair, and implements SPEC 6.2's
// lifecycle, SPEC 6.3's document synchronization/validation, and every
// capability-gated read-only request. `SwiftWorkspaceLanguageService`
// wraps an instance of this to keep its own public API and error type
// unchanged from Phase 6; every other language adapter (TypeScript/
// JavaScript, HTML/CSS, Python, Rust) uses it directly.

// MARK: - Result value types

/// One absolute UTF-8 byte-range token produced by decoding a
/// `semanticTokens/full` response's relative-encoded `data` array against
/// a specific `SourceSnapshot`. Discarded rather than surfaced if its
/// decoded range falls outside the snapshot's bounds (SPEC 6.3).
public struct SemanticToken: Equatable, Sendable {
    public let utf8Range: Range<Int>
    public let tokenType: String
    public let tokenModifiers: [String]

    public init(utf8Range: Range<Int>, tokenType: String, tokenModifiers: [String]) {
        self.utf8Range = utf8Range
        self.tokenType = tokenType
        self.tokenModifiers = tokenModifiers
    }
}

/// One `documentSymbol` result entry, already validated and translated
/// into UTF-8 byte ranges against the requesting snapshot.
public struct ValidatedDocumentSymbol: Sendable {
    public let name: String
    public let detail: String?
    public let kind: SymbolKind
    public let utf8Range: Range<Int>
    public let utf8SelectionRange: Range<Int>
    public let children: [ValidatedDocumentSymbol]

    public init(
        name: String,
        detail: String?,
        kind: SymbolKind,
        utf8Range: Range<Int>,
        utf8SelectionRange: Range<Int>,
        children: [ValidatedDocumentSymbol]
    ) {
        self.name = name
        self.detail = detail
        self.kind = kind
        self.utf8Range = utf8Range
        self.utf8SelectionRange = utf8SelectionRange
        self.children = children
    }
}

/// A `workspace/symbol` or cross-file `definition`/`references`/
/// hierarchy result, kept in wire form (URI + LSP position) since Kod
/// does not necessarily have the target file's `SourceSnapshot` loaded
/// yet; a caller resolves it to a byte offset only once (if) it actually
/// opens that file.
public struct WorkspaceSymbolLocation: Equatable, Sendable {
    public let url: URL
    public let range: LSPRange
    public let name: String
    public let kind: SymbolKind
    public let containerName: String?

    public init(url: URL, range: LSPRange, name: String, kind: SymbolKind, containerName: String?) {
        self.url = url
        self.range = range
        self.name = name
        self.kind = kind
        self.containerName = containerName
    }
}

/// A structurally-validated cross-file navigation target: a same-process
/// absolute `file://` URI with a non-negative, non-inverted range. Used
/// for definition/declaration/type-definition/implementation/references,
/// none of which are guaranteed to point inside the currently open
/// snapshot, so full UTF-8 byte-offset validation happens once (if) a
/// caller actually opens the target file's own snapshot.
public struct NavigationTarget: Equatable, Sendable {
    public let url: URL
    public let range: LSPRange

    public init(url: URL, range: LSPRange) {
        self.url = url
        self.range = range
    }
}

public struct ValidatedDocumentHighlight: Equatable, Sendable {
    public let utf8Range: Range<Int>
    public let kind: DocumentHighlight.Kind?

    public init(utf8Range: Range<Int>, kind: DocumentHighlight.Kind?) {
        self.utf8Range = utf8Range
        self.kind = kind
    }
}

public struct ValidatedFoldingRange: Equatable, Sendable {
    public let startLine: Int
    public let endLine: Int
    public let kind: String?

    public init(startLine: Int, endLine: Int, kind: String?) {
        self.startLine = startLine
        self.endLine = endLine
        self.kind = kind
    }
}

public final class ValidatedSelectionRange: Sendable {
    public let utf8Range: Range<Int>
    public let parent: ValidatedSelectionRange?

    public init(utf8Range: Range<Int>, parent: ValidatedSelectionRange?) {
        self.utf8Range = utf8Range
        self.parent = parent
    }
}

public struct ValidatedDocumentLink: Sendable {
    public let utf8Range: Range<Int>
    public let target: SafeDocumentLink.Target
    public let tooltip: String?

    public init(utf8Range: Range<Int>, target: SafeDocumentLink.Target, tooltip: String?) {
        self.utf8Range = utf8Range
        self.target = target
        self.tooltip = tooltip
    }
}

public struct ValidatedInlayHint: Sendable {
    public let utf8Offset: Int
    public let label: String
    public let kind: InlayHintKind?
    public let paddingLeft: Bool
    public let paddingRight: Bool

    public init(utf8Offset: Int, label: String, kind: InlayHintKind?, paddingLeft: Bool, paddingRight: Bool) {
        self.utf8Offset = utf8Offset
        self.label = label
        self.kind = kind
        self.paddingLeft = paddingLeft
        self.paddingRight = paddingRight
    }
}

/// A published diagnostic converted through the server-negotiated position
/// encoding and validated against the exact immutable snapshot version that
/// was open when the notification arrived.
public struct NormalizedDiagnostic: Sendable {
    public let snapshotVersion: Int
    public let utf8Range: Range<Int>
    public let startLine: Int
    public let severity: DiagnosticSeverity?
    public let code: JSONValue?
    public let source: String?
    public let message: String

    public init(
        snapshotVersion: Int,
        utf8Range: Range<Int>,
        startLine: Int,
        severity: DiagnosticSeverity?,
        code: JSONValue?,
        source: String?,
        message: String
    ) {
        self.snapshotVersion = snapshotVersion
        self.utf8Range = utf8Range
        self.startLine = startLine
        self.severity = severity
        self.code = code
        self.source = source
        self.message = message
    }
}

/// A `CallHierarchyItem`/`TypeHierarchyItem`, structurally validated like
/// `NavigationTarget` (its `uri`/`range` need not be inside the currently
/// open snapshot) with its opaque `data` preserved verbatim so it can be
/// sent back unmodified in a follow-up `incomingCalls`/`outgoingCalls`/
/// `supertypes`/`subtypes` request.
public struct ValidatedHierarchyItem: Equatable, Sendable {
    public let name: String
    public let kind: SymbolKind
    public let detail: String?
    public let url: URL
    public let range: LSPRange
    public let selectionRange: LSPRange
    public let data: JSONValue?

    public init(
        name: String,
        kind: SymbolKind,
        detail: String?,
        url: URL,
        range: LSPRange,
        selectionRange: LSPRange,
        data: JSONValue?
    ) {
        self.name = name
        self.kind = kind
        self.detail = detail
        self.url = url
        self.range = range
        self.selectionRange = selectionRange
        self.data = data
    }
}

public struct ValidatedIncomingCall: Equatable, Sendable {
    public let from: ValidatedHierarchyItem
    public let fromRanges: [LSPRange]

    public init(from: ValidatedHierarchyItem, fromRanges: [LSPRange]) {
        self.from = from
        self.fromRanges = fromRanges
    }
}

public struct ValidatedOutgoingCall: Equatable, Sendable {
    public let to: ValidatedHierarchyItem
    public let fromRanges: [LSPRange]

    public init(to: ValidatedHierarchyItem, fromRanges: [LSPRange]) {
        self.to = to
        self.fromRanges = fromRanges
    }
}

public enum LanguageWorkspaceServiceError: Error, Equatable, Sendable {
    case notTrusted
    case notStarted
    case documentNotOpen(URL)
    case staleRequest(url: URL, expectedVersion: Int, actualVersion: Int)
    case capabilityUnavailable(String)
    case invalidTargetURI(String)
}

public enum LanguageDocumentSynchronizationResult: Equatable, Sendable {
    case opened
    case unchanged
    case changed
}

/// Owns exactly one `LanguageServerConnection` for one (workspace,
/// language) pair, enforcing SPEC 6/13's trust-before-launch rule and
/// SPEC 6.3's document synchronization and response-validation
/// requirements, for the complete SPEC 6.1 read-only capability surface.
public actor LanguageWorkspaceService {
    public struct Dependencies: Sendable {
        public var discoverExecutable: @Sendable () throws -> URL
        public var connectionFactory: @Sendable (
            LanguageServerConnection.Configuration,
            @escaping @Sendable (LanguageServerState) -> Void,
            @escaping @Sendable (ServerNotification) -> Void
        ) -> LanguageServerConnection

        public init(
            discoverExecutable: @escaping @Sendable () throws -> URL,
            connectionFactory: @escaping @Sendable (
                LanguageServerConnection.Configuration,
                @escaping @Sendable (LanguageServerState) -> Void,
                @escaping @Sendable (ServerNotification) -> Void
            ) -> LanguageServerConnection = { configuration, onStateChange, onNotification in
                LanguageServerConnection(
                    configuration: configuration,
                    onStateChange: onStateChange,
                    onNotification: onNotification
                )
            }
        ) {
            self.discoverExecutable = discoverExecutable
            self.connectionFactory = connectionFactory
        }
    }

    public struct Configuration: Sendable {
        public var languageId: String
        public var languageIdForURL: @Sendable (URL) -> String?
        public var arguments: [String]
        public var environment: [String: String]?
        public var semanticTokenTypes: [String]
        public var semanticTokenModifiers: [String]
        public var initializationOptions: JSONValue?
        public var workspaceConfiguration: [String: JSONValue]

        public init(
            languageId: String,
            languageIdForURL: @escaping @Sendable (URL) -> String? = { _ in nil },
            arguments: [String] = [],
            environment: [String: String]? = nil,
            semanticTokenTypes: [String] = [],
            semanticTokenModifiers: [String] = [],
            initializationOptions: JSONValue? = nil,
            workspaceConfiguration: [String: JSONValue] = [:]
        ) {
            self.languageId = languageId
            self.languageIdForURL = languageIdForURL
            self.arguments = arguments
            self.environment = environment
            self.semanticTokenTypes = semanticTokenTypes
            self.semanticTokenModifiers = semanticTokenModifiers
            self.initializationOptions = initializationOptions
            self.workspaceConfiguration = workspaceConfiguration
        }

        func resolvedLanguageId(for url: URL) -> String {
            languageIdForURL(url) ?? languageId
        }
    }

    private let identity: WorkspaceIdentity
    private let trustStore: WorkspaceTrustStore
    private let configuration: Configuration
    private let dependencies: Dependencies
    private let onStateChange: @Sendable (LanguageServerState) -> Void
    /// Raw, workspace-wide diagnostics for storage/presentation. Fires for
    /// every accepted report, including push reports for files Kod has not
    /// opened (which therefore have no `SourceSnapshot` to validate against)
    /// and `workspace/diagnostic` pull results.
    private let onDiagnostics: @Sendable (URL, [Diagnostic]) -> Void
    /// Snapshot-normalized diagnostics for live editor decorations. Fires
    /// only for documents that are currently open in this service, against
    /// the exact immutable snapshot version that was open when the report
    /// arrived.
    private let onNormalizedDiagnostics: @Sendable (URL, [NormalizedDiagnostic]) -> Void
    private let onWorkspaceDiagnosticsFailure: @Sendable (String) -> Void
    private let diagnosticNormalizationYield: @Sendable () async -> Void

    private var connection: LanguageServerConnection?
    private var connectionGeneration = 0
    private var isRestarting = false
    private var openDocuments: [URL: SourceSnapshot] = [:]
    private var diagnosticPublishSequenceByURL: [URL: UInt64] = [:]
    private var diagnosticsRequiringFreshPublish: Set<URL> = []
    private var didCompleteFirstReady = false
    private var isAwaitingConnectionReady = false
    private var workspaceDiagnosticTask: Task<Void, Never>?
    private var workspaceDiagnosticResultIDs: [URL: String] = [:]

    public init(
        identity: WorkspaceIdentity,
        trustStore: WorkspaceTrustStore,
        configuration: Configuration,
        dependencies: Dependencies,
        onStateChange: @escaping @Sendable (LanguageServerState) -> Void = { _ in },
        onDiagnostics: @escaping @Sendable (URL, [Diagnostic]) -> Void = { _, _ in },
        onNormalizedDiagnostics: @escaping @Sendable (URL, [NormalizedDiagnostic]) -> Void = { _, _ in },
        onWorkspaceDiagnosticsFailure: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.init(
            identity: identity,
            trustStore: trustStore,
            configuration: configuration,
            dependencies: dependencies,
            onStateChange: onStateChange,
            onDiagnostics: onDiagnostics,
            onNormalizedDiagnostics: onNormalizedDiagnostics,
            onWorkspaceDiagnosticsFailure: onWorkspaceDiagnosticsFailure,
            diagnosticNormalizationYield: {}
        )
    }

    /// Test-facing designated initializer: `diagnosticNormalizationYield`
    /// is an injectable suspension point inside diagnostic normalization,
    /// used to exercise close/change/version races deterministically.
    init(
        identity: WorkspaceIdentity,
        trustStore: WorkspaceTrustStore,
        configuration: Configuration,
        dependencies: Dependencies,
        onStateChange: @escaping @Sendable (LanguageServerState) -> Void = { _ in },
        onDiagnostics: @escaping @Sendable (URL, [Diagnostic]) -> Void = { _, _ in },
        onNormalizedDiagnostics: @escaping @Sendable (URL, [NormalizedDiagnostic]) -> Void = { _, _ in },
        onWorkspaceDiagnosticsFailure: @escaping @Sendable (String) -> Void = { _ in },
        diagnosticNormalizationYield: @escaping @Sendable () async -> Void
    ) {
        self.identity = identity
        self.trustStore = trustStore
        self.configuration = configuration
        self.dependencies = dependencies
        self.onStateChange = onStateChange
        self.onDiagnostics = onDiagnostics
        self.onNormalizedDiagnostics = onNormalizedDiagnostics
        self.onWorkspaceDiagnosticsFailure = onWorkspaceDiagnosticsFailure
        self.diagnosticNormalizationYield = diagnosticNormalizationYield
    }

    public var currentState: LanguageServerState? {
        get async {
            await connection?.state
        }
    }

    // MARK: - Lifecycle

    public func start() async throws {
        guard await MainActor.run(body: { trustStore.isTrusted(identity) }) else {
            throw LanguageWorkspaceServiceError.notTrusted
        }
        guard connection == nil else {
            return
        }

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
            rootURL: identity.root,
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
    private func handleStateChange(
        _ newState: LanguageServerState,
        generation: Int
    ) async {
        guard generation == connectionGeneration else {
            return
        }
        onStateChange(newState)
        if newState == .starting {
            isAwaitingConnectionReady = true
            if didCompleteFirstReady {
                cancelWorkspaceDiagnostics(resetResultIDs: true)
                // A relaunching server's previously published markers no
                // longer describe anything; raw workspace problems stay
                // until their owner is cleared by the coordinator.
                clearNormalizedDiagnosticsForOpenDocuments()
            }
        }
        guard newState == .ready, isAwaitingConnectionReady else {
            return
        }
        isAwaitingConnectionReady = false
        if didCompleteFirstReady {
            await resyncOpenDocumentsAfterRestart()
        }
        didCompleteFirstReady = true
        await scheduleWorkspaceDiagnostics(generation: generation)
    }

    private func resyncOpenDocumentsAfterRestart() async {
        guard let connection else {
            return
        }
        for snapshot in openDocuments.values {
            let params = DidOpenTextDocumentParams(
                textDocument: TextDocumentItem(
                    uri: DocumentURI(fileURL: snapshot.url),
                    languageId: configuration.resolvedLanguageId(for: snapshot.url),
                    version: snapshot.version,
                    text: snapshot.text
                )
            )
            try? await connection.sendNotification(.didOpen, params: params)
        }
    }

    private func handleServerNotification(
        _ notification: ServerNotification,
        generation: Int
    ) async {
        guard generation == connectionGeneration else {
            return
        }
        switch notification {
        case .workspaceDiagnosticRefresh:
            await scheduleWorkspaceDiagnostics(generation: generation)
        case .publishDiagnostics(let params):
            await handlePublishedDiagnostics(params, generation: generation)
        case .progress, .logMessage, .showMessage, .unknown:
            break
        }
    }

    private func handlePublishedDiagnostics(
        _ params: PublishDiagnosticsParams,
        generation: Int
    ) async {
        guard let url = workspaceFileURL(from: params.uri) else {
            return
        }
        // Versioned reports for open files must match the live snapshot.
        // Unopened files have no client-side version to compare and are
        // accepted when their file URI remains inside the trusted workspace.
        if let version = params.version, let openSnapshot = openDocuments[url], version != openSnapshot.version {
            return
        }
        // Raw diagnostics always reach the workspace-wide store, whether
        // or not Kod has the file open; normalization additionally runs
        // for open documents so editors get snapshot-validated markers.
        onDiagnostics(url, params.diagnostics)
        await publishNormalizedDiagnostics(
            url: url,
            diagnostics: params.diagnostics,
            generation: generation
        )
    }

    /// Converts `diagnostics` against the exact snapshot that is open for
    /// `url` right now and forwards them to `onNormalizedDiagnostics`.
    /// No-ops for files that are not open: an unopened workspace file has
    /// no `SourceSnapshot` to validate against, and its problems remain
    /// raw-only. A per-URL monotonically increasing publish sequence, the
    /// connection generation and the snapshot version are all re-checked
    /// after the normalization suspension point so a close, a `didChange`,
    /// a restart, or a newer same-version publish can never be overwritten
    /// by an older in-flight normalization.
    private func publishNormalizedDiagnostics(
        url: URL,
        diagnostics: [Diagnostic],
        generation: Int
    ) async {
        guard let snapshot = openDocuments[url] else {
            return
        }
        let publishSequence = diagnosticPublishSequenceByURL[url, default: 0] &+ 1
        diagnosticPublishSequenceByURL[url] = publishSequence
        let encoding = await resolvedPositionEncoding()
        await diagnosticNormalizationYield()
        guard generation == connectionGeneration,
              let currentSnapshot = openDocuments[url],
              currentSnapshot.version == snapshot.version,
              diagnosticPublishSequenceByURL[url] == publishSequence else {
            return
        }
        diagnosticsRequiringFreshPublish.remove(url)
        onNormalizedDiagnostics(
            url,
            normalizedDiagnostics(diagnostics, snapshot: snapshot, encoding: encoding)
        )
    }

    private func clearNormalizedDiagnosticsForOpenDocuments() {
        for url in openDocuments.keys {
            diagnosticPublishSequenceByURL[url] = diagnosticPublishSequenceByURL[url, default: 0] &+ 1
            diagnosticsRequiringFreshPublish.insert(url)
            onNormalizedDiagnostics(url, [])
        }
    }

    private func scheduleWorkspaceDiagnostics(generation: Int) async {
        guard generation == connectionGeneration,
              let connection,
              await connection.serverCapabilities?.diagnosticProvider?.workspaceDiagnostics == true else {
            return
        }
        workspaceDiagnosticTask?.cancel()
        workspaceDiagnosticTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else {
                    return
                }
                await self?.performWorkspaceDiagnostics(
                    connection: connection,
                    generation: generation
                )
            } catch {
                // Cancellation is the expected coalescing path.
            }
        }
    }

    private func performWorkspaceDiagnostics(
        connection: LanguageServerConnection,
        generation: Int
    ) async {
        guard generation == connectionGeneration, self.connection === connection else {
            return
        }
        let previousResultIDs = workspaceDiagnosticResultIDs
            .map { PreviousResultID(uri: DocumentURI(fileURL: $0.key), value: $0.value) }
            .sorted { $0.uri.stringValue < $1.uri.stringValue }
        let identifier = await connection.serverCapabilities?.diagnosticProvider?.identifier
        do {
            let report: WorkspaceDiagnosticReport = try await connection.sendRequest(
                .workspaceDiagnostic,
                params: WorkspaceDiagnosticParams(
                    identifier: identifier,
                    previousResultIds: previousResultIDs
                ),
                priority: .background
            )
            try Task.checkCancellation()
            guard generation == connectionGeneration, self.connection === connection else {
                return
            }
            for item in report.items {
                guard let url = workspaceFileURL(from: item.uri) else {
                    continue
                }
                if let version = item.version,
                   let openSnapshot = openDocuments[url],
                   version != openSnapshot.version {
                    continue
                }
                if let resultID = item.resultId {
                    workspaceDiagnosticResultIDs[url] = resultID
                } else if item.kind == .full {
                    workspaceDiagnosticResultIDs.removeValue(forKey: url)
                }
                if item.kind == .full {
                    let diagnostics = item.items ?? []
                    onDiagnostics(url, diagnostics)
                    await publishNormalizedDiagnostics(
                        url: url,
                        diagnostics: diagnostics,
                        generation: generation
                    )
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == connectionGeneration, self.connection === connection else {
                return
            }
            onWorkspaceDiagnosticsFailure(String(describing: error))
        }
    }

    private func cancelWorkspaceDiagnostics(resetResultIDs: Bool) {
        workspaceDiagnosticTask?.cancel()
        workspaceDiagnosticTask = nil
        if resetResultIDs {
            workspaceDiagnosticResultIDs.removeAll()
        }
    }

    private func workspaceFileURL(from uri: DocumentURI) -> URL? {
        guard let rawURL = uri.fileURL else {
            return nil
        }
        let url = rawURL.standardizedFileURL
        let root = identity.root.standardizedFileURL
        let rootPath = root.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard url.path == rootPath || url.path.hasPrefix(prefix) else {
            return nil
        }
        return url
    }

    func handleServerNotificationForTesting(_ notification: ServerNotification) async {
        await handleServerNotification(notification, generation: connectionGeneration)
    }

    /// Stops the current server (if any) and restarts it from scratch,
    /// clearing all tracked open-document state (SPEC 6.2's manual
    /// Restart action).
    public func restart() async throws {
        guard !isRestarting else {
            return
        }
        isRestarting = true
        defer { isRestarting = false }
        cancelWorkspaceDiagnostics(resetResultIDs: true)
        connectionGeneration += 1
        if let connection {
            await connection.shutdown()
        }
        connection = nil
        clearNormalizedDiagnosticsForOpenDocuments()
        openDocuments.removeAll()
        didCompleteFirstReady = false
        isAwaitingConnectionReady = false
        try await start()
    }

    public func stop() async {
        cancelWorkspaceDiagnostics(resetResultIDs: true)
        connectionGeneration += 1
        await connection?.shutdown()
        connection = nil
        clearNormalizedDiagnosticsForOpenDocuments()
        openDocuments.removeAll()
        didCompleteFirstReady = false
        isAwaitingConnectionReady = false
    }

    // MARK: - Document synchronization (SPEC 6.3)

    /// Synchronizes `snapshot` without sending duplicate `didOpen`
    /// notifications. Callers can use the result to avoid projecting raw
    /// diagnostics from a superseded snapshot onto newly loaded content.
    public func synchronize(
        _ snapshot: SourceSnapshot
    ) async throws -> LanguageDocumentSynchronizationResult {
        let url = snapshot.url.standardizedFileURL
        guard let current = openDocuments[url] else {
            try await didOpen(snapshot)
            return .opened
        }
        guard current.version != snapshot.version
                || current.text != snapshot.text else {
            return .unchanged
        }
        try await didChange(snapshot)
        return .changed
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
        openDocuments[snapshot.url.standardizedFileURL] = snapshot
    }

    /// Called for a newly-loaded snapshot of an already-open document,
    /// e.g. after an external write (SPEC 6.3: "External changes
    /// increment the document version and send `didChange`").
    public func didChange(_ snapshot: SourceSnapshot) async throws {
        guard let connection else {
            throw LanguageWorkspaceServiceError.notStarted
        }
        guard openDocuments[snapshot.url.standardizedFileURL] != nil else {
            throw LanguageWorkspaceServiceError.documentNotOpen(snapshot.url)
        }
        let params = DidChangeTextDocumentParams(
            textDocument: VersionedTextDocumentIdentifier(
                uri: DocumentURI(fileURL: snapshot.url),
                version: snapshot.version
            ),
            contentChanges: [TextDocumentContentChangeEvent(text: snapshot.text)]
        )
        try await connection.sendNotification(.didChange, params: params)
        let url = snapshot.url.standardizedFileURL
        openDocuments[url] = snapshot
        // Markers validated against the superseded snapshot are dropped
        // immediately; the raw workspace store keeps this file's problems
        // until the server republishes for the new version.
        diagnosticPublishSequenceByURL[url] = diagnosticPublishSequenceByURL[url, default: 0] &+ 1
        diagnosticsRequiringFreshPublish.insert(url)
        onNormalizedDiagnostics(url, [])
    }

    public func didClose(url: URL) async throws {
        guard let connection else {
            throw LanguageWorkspaceServiceError.notStarted
        }
        let standardizedURL = url.standardizedFileURL
        guard openDocuments.removeValue(forKey: standardizedURL) != nil else {
            return
        }
        // Only editor markers are cleared here: a closed file's problems
        // stay in the workspace-wide store, exactly like a file that was
        // never opened at all.
        diagnosticPublishSequenceByURL[standardizedURL] =
            diagnosticPublishSequenceByURL[standardizedURL, default: 0] &+ 1
        diagnosticsRequiringFreshPublish.insert(standardizedURL)
        onNormalizedDiagnostics(standardizedURL, [])
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

    private func resolvedPositionEncoding() async -> LSPPositionEncoding {
        guard let raw = await connection?.serverCapabilities?.positionEncoding else {
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
        return utf8Range(range, snapshot: snapshot, encoding: encoding)
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
        return normalizedDiagnostics(diagnostics, snapshot: snapshot, encoding: encoding)
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
        guard let currentSnapshot = openDocuments[url],
              currentSnapshot.version == snapshot.version,
              currentSnapshot.text == snapshot.text,
              !diagnosticsRequiringFreshPublish.contains(url) else {
            return nil
        }
        let publishSequence = diagnosticPublishSequenceByURL[url, default: 0]
        let encoding = await resolvedPositionEncoding()
        guard let latestSnapshot = openDocuments[url],
              latestSnapshot.version == snapshot.version,
              latestSnapshot.text == snapshot.text,
              diagnosticPublishSequenceByURL[url, default: 0] == publishSequence,
              !diagnosticsRequiringFreshPublish.contains(url) else {
            return nil
        }
        return normalizedDiagnostics(
            diagnostics,
            snapshot: snapshot,
            encoding: encoding
        )
    }

    private func normalizedDiagnostics(
        _ diagnostics: [Diagnostic],
        snapshot: SourceSnapshot,
        encoding: LSPPositionEncoding
    ) -> [NormalizedDiagnostic] {
        diagnostics.compactMap { diagnostic in
            guard let range = utf8Range(
                diagnostic.range,
                snapshot: snapshot,
                encoding: encoding
            ) else {
                return nil
            }
            return NormalizedDiagnostic(
                snapshotVersion: snapshot.version,
                utf8Range: range,
                startLine: diagnostic.range.start.line,
                severity: diagnostic.severity,
                code: diagnostic.code,
                source: diagnostic.source,
                message: diagnostic.message
            )
        }
    }

    /// Whether `method` is currently usable, per static `initialize`
    /// capabilities (`staticallyAdvertised`) or a subsequent read-only
    /// dynamic registration.
    private func isAvailable(_ method: LanguageClientOutboundMethod, staticallyAdvertised: Bool) async -> Bool {
        guard let connection else {
            return false
        }
        return await connection.isAvailable(method, staticallyAdvertised: staticallyAdvertised)
    }

    // MARK: - Requests

    public func hover(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> Hover? {
        let connection = try connected()
        try requireOpenAndCurrent(snapshot)
        let encoding = await resolvedPositionEncoding()
        let position = try snapshot.position(forUTF8Offset: utf8Offset, encoding: encoding)

        let hover: Hover? = try await connection.sendRequest(
            .hover,
            params: HoverParams(
                textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: snapshot.url)),
                position: LSPPosition(line: position.line, character: position.character)
            ),
            priority: .interactive
        )
        guard let hover else {
            return nil
        }
        // A hover range outside the (possibly now-stale) snapshot is
        // discarded rather than shown against the wrong text (SPEC 6.3).
        if let range = hover.range, utf8Range(range, snapshot: snapshot, encoding: encoding) == nil {
            return Hover(contents: hover.contents, range: nil)
        }
        return hover
    }

    public func definition(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> [NavigationTarget] {
        try await navigationRequest(
            .definition,
            snapshot: snapshot,
            utf8Offset: utf8Offset,
            priority: .interactive
        ) { (result: DefinitionResult) in
            result.locations
        }
    }

    public func declaration(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> [NavigationTarget] {
        let advertised = await capabilities()?.declarationProvider?.isEnabled == true
        guard await isAvailable(.declaration, staticallyAdvertised: advertised) else {
            throw LanguageWorkspaceServiceError.capabilityUnavailable("textDocument/declaration")
        }
        return try await navigationRequest(.declaration, snapshot: snapshot, utf8Offset: utf8Offset) { (result: DeclarationResult) in
            result.locations
        }
    }

    public func typeDefinition(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> [NavigationTarget] {
        let advertised = await capabilities()?.typeDefinitionProvider?.isEnabled == true
        guard await isAvailable(.typeDefinition, staticallyAdvertised: advertised) else {
            throw LanguageWorkspaceServiceError.capabilityUnavailable("textDocument/typeDefinition")
        }
        return try await navigationRequest(.typeDefinition, snapshot: snapshot, utf8Offset: utf8Offset) { (result: TypeDefinitionResult) in
            result.locations
        }
    }

    public func implementation(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> [NavigationTarget] {
        let advertised = await capabilities()?.implementationProvider?.isEnabled == true
        guard await isAvailable(.implementation, staticallyAdvertised: advertised) else {
            throw LanguageWorkspaceServiceError.capabilityUnavailable("textDocument/implementation")
        }
        return try await navigationRequest(.implementation, snapshot: snapshot, utf8Offset: utf8Offset) { (result: ImplementationResult) in
            result.locations
        }
    }

    private func navigationRequest<Result: Decodable & Sendable>(
        _ method: LanguageClientOutboundMethod,
        snapshot: SourceSnapshot,
        utf8Offset: Int,
        priority: LanguageClientRequestPriority = .normal,
        locations: (Result) -> [LSPLocation]
    ) async throws -> [NavigationTarget] {
        let connection = try connected()
        try requireOpenAndCurrent(snapshot)
        let encoding = await resolvedPositionEncoding()
        let position = try snapshot.position(forUTF8Offset: utf8Offset, encoding: encoding)

        let result: Result = try await connection.sendRequest(
            method,
            params: TextDocumentPositionParams(
                textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: snapshot.url)),
                position: LSPPosition(line: position.line, character: position.character)
            ),
            priority: priority
        )
        return locations(result).compactMap(validatedNavigationTarget)
    }

    public func references(snapshot: SourceSnapshot, utf8Offset: Int, includeDeclaration: Bool) async throws -> [NavigationTarget] {
        let connection = try connected()
        try requireOpenAndCurrent(snapshot)
        let encoding = await resolvedPositionEncoding()
        let position = try snapshot.position(forUTF8Offset: utf8Offset, encoding: encoding)

        let locations: ReferenceResult = try await connection.sendRequest(
            .references,
            params: ReferenceParams(
                textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: snapshot.url)),
                position: LSPPosition(line: position.line, character: position.character),
                context: ReferenceContext(includeDeclaration: includeDeclaration)
            )
        )
        return (locations ?? []).compactMap(validatedNavigationTarget)
    }

    public func documentHighlights(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> [ValidatedDocumentHighlight] {
        let advertised = await capabilities()?.documentHighlightProvider?.isEnabled == true
        guard await isAvailable(.documentHighlight, staticallyAdvertised: advertised) else {
            throw LanguageWorkspaceServiceError.capabilityUnavailable("textDocument/documentHighlight")
        }
        let connection = try connected()
        try requireOpenAndCurrent(snapshot)
        let encoding = await resolvedPositionEncoding()
        let position = try snapshot.position(forUTF8Offset: utf8Offset, encoding: encoding)

        let highlights: DocumentHighlightResult = try await connection.sendRequest(
            .documentHighlight,
            params: TextDocumentPositionParams(
                textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: snapshot.url)),
                position: LSPPosition(line: position.line, character: position.character)
            )
        )
        return highlights.compactMap { highlight in
            guard let range = utf8Range(highlight.range, snapshot: snapshot, encoding: encoding) else {
                return nil
            }
            return ValidatedDocumentHighlight(utf8Range: range, kind: highlight.kind)
        }
    }

    public func documentSymbols(snapshot: SourceSnapshot) async throws -> [ValidatedDocumentSymbol] {
        let connection = try connected()
        try requireOpenAndCurrent(snapshot)
        let encoding = await resolvedPositionEncoding()

        let result: DocumentSymbolResult = try await connection.sendRequest(
            .documentSymbol,
            params: DocumentSymbolParams(textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: snapshot.url)))
        )

        switch result {
        case .none:
            return []
        case .hierarchical(let symbols):
            return symbols.compactMap { validated($0, snapshot: snapshot, encoding: encoding) }
        case .flat(let symbols):
            return symbols.compactMap { info -> ValidatedDocumentSymbol? in
                guard info.location.uri.fileURL == snapshot.url,
                      let range = utf8Range(info.location.range, snapshot: snapshot, encoding: encoding) else {
                    return nil
                }
                return ValidatedDocumentSymbol(
                    name: info.name,
                    detail: info.containerName,
                    kind: info.kind,
                    utf8Range: range,
                    utf8SelectionRange: range,
                    children: []
                )
            }
        }
    }

    public func workspaceSymbols(query: String) async throws -> [WorkspaceSymbolLocation] {
        let connection = try connected()
        let results: WorkspaceSymbolResult = try await connection.sendRequest(
            .workspaceSymbol,
            params: WorkspaceSymbolParams(query: query)
        )
        let workspaceRoot = identity.root.standardizedFileURL.path
        return results.compactMap { info -> WorkspaceSymbolLocation? in
            guard let url = info.location.uri.fileURL else {
                return nil
            }
            // Defensive: never surface a "workspace" symbol whose server-
            // reported location falls outside the trusted workspace root.
            guard url.standardizedFileURL.path.hasPrefix(workspaceRoot) else {
                return nil
            }
            return WorkspaceSymbolLocation(
                url: url,
                range: info.location.range,
                name: info.name,
                kind: info.kind,
                containerName: info.containerName
            )
        }
    }

    /// Pull diagnostics (`textDocument/diagnostic`). Capability-gated:
    /// throws `.capabilityUnavailable` rather than silently returning
    /// nothing when the server never advertised `diagnosticProvider`, so
    /// callers can report the exact limitation instead of assuming "no
    /// problems" (per the no-silent-fallback requirement).
    public func pullDiagnostics(snapshot: SourceSnapshot) async throws -> [Diagnostic] {
        let connection = try connected()
        try requireOpenAndCurrent(snapshot)
        guard await connection.serverCapabilities?.diagnosticProvider != nil else {
            throw LanguageWorkspaceServiceError.capabilityUnavailable("textDocument/diagnostic (pull diagnostics)")
        }
        let report: DocumentDiagnosticReport = try await connection.sendRequest(
            .diagnostic,
            params: DocumentDiagnosticParams(textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: snapshot.url)))
        )
        guard report.kind == "full" else {
            return []
        }
        return report.items ?? []
    }

    /// Capability-gated full semantic tokens for `snapshot`. Throws
    /// `.capabilityUnavailable` when the server never advertised
    /// `semanticTokensProvider.full`. Range/delta semantic tokens are not
    /// implemented in this phase; that limitation is reported the same
    /// way rather than silently downgraded to nothing.
    public func semanticTokens(snapshot: SourceSnapshot) async throws -> [SemanticToken] {
        let connection = try connected()
        try requireOpenAndCurrent(snapshot)
        guard let provider = await connection.serverCapabilities?.semanticTokensProvider,
              provider.full?.isEnabled == true else {
            throw LanguageWorkspaceServiceError.capabilityUnavailable("textDocument/semanticTokens/full")
        }
        let legend = provider.legend
        let encoding = await resolvedPositionEncoding()

        let tokens: SemanticTokens = try await connection.sendRequest(
            .semanticTokensFull,
            params: SemanticTokensParams(textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: snapshot.url))),
            priority: .background
        )
        return Self.decode(tokens, legend: legend, snapshot: snapshot, encoding: encoding)
    }

    public func foldingRanges(snapshot: SourceSnapshot) async throws -> [ValidatedFoldingRange] {
        let advertised = await capabilities()?.foldingRangeProvider?.isEnabled == true
        guard await isAvailable(.foldingRange, staticallyAdvertised: advertised) else {
            throw LanguageWorkspaceServiceError.capabilityUnavailable("textDocument/foldingRange")
        }
        let connection = try connected()
        try requireOpenAndCurrent(snapshot)

        let ranges: FoldingRangeResult = try await connection.sendRequest(
            .foldingRange,
            params: FoldingRangeParams(textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: snapshot.url)))
        )
        return ranges.compactMap { range in
            guard range.startLine >= 0, range.endLine >= range.startLine, range.endLine < snapshot.lineCount else {
                return nil
            }
            return ValidatedFoldingRange(startLine: range.startLine, endLine: range.endLine, kind: range.kind)
        }
    }

    public func selectionRanges(snapshot: SourceSnapshot, utf8Offsets: [Int]) async throws -> [ValidatedSelectionRange] {
        let advertised = await capabilities()?.selectionRangeProvider?.isEnabled == true
        guard await isAvailable(.selectionRange, staticallyAdvertised: advertised) else {
            throw LanguageWorkspaceServiceError.capabilityUnavailable("textDocument/selectionRange")
        }
        let connection = try connected()
        try requireOpenAndCurrent(snapshot)
        let encoding = await resolvedPositionEncoding()
        let positions = try utf8Offsets.map { offset -> LSPPosition in
            let position = try snapshot.position(forUTF8Offset: offset, encoding: encoding)
            return LSPPosition(line: position.line, character: position.character)
        }

        let result: SelectionRangeResult = try await connection.sendRequest(
            .selectionRange,
            params: SelectionRangeParams(
                textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: snapshot.url)),
                positions: positions
            )
        )
        return result.compactMap { validatedSelectionRange($0, snapshot: snapshot, encoding: encoding) }
    }

    public func documentLinks(snapshot: SourceSnapshot) async throws -> [ValidatedDocumentLink] {
        let advertised = await capabilities()?.documentLinkProvider?.isEnabled == true
        guard await isAvailable(.documentLink, staticallyAdvertised: advertised) else {
            throw LanguageWorkspaceServiceError.capabilityUnavailable("textDocument/documentLink")
        }
        let connection = try connected()
        try requireOpenAndCurrent(snapshot)
        let encoding = await resolvedPositionEncoding()

        let links: DocumentLinkResult? = try await connection.sendRequest(
            .documentLink,
            params: DocumentLinkParams(textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: snapshot.url)))
        )
        return (links ?? []).compactMap { link -> ValidatedDocumentLink? in
            guard let safeLink = SafeDocumentLink.validating(link),
                  let range = utf8Range(link.range, snapshot: snapshot, encoding: encoding) else {
                return nil
            }
            return ValidatedDocumentLink(utf8Range: range, target: safeLink.target, tooltip: safeLink.tooltip)
        }
    }

    public func inlayHints(snapshot: SourceSnapshot, utf8Range requestedRange: Range<Int>) async throws -> [ValidatedInlayHint] {
        let advertised = await capabilities()?.inlayHintProvider?.isEnabled == true
        guard await isAvailable(.inlayHint, staticallyAdvertised: advertised) else {
            throw LanguageWorkspaceServiceError.capabilityUnavailable("textDocument/inlayHint")
        }
        let connection = try connected()
        try requireOpenAndCurrent(snapshot)
        let encoding = await resolvedPositionEncoding()
        let startPosition = try snapshot.position(forUTF8Offset: requestedRange.lowerBound, encoding: encoding)
        let endPosition = try snapshot.position(forUTF8Offset: requestedRange.upperBound, encoding: encoding)

        let hints: InlayHintResult = try await connection.sendRequest(
            .inlayHint,
            params: InlayHintParams(
                textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: snapshot.url)),
                range: LSPRange(
                    start: LSPPosition(line: startPosition.line, character: startPosition.character),
                    end: LSPPosition(line: endPosition.line, character: endPosition.character)
                )
            )
        )
        return (hints ?? []).compactMap { hint -> ValidatedInlayHint? in
            guard let offset = try? snapshot.utf8Offset(
                for: SourcePosition(line: hint.position.line, character: hint.position.character),
                encoding: encoding
            ) else {
                return nil
            }
            return ValidatedInlayHint(
                utf8Offset: offset,
                label: hint.label.displayText,
                kind: hint.kind,
                paddingLeft: hint.paddingLeft ?? false,
                paddingRight: hint.paddingRight ?? false
            )
        }
    }

    /// Explicit-request-only signature help (SPEC 6.1): Kod calls this
    /// only in direct response to a user action on the currently
    /// selected symbol, never automatically while typing.
    public func signatureHelp(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> SignatureHelp? {
        let advertised = await capabilities()?.signatureHelpProvider?.isEnabled == true
        guard await isAvailable(.signatureHelp, staticallyAdvertised: advertised) else {
            throw LanguageWorkspaceServiceError.capabilityUnavailable("textDocument/signatureHelp")
        }
        let connection = try connected()
        try requireOpenAndCurrent(snapshot)
        let encoding = await resolvedPositionEncoding()
        let position = try snapshot.position(forUTF8Offset: utf8Offset, encoding: encoding)

        return try? await connection.sendRequest(
            .signatureHelp,
            params: SignatureHelpParams(
                textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: snapshot.url)),
                position: LSPPosition(line: position.line, character: position.character)
            )
        )
    }

    // MARK: - Call hierarchy

    public func prepareCallHierarchy(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> [ValidatedHierarchyItem] {
        let advertised = await capabilities()?.callHierarchyProvider?.isEnabled == true
        guard await isAvailable(.prepareCallHierarchy, staticallyAdvertised: advertised) else {
            throw LanguageWorkspaceServiceError.capabilityUnavailable("textDocument/prepareCallHierarchy")
        }
        let connection = try connected()
        try requireOpenAndCurrent(snapshot)
        let encoding = await resolvedPositionEncoding()
        let position = try snapshot.position(forUTF8Offset: utf8Offset, encoding: encoding)

        let items: CallHierarchyPrepareResult = try await connection.sendRequest(
            .prepareCallHierarchy,
            params: CallHierarchyPrepareParams(
                textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: snapshot.url)),
                position: LSPPosition(line: position.line, character: position.character)
            )
        )
        return (items ?? []).compactMap(validatedHierarchyItem)
    }

    public func callHierarchyIncomingCalls(item: ValidatedHierarchyItem) async throws -> [ValidatedIncomingCall] {
        let connection = try connected()
        let calls: CallHierarchyIncomingCallsResult = try await connection.sendRequest(
            .callHierarchyIncomingCalls,
            params: CallHierarchyIncomingCallsParams(item: wireItem(item))
        )
        return (calls ?? []).compactMap { call in
            guard let from = validatedHierarchyItem(call.from) else {
                return nil
            }
            return ValidatedIncomingCall(from: from, fromRanges: call.fromRanges)
        }
    }

    public func callHierarchyOutgoingCalls(item: ValidatedHierarchyItem) async throws -> [ValidatedOutgoingCall] {
        let connection = try connected()
        let calls: CallHierarchyOutgoingCallsResult = try await connection.sendRequest(
            .callHierarchyOutgoingCalls,
            params: CallHierarchyOutgoingCallsParams(item: wireItem(item))
        )
        return (calls ?? []).compactMap { call in
            guard let to = validatedHierarchyItem(call.to) else {
                return nil
            }
            return ValidatedOutgoingCall(to: to, fromRanges: call.fromRanges)
        }
    }

    // MARK: - Type hierarchy

    public func prepareTypeHierarchy(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> [ValidatedHierarchyItem] {
        let advertised = await capabilities()?.typeHierarchyProvider?.isEnabled == true
        guard await isAvailable(.prepareTypeHierarchy, staticallyAdvertised: advertised) else {
            throw LanguageWorkspaceServiceError.capabilityUnavailable("textDocument/prepareTypeHierarchy")
        }
        let connection = try connected()
        try requireOpenAndCurrent(snapshot)
        let encoding = await resolvedPositionEncoding()
        let position = try snapshot.position(forUTF8Offset: utf8Offset, encoding: encoding)

        let items: TypeHierarchyPrepareResult = try await connection.sendRequest(
            .prepareTypeHierarchy,
            params: TypeHierarchyPrepareParams(
                textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: snapshot.url)),
                position: LSPPosition(line: position.line, character: position.character)
            )
        )
        return (items ?? []).compactMap(validatedHierarchyItem)
    }

    public func typeHierarchySupertypes(item: ValidatedHierarchyItem) async throws -> [ValidatedHierarchyItem] {
        let connection = try connected()
        let results: TypeHierarchySupertypesResult = try await connection.sendRequest(
            .typeHierarchySupertypes,
            params: TypeHierarchySupertypesParams(item: wireTypeHierarchyItem(item))
        )
        return (results ?? []).compactMap(validatedHierarchyItem)
    }

    public func typeHierarchySubtypes(item: ValidatedHierarchyItem) async throws -> [ValidatedHierarchyItem] {
        let connection = try connected()
        let results: TypeHierarchySubtypesResult = try await connection.sendRequest(
            .typeHierarchySubtypes,
            params: TypeHierarchySubtypesParams(item: wireTypeHierarchyItem(item))
        )
        return (results ?? []).compactMap(validatedHierarchyItem)
    }

    // MARK: - Helpers

    private func connected() throws -> LanguageServerConnection {
        guard let connection else {
            throw LanguageWorkspaceServiceError.notStarted
        }
        return connection
    }

    private func requireOpenAndCurrent(_ snapshot: SourceSnapshot) throws {
        guard let openSnapshot = openDocuments[snapshot.url.standardizedFileURL] else {
            throw LanguageWorkspaceServiceError.documentNotOpen(snapshot.url)
        }
        guard openSnapshot.version == snapshot.version else {
            throw LanguageWorkspaceServiceError.staleRequest(
                url: snapshot.url,
                expectedVersion: openSnapshot.version,
                actualVersion: snapshot.version
            )
        }
    }

    private func utf8Range(_ range: LSPRange, snapshot: SourceSnapshot, encoding: LSPPositionEncoding) -> Range<Int>? {
        guard let start = try? snapshot.utf8Offset(
            for: SourcePosition(line: range.start.line, character: range.start.character),
            encoding: encoding
        ), let end = try? snapshot.utf8Offset(
            for: SourcePosition(line: range.end.line, character: range.end.character),
            encoding: encoding
        ), start <= end else {
            return nil
        }
        return start..<end
    }

    private func validated(
        _ symbol: DocumentSymbol,
        snapshot: SourceSnapshot,
        encoding: LSPPositionEncoding
    ) -> ValidatedDocumentSymbol? {
        guard let range = utf8Range(symbol.range, snapshot: snapshot, encoding: encoding),
              let selectionRange = utf8Range(symbol.selectionRange, snapshot: snapshot, encoding: encoding) else {
            return nil
        }
        let children = symbol.children.compactMap { validated($0, snapshot: snapshot, encoding: encoding) }
        return ValidatedDocumentSymbol(
            name: symbol.name,
            detail: symbol.detail,
            kind: symbol.kind,
            utf8Range: range,
            utf8SelectionRange: selectionRange,
            children: children
        )
    }

    private func validatedSelectionRange(
        _ range: SelectionRange,
        snapshot: SourceSnapshot,
        encoding: LSPPositionEncoding
    ) -> ValidatedSelectionRange? {
        guard let utf8Range = utf8Range(range.range, snapshot: snapshot, encoding: encoding) else {
            return nil
        }
        let parent = range.parent.flatMap { validatedSelectionRange($0, snapshot: snapshot, encoding: encoding) }
        return ValidatedSelectionRange(utf8Range: utf8Range, parent: parent)
    }

    /// Structural-only validation for a cross-file location: a
    /// same-process, absolute `file://` URI with a non-negative,
    /// non-inverted range. Full UTF-8 byte-offset validation happens once
    /// (if) a caller actually opens the target file's own snapshot.
    private func validatedNavigationTarget(_ location: LSPLocation) -> NavigationTarget? {
        guard let url = location.uri.fileURL, isStructurallyValid(location.range) else {
            return nil
        }
        return NavigationTarget(url: url, range: location.range)
    }

    private func isStructurallyValid(_ range: LSPRange) -> Bool {
        range.start.line >= 0 && range.start.character >= 0
            && range.end.line >= 0 && range.end.character >= 0
            && (range.start.line, range.start.character) <= (range.end.line, range.end.character)
    }

    private func validatedHierarchyItem(_ item: CallHierarchyItem) -> ValidatedHierarchyItem? {
        guard let url = item.uri.fileURL, isStructurallyValid(item.range), isStructurallyValid(item.selectionRange) else {
            return nil
        }
        return ValidatedHierarchyItem(
            name: item.name, kind: item.kind, detail: item.detail, url: url,
            range: item.range, selectionRange: item.selectionRange, data: item.data
        )
    }

    private func validatedHierarchyItem(_ item: TypeHierarchyItem) -> ValidatedHierarchyItem? {
        guard let url = item.uri.fileURL, isStructurallyValid(item.range), isStructurallyValid(item.selectionRange) else {
            return nil
        }
        return ValidatedHierarchyItem(
            name: item.name, kind: item.kind, detail: item.detail, url: url,
            range: item.range, selectionRange: item.selectionRange, data: item.data
        )
    }

    /// Re-wraps a previously validated hierarchy item back into its wire
    /// shape to send in a follow-up request, carrying its opaque `data`
    /// through completely unmodified (never inspected or reconstructed).
    private func wireItem(_ item: ValidatedHierarchyItem) -> CallHierarchyItem {
        CallHierarchyItem(
            name: item.name, kind: item.kind, detail: item.detail,
            uri: DocumentURI(fileURL: item.url), range: item.range,
            selectionRange: item.selectionRange, data: item.data
        )
    }

    private func wireTypeHierarchyItem(_ item: ValidatedHierarchyItem) -> TypeHierarchyItem {
        TypeHierarchyItem(
            name: item.name, kind: item.kind, detail: item.detail,
            uri: DocumentURI(fileURL: item.url), range: item.range,
            selectionRange: item.selectionRange, data: item.data
        )
    }

    private static func decode(
        _ tokens: SemanticTokens,
        legend: ServerCapabilities.SemanticTokensOptions.Legend,
        snapshot: SourceSnapshot,
        encoding: LSPPositionEncoding
    ) -> [SemanticToken] {
        var results: [SemanticToken] = []
        results.reserveCapacity(tokens.data.count / 5)

        var line = 0
        var character = 0
        var index = 0
        let data = tokens.data
        while index + 4 < data.count {
            let deltaLine = Int(data[index])
            let deltaStart = Int(data[index + 1])
            let length = Int(data[index + 2])
            let typeIndex = Int(data[index + 3])
            let modifierBits = data[index + 4]
            index += 5

            line += deltaLine
            character = deltaLine == 0 ? character + deltaStart : deltaStart
            guard line >= 0, character >= 0, length >= 0 else {
                continue
            }

            guard let startOffset = try? snapshot.utf8Offset(
                for: SourcePosition(line: line, character: character),
                encoding: encoding
            ) else {
                continue
            }
            let endPosition = SourcePosition(line: line, character: character + length)
            guard let endOffset = try? snapshot.utf8Offset(for: endPosition, encoding: encoding),
                  startOffset < endOffset else {
                continue
            }

            let tokenType = legend.tokenTypes.indices.contains(typeIndex) ? legend.tokenTypes[typeIndex] : "unknown"
            var modifiers: [String] = []
            for bit in 0..<legend.tokenModifiers.count where modifierBits & (1 << bit) != 0 {
                modifiers.append(legend.tokenModifiers[bit])
            }
            results.append(SemanticToken(utf8Range: startOffset..<endOffset, tokenType: tokenType, tokenModifiers: modifiers))
        }
        return results
    }
}
