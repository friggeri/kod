import Foundation

// Wire-level models for Phase 7's remaining read-only LSP capabilities
// (SPEC 6.1): declaration, type definition, implementation, document
// highlight, inlay hints, explicit signature help, call hierarchy, type
// hierarchy, folding ranges, selection ranges, and document links.
// Every type here is `Decodable`-only unless Kod must echo an opaque
// server-provided value back verbatim (call/type hierarchy `data`), in
// which case it is `Codable` so the round trip never reconstructs or
// reinterprets that value. None of these types model a server's
// `resolve`/`command` fields Kod doesn't send resolve requests for
// (`documentLink/resolve`, `inlayHint/resolve`) or that could carry a
// mutating command, so even a server that returns one is structurally
// unable to have it interpreted or executed.

// MARK: - Declaration / type definition / implementation
//
// All three share `Location | Location[] | LocationLink[] | null`, the
// same shape as `textDocument/definition` (LSP 3.17 §3.17.1.4-1.6).

public typealias DeclarationResult = DefinitionResult
public typealias TypeDefinitionResult = DefinitionResult
public typealias ImplementationResult = DefinitionResult
public typealias DeclarationParams = TextDocumentPositionParams
public typealias TypeDefinitionParams = TextDocumentPositionParams
public typealias ImplementationParams = TextDocumentPositionParams

// MARK: - Document highlight

public struct DocumentHighlight: Decodable, Sendable {
    public enum Kind: Int, Decodable, Sendable {
        case text = 1
        case read = 2
        case write = 3
    }

    public let range: LSPRange
    public let kind: Kind?
}

public typealias DocumentHighlightParams = TextDocumentPositionParams
public typealias DocumentHighlightResult = [DocumentHighlight]

// MARK: - Folding ranges

public struct FoldingRange: Decodable, Sendable {
    public let startLine: Int
    public let startCharacter: Int?
    public let endLine: Int
    public let endCharacter: Int?
    public let kind: String?
}

public struct FoldingRangeParams: Encodable, Sendable {
    public let textDocument: TextDocumentIdentifier

    public init(textDocument: TextDocumentIdentifier) {
        self.textDocument = textDocument
    }
}

public typealias FoldingRangeResult = [FoldingRange]

// MARK: - Selection ranges
//
// Recursive by construction (`parent` walks outward); modeled as a
// reference type for the same reason as `DocumentSymbol.children`.

public final class SelectionRange: Decodable, Sendable {
    public let range: LSPRange
    public let parent: SelectionRange?

    public init(range: LSPRange, parent: SelectionRange?) {
        self.range = range
        self.parent = parent
    }
}

public struct SelectionRangeParams: Encodable, Sendable {
    public let textDocument: TextDocumentIdentifier
    public let positions: [LSPPosition]

    public init(textDocument: TextDocumentIdentifier, positions: [LSPPosition]) {
        self.textDocument = textDocument
        self.positions = positions
    }
}

public typealias SelectionRangeResult = [SelectionRange]

// MARK: - Document links
//
// `target` is validated by `SafeDocumentLink` (see below), never trusted
// as-is: an LSP `DocumentLink.target` can carry any URI scheme, and some
// servers/extensions use non-`file`/`http(s)` schemes (e.g. `command:`)
// to trigger client-side actions — Kod must never navigate to or open
// one of those (SPEC 13.2, "no mutation escape hatch").

public struct DocumentLink: Decodable, Sendable {
    public let range: LSPRange
    public let target: DocumentURI?
    public let tooltip: String?
}

public struct DocumentLinkParams: Encodable, Sendable {
    public let textDocument: TextDocumentIdentifier

    public init(textDocument: TextDocumentIdentifier) {
        self.textDocument = textDocument
    }
}

public typealias DocumentLinkResult = [DocumentLink]

/// A `DocumentLink` whose `target` has been validated to be safe to
/// display/open: only `file:` (resolved to an absolute, existing path)
/// or `https`/`http` schemes are accepted. Anything else — `command:`,
/// `vscode:`, a relative/malformed URI, or a missing target — is
/// rejected rather than silently normalized into something clickable.
public struct SafeDocumentLink: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case file(URL)
        case web(URL)
    }

    public let range: LSPRange
    public let target: Target
    public let tooltip: String?

    /// Returns `nil` (not a validation error — just "not safe to show")
    /// for any link Kod should silently omit from the surfaced list.
    public static func validating(_ link: DocumentLink) -> SafeDocumentLink? {
        guard let target = link.target, let url = URL(string: target.stringValue) else {
            return nil
        }
        switch url.scheme?.lowercased() {
        case "file":
            return SafeDocumentLink(range: link.range, target: .file(url), tooltip: link.tooltip)
        case "https", "http":
            return SafeDocumentLink(range: link.range, target: .web(url), tooltip: link.tooltip)
        default:
            return nil
        }
    }
}

// MARK: - Inlay hints

public enum InlayHintKind: Int, Decodable, Sendable {
    case type = 1
    case parameter = 2
}

/// `InlayHintLabelPart` deliberately does not model `location` or
/// `command` — Kod never issues `inlayHint/resolve` and never executes a
/// hint-attached command, so these fields (present or not) are simply
/// never decoded.
public struct InlayHintLabelPart: Decodable, Sendable {
    public let value: String
}

/// `InlayHint.label` is `string | InlayHintLabelPart[]`.
public enum InlayHintLabel: Decodable, Sendable {
    case string(String)
    case parts([InlayHintLabelPart])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        self = .parts(try container.decode([InlayHintLabelPart].self))
    }

    public var displayText: String {
        switch self {
        case .string(let value):
            return value
        case .parts(let parts):
            return parts.map(\.value).joined()
        }
    }
}

/// Deliberately omits `textEdits` (only present on a resolved hint, which
/// Kod never requests) and `command`.
public struct InlayHint: Decodable, Sendable {
    public let position: LSPPosition
    public let label: InlayHintLabel
    public let kind: InlayHintKind?
    public let paddingLeft: Bool?
    public let paddingRight: Bool?
}

public struct InlayHintParams: Encodable, Sendable {
    public let textDocument: TextDocumentIdentifier
    public let range: LSPRange

    public init(textDocument: TextDocumentIdentifier, range: LSPRange) {
        self.textDocument = textDocument
        self.range = range
    }
}

/// `textDocument/inlayHint` returns `InlayHint[] | null`.
public typealias InlayHintResult = [InlayHint]?

// MARK: - Signature help
//
// Kod only ever sends this on an explicit user request for the currently
// selected symbol (SPEC 6.1: "when explicitly requested"), never as a
// side effect of typing — Kod never sends keystroke-driven `didChange`
// content in the first place (SPEC 6.3).

public enum ParameterLabel: Decodable, Sendable {
    case string(String)
    case range(UInt32, UInt32)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        let pair = try container.decode([UInt32].self)
        guard pair.count == 2 else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a 2-element offset pair")
        }
        self = .range(pair[0], pair[1])
    }
}

public enum DocumentationValue: Decodable, Sendable {
    case string(String)
    case markup(MarkupContent)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        self = .markup(try container.decode(MarkupContent.self))
    }
}

public struct ParameterInformation: Decodable, Sendable {
    public let label: ParameterLabel
    public let documentation: DocumentationValue?
}

public struct SignatureInformation: Decodable, Sendable {
    public let label: String
    public let documentation: DocumentationValue?
    public let parameters: [ParameterInformation]?
    public let activeParameter: Int?
}

public struct SignatureHelp: Decodable, Sendable {
    public let signatures: [SignatureInformation]
    public let activeSignature: Int?
    public let activeParameter: Int?
}

public typealias SignatureHelpParams = TextDocumentPositionParams

// MARK: - Call hierarchy
//
// `data` is an opaque server-defined payload Kod must echo back verbatim
// in follow-up `callHierarchy/incomingCalls`/`outgoingCalls` requests
// without ever interpreting it — modeled as `JSONValue` (itself
// `Codable`) rather than any concrete shape.

public struct CallHierarchyItem: Codable, Sendable {
    public let name: String
    public let kind: SymbolKind
    public let detail: String?
    public let uri: DocumentURI
    public let range: LSPRange
    public let selectionRange: LSPRange
    public let data: JSONValue?
}

public typealias CallHierarchyPrepareParams = TextDocumentPositionParams
/// `textDocument/prepareCallHierarchy` returns `CallHierarchyItem[] | null`.
public typealias CallHierarchyPrepareResult = [CallHierarchyItem]?

public struct CallHierarchyItemParams: Encodable, Sendable {
    public let item: CallHierarchyItem

    public init(item: CallHierarchyItem) {
        self.item = item
    }
}

public typealias CallHierarchyIncomingCallsParams = CallHierarchyItemParams
public typealias CallHierarchyOutgoingCallsParams = CallHierarchyItemParams

public struct CallHierarchyIncomingCall: Decodable, Sendable {
    public let from: CallHierarchyItem
    public let fromRanges: [LSPRange]
}

public struct CallHierarchyOutgoingCall: Decodable, Sendable {
    public let to: CallHierarchyItem
    public let fromRanges: [LSPRange]
}

public typealias CallHierarchyIncomingCallsResult = [CallHierarchyIncomingCall]?
public typealias CallHierarchyOutgoingCallsResult = [CallHierarchyOutgoingCall]?

// MARK: - Type hierarchy

public struct TypeHierarchyItem: Codable, Sendable {
    public let name: String
    public let kind: SymbolKind
    public let detail: String?
    public let uri: DocumentURI
    public let range: LSPRange
    public let selectionRange: LSPRange
    public let data: JSONValue?
}

public typealias TypeHierarchyPrepareParams = TextDocumentPositionParams
public typealias TypeHierarchyPrepareResult = [TypeHierarchyItem]?

public struct TypeHierarchyItemParams: Encodable, Sendable {
    public let item: TypeHierarchyItem

    public init(item: TypeHierarchyItem) {
        self.item = item
    }
}

public typealias TypeHierarchySupertypesParams = TypeHierarchyItemParams
public typealias TypeHierarchySubtypesParams = TypeHierarchyItemParams
public typealias TypeHierarchySupertypesResult = [TypeHierarchyItem]?
public typealias TypeHierarchySubtypesResult = [TypeHierarchyItem]?
