import Foundation
import SourceModel
import WorkspaceCore

public enum SwiftLanguageServiceError: Error, Equatable, Sendable {
    case notTrusted
    case notStarted
    case documentNotOpen(URL)
    case staleRequest(url: URL, expectedVersion: Int, actualVersion: Int)
    case capabilityUnavailable(String)
    case invalidTargetURI(String)

    init(_ error: LanguageWorkspaceServiceError) {
        switch error {
        case .notTrusted:
            self = .notTrusted
        case .notStarted:
            self = .notStarted
        case .documentNotOpen(let url):
            self = .documentNotOpen(url)
        case .staleRequest(let url, let expectedVersion, let actualVersion):
            self = .staleRequest(url: url, expectedVersion: expectedVersion, actualVersion: actualVersion)
        case .capabilityUnavailable(let feature):
            self = .capabilityUnavailable(feature)
        case .invalidTargetURI(let uri):
            self = .invalidTargetURI(uri)
        }
    }
}

/// Owns exactly one `LanguageServerConnection` (SourceKit-LSP) for one
/// Swift workspace, enforcing SPEC 6/13's trust-before-launch rule and
/// SPEC 6.3's document synchronization and response-validation
/// requirements. `WorkspaceViewController`-level callers own zero or one
/// of these per open workspace, created lazily after trust and the first
/// Swift file is touched.
///
/// This type is a thin, Swift-flavored wrapper around the shared,
/// language-agnostic `LanguageWorkspaceService` engine (Phase 7):
/// its own public API and `SwiftLanguageServiceError` are unchanged
/// from Phase 6, but the implementation is now shared with every other
/// language adapter (TypeScript/JavaScript, HTML/CSS, Python, Rust)
/// rather than duplicated.
public actor SwiftWorkspaceLanguageService {
    public struct Dependencies: Sendable {
        public var discoverExecutable: @Sendable () throws -> URL
        public var connectionFactory: @Sendable (
            LanguageServerConnection.Configuration,
            @escaping @Sendable (LanguageServerState) -> Void,
            @escaping @Sendable (ServerNotification) -> Void
        ) -> LanguageServerConnection

        public init(
            discoverExecutable: @escaping @Sendable () throws -> URL = {
                try SourceKitLSPDiscovery.discoverExecutableURL()
            },
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

    /// The full semantic token type/modifier legend Kod requests and
    /// understands. Anything a server's own legend maps to outside this
    /// list is still decoded (index-based) but reported under its raw
    /// name so the decoration layer can no-op unknown types gracefully.
    public static let semanticTokenTypes = [
        "namespace", "type", "class", "enum", "interface", "struct", "typeParameter",
        "parameter", "variable", "property", "enumMember", "function", "method",
        "macro", "keyword", "modifier", "comment", "string", "number", "regexp", "operator"
    ]
    public static let semanticTokenModifiers = [
        "declaration", "definition", "readonly", "static", "deprecated", "abstract",
        "async", "modification", "documentation", "defaultLibrary"
    ]

    private let core: LanguageWorkspaceService

    public init(
        identity: WorkspaceIdentity,
        trustStore: WorkspaceTrustStore,
        dependencies: Dependencies = Dependencies(),
        onStateChange: @escaping @Sendable (LanguageServerState) -> Void = { _ in },
        onDiagnostics: @escaping @Sendable (URL, [NormalizedDiagnostic]) -> Void = { _, _ in }
    ) {
        core = LanguageWorkspaceService(
            identity: identity,
            trustStore: trustStore,
            configuration: LanguageWorkspaceService.Configuration(
                languageId: "swift",
                semanticTokenTypes: Self.semanticTokenTypes,
                semanticTokenModifiers: Self.semanticTokenModifiers
            ),
            dependencies: LanguageWorkspaceService.Dependencies(
                discoverExecutable: dependencies.discoverExecutable,
                connectionFactory: dependencies.connectionFactory
            ),
            onStateChange: onStateChange,
            onDiagnostics: onDiagnostics
        )
    }

    public var currentState: LanguageServerState? {
        get async {
            await core.currentState
        }
    }

    // MARK: - Lifecycle

    public func start() async throws {
        try await rethrowing { try await core.start() }
    }

    public func restart() async throws {
        try await rethrowing { try await core.restart() }
    }

    public func stop() async {
        await core.stop()
    }

    // MARK: - Document synchronization

    public func didOpen(_ snapshot: SourceSnapshot) async throws {
        try await rethrowing { try await core.didOpen(snapshot) }
    }

    public func didChange(_ snapshot: SourceSnapshot) async throws {
        try await rethrowing { try await core.didChange(snapshot) }
    }

    public func didClose(url: URL) async throws {
        try await rethrowing { try await core.didClose(url: url) }
    }

    // MARK: - Capability gating

    public func capabilities() async -> ServerCapabilities? {
        await core.capabilities()
    }

    // MARK: - Requests

    public func hover(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> Hover? {
        try await rethrowing { try await core.hover(snapshot: snapshot, utf8Offset: utf8Offset) }
    }

    public func definition(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> [NavigationTarget] {
        try await rethrowing { try await core.definition(snapshot: snapshot, utf8Offset: utf8Offset) }
    }

    public func declaration(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> [NavigationTarget] {
        try await rethrowing { try await core.declaration(snapshot: snapshot, utf8Offset: utf8Offset) }
    }

    public func typeDefinition(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> [NavigationTarget] {
        try await rethrowing { try await core.typeDefinition(snapshot: snapshot, utf8Offset: utf8Offset) }
    }

    public func implementation(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> [NavigationTarget] {
        try await rethrowing { try await core.implementation(snapshot: snapshot, utf8Offset: utf8Offset) }
    }

    public func references(snapshot: SourceSnapshot, utf8Offset: Int, includeDeclaration: Bool) async throws -> [NavigationTarget] {
        try await rethrowing { try await core.references(snapshot: snapshot, utf8Offset: utf8Offset, includeDeclaration: includeDeclaration) }
    }

    public func documentHighlights(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> [ValidatedDocumentHighlight] {
        try await rethrowing { try await core.documentHighlights(snapshot: snapshot, utf8Offset: utf8Offset) }
    }

    public func documentSymbols(snapshot: SourceSnapshot) async throws -> [ValidatedDocumentSymbol] {
        try await rethrowing { try await core.documentSymbols(snapshot: snapshot) }
    }

    public func workspaceSymbols(query: String) async throws -> [WorkspaceSymbolLocation] {
        try await rethrowing { try await core.workspaceSymbols(query: query) }
    }

    public func pullDiagnostics(snapshot: SourceSnapshot) async throws -> [Diagnostic] {
        try await rethrowing { try await core.pullDiagnostics(snapshot: snapshot) }
    }

    public func semanticTokens(snapshot: SourceSnapshot) async throws -> [SemanticToken] {
        try await rethrowing { try await core.semanticTokens(snapshot: snapshot) }
    }

    public func foldingRanges(snapshot: SourceSnapshot) async throws -> [ValidatedFoldingRange] {
        try await rethrowing { try await core.foldingRanges(snapshot: snapshot) }
    }

    public func selectionRanges(snapshot: SourceSnapshot, utf8Offsets: [Int]) async throws -> [ValidatedSelectionRange] {
        try await rethrowing { try await core.selectionRanges(snapshot: snapshot, utf8Offsets: utf8Offsets) }
    }

    public func documentLinks(snapshot: SourceSnapshot) async throws -> [ValidatedDocumentLink] {
        try await rethrowing { try await core.documentLinks(snapshot: snapshot) }
    }

    public func inlayHints(snapshot: SourceSnapshot, utf8Range: Range<Int>) async throws -> [ValidatedInlayHint] {
        try await rethrowing { try await core.inlayHints(snapshot: snapshot, utf8Range: utf8Range) }
    }

    public func signatureHelp(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> SignatureHelp? {
        try await rethrowing { try await core.signatureHelp(snapshot: snapshot, utf8Offset: utf8Offset) }
    }

    public func prepareCallHierarchy(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> [ValidatedHierarchyItem] {
        try await rethrowing { try await core.prepareCallHierarchy(snapshot: snapshot, utf8Offset: utf8Offset) }
    }

    public func callHierarchyIncomingCalls(item: ValidatedHierarchyItem) async throws -> [ValidatedIncomingCall] {
        try await rethrowing { try await core.callHierarchyIncomingCalls(item: item) }
    }

    public func callHierarchyOutgoingCalls(item: ValidatedHierarchyItem) async throws -> [ValidatedOutgoingCall] {
        try await rethrowing { try await core.callHierarchyOutgoingCalls(item: item) }
    }

    public func prepareTypeHierarchy(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> [ValidatedHierarchyItem] {
        try await rethrowing { try await core.prepareTypeHierarchy(snapshot: snapshot, utf8Offset: utf8Offset) }
    }

    public func typeHierarchySupertypes(item: ValidatedHierarchyItem) async throws -> [ValidatedHierarchyItem] {
        try await rethrowing { try await core.typeHierarchySupertypes(item: item) }
    }

    public func typeHierarchySubtypes(item: ValidatedHierarchyItem) async throws -> [ValidatedHierarchyItem] {
        try await rethrowing { try await core.typeHierarchySubtypes(item: item) }
    }

    // MARK: - Error mapping

    /// Converts a thrown `LanguageWorkspaceServiceError` (the generic
    /// engine's error type) back into `SwiftLanguageServiceError` so
    /// existing Swift-facing call sites and tests see exactly the error
    /// type they did in Phase 6. Any other error (timeouts, decode
    /// failures, etc.) passes through unchanged.
    private func rethrowing<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as LanguageWorkspaceServiceError {
            throw SwiftLanguageServiceError(error)
        }
    }
}
