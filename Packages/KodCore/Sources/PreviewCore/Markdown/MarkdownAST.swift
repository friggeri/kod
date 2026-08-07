import Foundation

/// One inline (within-a-line) Markdown span. Raw HTML spans are always
/// pre-sanitized text by the time they reach this model (see
/// `MarkdownHTMLSanitizer`); this AST never carries executable markup.
public indirect enum MarkdownInline: Equatable, Sendable {
    case text(String)
    case softBreak
    case hardBreak
    case emphasis([MarkdownInline])
    case strong([MarkdownInline])
    case strikethrough([MarkdownInline])
    case code(String)
    case link(destination: MarkdownDestination, title: String?, children: [MarkdownInline])
    case image(destination: MarkdownDestination, title: String?, altText: String)
    /// Sanitized raw inline HTML, rendered as literal text (never parsed
    /// as markup by the renderer) — see SPEC 10.1's "Raw HTML is
    /// sanitized; scripts never run."
    case sanitizedHTML(String)
}

public enum MarkdownListKind: Equatable, Sendable {
    case unordered(marker: Character)
    case ordered(start: Int, delimiter: Character)
}

/// One row of a GFM table.
public struct MarkdownTableRow: Equatable, Sendable {
    public let cells: [[MarkdownInline]]

    public init(cells: [[MarkdownInline]]) {
        self.cells = cells
    }
}

public enum MarkdownTableAlignment: Equatable, Sendable {
    case none
    case left
    case center
    case right
}

/// A single Markdown list item: its own block content plus, for GFM task
/// lists, whether it has a checkbox and its checked state.
public struct MarkdownListItem: Equatable, Sendable {
    public let checked: Bool?
    public let blocks: [MarkdownBlock]

    public init(checked: Bool?, blocks: [MarkdownBlock]) {
        self.checked = checked
        self.blocks = blocks
    }
}

/// One block-level Markdown node. `MarkdownParser` builds a document as
/// `[MarkdownBlock]`; container blocks (`blockquote`, `list`) recurse.
public indirect enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, inlines: [MarkdownInline])
    case paragraph([MarkdownInline])
    case blockquote([MarkdownBlock])
    case list(kind: MarkdownListKind, isTight: Bool, items: [MarkdownListItem])
    /// A fenced or indented code block. `language` is the fence's info
    /// string's first word (lowercased), used to select a `SyntaxCore`
    /// grammar for highlighting; `nil` for indented code blocks or an
    /// unrecognized/absent info string.
    case codeBlock(language: String?, code: String)
    case thematicBreak
    case table(alignments: [MarkdownTableAlignment], header: MarkdownTableRow, rows: [MarkdownTableRow])
    /// A sanitized raw HTML block, rendered as literal preformatted text.
    case sanitizedHTMLBlock(String)
}

/// A fully-parsed Markdown source document: the ordered top-level blocks
/// plus every diagnostic the sanitizer produced while stripping unsafe raw
/// HTML (SPEC 10.1) — surfaced, never silently discarded, matching Kod's
/// "no silent sanitization failure" requirement.
public struct MarkdownDocument: Equatable, Sendable {
    public let blocks: [MarkdownBlock]
    public let sanitizerDiagnostics: [String]

    public init(blocks: [MarkdownBlock], sanitizerDiagnostics: [String]) {
        self.blocks = blocks
        self.sanitizerDiagnostics = sanitizerDiagnostics
    }
}
