import Foundation

/// The exhaustive allow-list of JSON-RPC methods Kod is willing to send to
/// a language server. `LanguageServerConnection` refuses to send any
/// request or notification whose method is not in this list — there is
/// no generic "send arbitrary request" escape hatch, so a caller can
/// never accidentally invoke `textDocument/rename`, `workspace/applyEdit`,
/// `workspace/executeCommand`, formatting, code actions, or a file
/// operation even by mistake (SPEC 6.1: "Capabilities that imply mutation
/// are not advertised... rejected").
public enum LanguageClientOutboundMethod: String, CaseIterable, Sendable {
    case initialize
    case initialized
    case shutdown
    case exit
    case cancelRequest = "$/cancelRequest"
    case didOpen = "textDocument/didOpen"
    case didChange = "textDocument/didChange"
    case didClose = "textDocument/didClose"
    case hover = "textDocument/hover"
    case definition = "textDocument/definition"
    case references = "textDocument/references"
    case documentSymbol = "textDocument/documentSymbol"
    case workspaceSymbol = "workspace/symbol"
    case diagnostic = "textDocument/diagnostic"
    case workspaceDiagnostic = "workspace/diagnostic"
    case semanticTokensFull = "textDocument/semanticTokens/full"
    case declaration = "textDocument/declaration"
    case typeDefinition = "textDocument/typeDefinition"
    case implementation = "textDocument/implementation"
    case documentHighlight = "textDocument/documentHighlight"
    case foldingRange = "textDocument/foldingRange"
    case selectionRange = "textDocument/selectionRange"
    case documentLink = "textDocument/documentLink"
    case inlayHint = "textDocument/inlayHint"
    case signatureHelp = "textDocument/signatureHelp"
    case prepareCallHierarchy = "textDocument/prepareCallHierarchy"
    case callHierarchyIncomingCalls = "callHierarchy/incomingCalls"
    case callHierarchyOutgoingCalls = "callHierarchy/outgoingCalls"
    case prepareTypeHierarchy = "textDocument/prepareTypeHierarchy"
    case typeHierarchySupertypes = "typeHierarchy/supertypes"
    case typeHierarchySubtypes = "typeHierarchy/subtypes"

    /// The methods a server may legitimately dynamically-register for
    /// via `client/registerCapability` (SPEC 6.1: "Handle dynamic
    /// registration for read-only capabilities while continuing to
    /// reject all mutating registrations"). Lifecycle/sync methods are
    /// included only because they are harmless to allow — Kod always
    /// sends them unconditionally regardless of any registration state,
    /// so a server "registering" for one grants it nothing. Every method
    /// that implies mutation (rename, code actions, formatting, execute
    /// command, file operations, ...) is absent from this list by
    /// construction: it is not a `LanguageClientOutboundMethod` case at
    /// all, so it can never appear here.
    public static let dynamicallyRegistrableReadOnlyMethods: Set<String> = Set(allCases.map(\.rawValue))
}

/// Server-to-client request methods Kod implements a response for. Any
/// other server-to-client request — most importantly every one that
/// implies mutation — is answered with `operationNotPermitted` (for
/// methods Kod recognizes as mutating) or `methodNotFound` (for anything
/// else Kod simply doesn't support), never executed and never silently
/// dropped (SPEC 6.1, 13.2).
public enum LanguageClientInboundMethod: String, Sendable {
    case registerCapability = "client/registerCapability"
    case unregisterCapability = "client/unregisterCapability"
    case applyEdit = "workspace/applyEdit"
    case workspaceConfiguration = "workspace/configuration"
    case workspaceFolders = "workspace/workspaceFolders"
    case createWorkDoneProgress = "window/workDoneProgress/create"
    case showMessageRequest = "window/showMessageRequest"
    case workspaceDiagnosticRefresh = "workspace/diagnostic/refresh"

    /// `applyEdit` is the only request always rejected unconditionally
    /// (Kod is read-only and can never mutate a document — SPEC 13.2).
    /// `registerCapability` gets its own per-registration inspection
    /// (accept only if every registered method is read-only; reject the
    /// whole batch otherwise) rather than a blanket true/false, and
    /// `unregisterCapability` is always safe to accept (removing a
    /// registration can never grant a new capability), so neither is
    /// covered by this flag.
    public var isAlwaysRejected: Bool {
        self == .applyEdit
    }
}

public enum LanguageClientError: Error, Equatable, Sendable {
    /// A caller (internal to Kod) attempted to send a method outside
    /// `LanguageClientOutboundMethod`'s allow-list.
    case mutatingOrUnsupportedOutboundMethod(String)
    case notTrusted
    case notConnected
    case timedOut(method: String)
    case cancelled(method: String)
    case serverError(JSONRPCResponseError)
    case invalidResponse(method: String, reason: String)
    case staleResponse(method: String)
    case processLaunchFailed(String)
    case executableNotFound(String)
}
