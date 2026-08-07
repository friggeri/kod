import Foundation

public struct TextDocumentItem: Codable, Sendable {
    public let uri: DocumentURI
    public let languageId: String
    public let version: Int
    public let text: String

    public init(uri: DocumentURI, languageId: String, version: Int, text: String) {
        self.uri = uri
        self.languageId = languageId
        self.version = version
        self.text = text
    }
}

public struct DidOpenTextDocumentParams: Encodable, Sendable {
    public let textDocument: TextDocumentItem

    public init(textDocument: TextDocumentItem) {
        self.textDocument = textDocument
    }
}

/// Kod always sends whole-document sync (`TextDocumentSyncKind.full`):
/// every `didChange` carries the complete new text with no `range`, which
/// keeps synchronization trivially correct for Kod's read-only, external-
/// change-driven model (SPEC 6.3) without needing incremental diffing.
public struct TextDocumentContentChangeEvent: Encodable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public struct DidChangeTextDocumentParams: Encodable, Sendable {
    public let textDocument: VersionedTextDocumentIdentifier
    public let contentChanges: [TextDocumentContentChangeEvent]

    public init(textDocument: VersionedTextDocumentIdentifier, contentChanges: [TextDocumentContentChangeEvent]) {
        self.textDocument = textDocument
        self.contentChanges = contentChanges
    }
}

public struct DidCloseTextDocumentParams: Encodable, Sendable {
    public let textDocument: TextDocumentIdentifier

    public init(textDocument: TextDocumentIdentifier) {
        self.textDocument = textDocument
    }
}

// MARK: - Hover

public struct MarkupContent: Decodable, Equatable, Sendable {
    public let kind: String
    public let value: String
}

/// `Hover.contents` is `MarkedString | MarkedString[] | MarkupContent` in
/// the spec; SourceKit-LSP always sends `MarkupContent`, so that's the
/// only shape modeled. A server sending a legacy shape simply fails to
/// decode, surfacing as a capability limitation rather than silently
/// showing nothing.
public struct Hover: Decodable, Sendable {
    public let contents: MarkupContent
    public let range: LSPRange?
}

public typealias HoverParams = TextDocumentPositionParams

// MARK: - Definition / References

/// `textDocument/definition` returns `Location | Location[] | LocationLink[] | null`.
public enum DefinitionResult: Decodable, Sendable {
    case none
    case locations([LSPLocation])
    case links([LSPLocationLink])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
            return
        }
        if let single = try? container.decode(LSPLocation.self) {
            self = .locations([single])
            return
        }
        if let locations = try? container.decode([LSPLocation].self) {
            self = .locations(locations)
            return
        }
        if let links = try? container.decode([LSPLocationLink].self) {
            self = .links(links)
            return
        }
        self = .none
    }

    public var locations: [LSPLocation] {
        switch self {
        case .none:
            return []
        case .locations(let locations):
            return locations
        case .links(let links):
            return links.map { LSPLocation(uri: $0.targetUri, range: $0.targetSelectionRange) }
        }
    }
}

public typealias DefinitionParams = TextDocumentPositionParams

public struct ReferenceContext: Encodable, Sendable {
    public let includeDeclaration: Bool

    public init(includeDeclaration: Bool) {
        self.includeDeclaration = includeDeclaration
    }
}

public struct ReferenceParams: Encodable, Sendable {
    public let textDocument: TextDocumentIdentifier
    public let position: LSPPosition
    public let context: ReferenceContext

    public init(textDocument: TextDocumentIdentifier, position: LSPPosition, context: ReferenceContext) {
        self.textDocument = textDocument
        self.position = position
        self.context = context
    }
}

// MARK: - Symbols

public enum SymbolKind: Int, Codable, Sendable {
    case file = 1, module, namespace, package, `class`, method, property, field
    case constructor, `enum`, interface, function, variable, constant, string, number
    case boolean, array, object, key, null, enumMember, structType, event, `operator`
    case typeParameter

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(Int.self)
        self = SymbolKind(rawValue: raw) ?? .file
    }

    /// A lowercase, human-readable name for this kind — "function",
    /// "class", "struct", etc. — used anywhere a symbol's kind needs to
    /// be spoken or displayed as text rather than an icon alone (SPEC 14:
    /// symbols sidebar rows, and `CodeAccessibilityAnnotation.symbol`'s
    /// rotor label in `CodeViewportAccessibility.swift`, both want the
    /// exact same vocabulary).
    public var displayName: String {
        switch self {
        case .file: return "file"
        case .module: return "module"
        case .namespace: return "namespace"
        case .package: return "package"
        case .class: return "class"
        case .method: return "method"
        case .property: return "property"
        case .field: return "field"
        case .constructor: return "constructor"
        case .enum: return "enum"
        case .interface: return "interface"
        case .function: return "function"
        case .variable: return "variable"
        case .constant: return "constant"
        case .string: return "string"
        case .number: return "number"
        case .boolean: return "boolean"
        case .array: return "array"
        case .object: return "object"
        case .key: return "key"
        case .null: return "null"
        case .enumMember: return "enum case"
        case .structType: return "struct"
        case .event: return "event"
        case .operator: return "operator"
        case .typeParameter: return "type parameter"
        }
    }
}

/// `textDocument/documentSymbol` result is `DocumentSymbol[] | SymbolInformation[]`.
/// SourceKit-LSP returns hierarchical `DocumentSymbol`, which is the only
/// shape modeled directly; a flat `SymbolInformation[]` result is
/// converted into single-level `DocumentSymbol`s for a uniform surface.
public final class DocumentSymbol: Decodable, Sendable {
    public let name: String
    public let detail: String?
    public let kind: SymbolKind
    public let range: LSPRange
    public let selectionRange: LSPRange
    public let children: [DocumentSymbol]

    private enum CodingKeys: String, CodingKey {
        case name, detail, kind, range, selectionRange, children
    }

    public init(
        name: String,
        detail: String?,
        kind: SymbolKind,
        range: LSPRange,
        selectionRange: LSPRange,
        children: [DocumentSymbol]
    ) {
        self.name = name
        self.detail = detail
        self.kind = kind
        self.range = range
        self.selectionRange = selectionRange
        self.children = children
    }

    /// LSP 3.17 §3.17.0.20 marks `children` optional (a leaf symbol has
    /// none); several real servers (e.g. `vscode-css-language-server`)
    /// omit the key entirely rather than sending `[]`. Decoding this
    /// with the compiler-synthesized initializer would require the key
    /// and reject every leaf symbol from such a server.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        kind = try container.decode(SymbolKind.self, forKey: .kind)
        range = try container.decode(LSPRange.self, forKey: .range)
        selectionRange = try container.decode(LSPRange.self, forKey: .selectionRange)
        children = try container.decodeIfPresent([DocumentSymbol].self, forKey: .children) ?? []
    }
}

public struct SymbolInformation: Decodable, Sendable {
    public let name: String
    public let kind: SymbolKind
    public let location: LSPLocation
    public let containerName: String?
}

public enum DocumentSymbolResult: Decodable, Sendable {
    case none
    case hierarchical([DocumentSymbol])
    case flat([SymbolInformation])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
            return
        }
        if let hierarchical = try? container.decode([DocumentSymbol].self) {
            self = .hierarchical(hierarchical)
            return
        }
        if let flat = try? container.decode([SymbolInformation].self) {
            self = .flat(flat)
            return
        }
        self = .none
    }
}

public struct DocumentSymbolParams: Encodable, Sendable {
    public let textDocument: TextDocumentIdentifier

    public init(textDocument: TextDocumentIdentifier) {
        self.textDocument = textDocument
    }
}

public struct WorkspaceSymbolParams: Encodable, Sendable {
    public let query: String

    public init(query: String) {
        self.query = query
    }
}

public typealias WorkspaceSymbolResult = [SymbolInformation]

// MARK: - Diagnostics

public enum DiagnosticSeverity: Int, Decodable, Sendable {
    case error = 1
    case warning = 2
    case information = 3
    case hint = 4
}

public struct Diagnostic: Decodable, Sendable {
    public let range: LSPRange
    public let severity: DiagnosticSeverity?
    public let code: JSONValue?
    public let source: String?
    public let message: String

    public init(range: LSPRange, severity: DiagnosticSeverity?, code: JSONValue?, source: String?, message: String) {
        self.range = range
        self.severity = severity
        self.code = code
        self.source = source
        self.message = message
    }
}

public struct PublishDiagnosticsParams: Decodable, Sendable {
    public let uri: DocumentURI
    public let version: Int?
    public let diagnostics: [Diagnostic]
}

public struct DocumentDiagnosticParams: Encodable, Sendable {
    public let textDocument: TextDocumentIdentifier

    public init(textDocument: TextDocumentIdentifier) {
        self.textDocument = textDocument
    }
}

/// `textDocument/diagnostic` (pull) returns a `DocumentDiagnosticReport`,
/// either `full` (with a fresh diagnostics array) or `unchanged` (client
/// should keep what it already has). Only `full` is meaningful for Kod's
/// stateless-per-request pull usage, so `unchanged` simply yields `nil`
/// and callers keep the previously published set.
public struct DocumentDiagnosticReport: Decodable, Sendable {
    public let kind: String
    public let items: [Diagnostic]?

    private enum CodingKeys: String, CodingKey {
        case kind
        case items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        items = try container.decodeIfPresent([Diagnostic].self, forKey: .items)
    }
}

// MARK: - Semantic tokens

public struct SemanticTokensParams: Encodable, Sendable {
    public let textDocument: TextDocumentIdentifier

    public init(textDocument: TextDocumentIdentifier) {
        self.textDocument = textDocument
    }
}

/// `data` is a flat array of relative-encoded 5-tuples per LSP 3.17
/// §3.17.6: `[deltaLine, deltaStartChar, length, tokenType, tokenModifiers]`.
public struct SemanticTokens: Decodable, Sendable {
    public let resultId: String?
    public let data: [UInt32]
}

// MARK: - Cancellation / progress

public struct CancelParams: Encodable, Sendable {
    public let id: JSONRPCID

    public init(id: JSONRPCID) {
        self.id = id
    }
}

public struct ProgressParams: Decodable, Sendable {
    public let token: ProgressToken
    public let value: JSONValue
}

public struct WorkDoneProgressCreateParams: Decodable, Sendable {
    public let token: ProgressToken
}

/// The `kind`-discriminated payload carried inside `$/progress` for
/// work-done progress: `begin` (with title/percentage), `report`
/// (incremental updates), and `end`.
public struct WorkDoneProgressValue: Sendable {
    public enum Kind: String, Sendable {
        case begin
        case report
        case end
    }

    public let kind: Kind
    public let title: String?
    public let message: String?
    public let percentage: Int?
    public let cancellable: Bool?

    public init?(jsonValue: JSONValue) {
        guard case .object(let fields) = jsonValue,
              case .string(let kindString)? = fields["kind"],
              let kind = Kind(rawValue: kindString) else {
            return nil
        }
        self.kind = kind
        if case .string(let title)? = fields["title"] {
            self.title = title
        } else {
            self.title = nil
        }
        if case .string(let message)? = fields["message"] {
            self.message = message
        } else {
            self.message = nil
        }
        if case .number(let percentage)? = fields["percentage"] {
            self.percentage = Int(percentage)
        } else {
            self.percentage = nil
        }
        if case .bool(let cancellable)? = fields["cancellable"] {
            self.cancellable = cancellable
        } else {
            self.cancellable = nil
        }
    }
}
