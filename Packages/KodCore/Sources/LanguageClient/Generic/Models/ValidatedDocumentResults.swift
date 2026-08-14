import Foundation

// Snapshot-validated document results (SPEC 6.1/6.3). Every type here
// has already been converted out of LSP wire coordinates into UTF-8 byte
// offsets against one exact immutable `SourceSnapshot`, so a consumer
// can use it directly without re-deriving offsets — and anything that
// did not resolve inside that snapshot was discarded rather than
// surfaced at the wrong place.

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
