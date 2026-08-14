import Foundation
import SourceIO
import SourceModel
import SyntaxCore
import ThemeCore

/// Maps a fenced code block's info-string language token to one of Kod's
/// compiled-in Tree-sitter grammars (SPEC 10.1: "Syntax highlighting in
/// fenced code uses Kod's built-in Tree-sitter grammars"), accepting the
/// common aliases Markdown authors actually type (```js`, ```ts, ```py,
/// ```rs`, ...) in addition to the canonical names. Returns `nil` — plain,
/// unhighlighted code text — for anything outside SPEC 4.2's seven launch
/// languages; this is an explicit, documented limitation, not a silent
/// failure, and the code block itself always still renders as ordinary
/// monospaced text.
enum MarkdownFenceLanguage {
    static func syntaxLanguage(forFenceLanguage language: String?) -> SyntaxLanguage? {
        guard let language else {
            return nil
        }
        switch language.lowercased() {
        case "swift": return .swift
        case "typescript", "ts": return .typescript
        case "tsx": return .tsx
        case "javascript", "js", "jsx", "mjs", "cjs": return .javascript
        case "html", "htm": return .html
        case "css": return .css
        case "python", "py", "py3": return .python
        case "rust", "rs": return .rust
        default: return nil
        }
    }
}

/// One themed run of fenced-code text, mirroring `SyntaxCapture` but
/// already resolved to a concrete `TokenStyle` for the active theme so the
/// App layer never needs its own theme-resolution logic for Markdown code
/// blocks.
public struct MarkdownCodeRun: Equatable, Sendable {
    public let utf8Range: Range<Int>
    public let style: TokenStyle

    public init(utf8Range: Range<Int>, style: TokenStyle) {
        self.utf8Range = utf8Range
        self.style = style
    }
}

/// One styled run of rendered inline text — the flattened, renderer-ready
/// form of `MarkdownInline`.
public struct MarkdownRenderRun: Equatable, Sendable {
    public var text: String
    public var isBold = false
    public var isItalic = false
    public var isStrikethrough = false
    public var isCode = false
    public var isSoftBreak = false
    public var isHardBreak = false
    /// True for a run produced from a Markdown `![alt](url)` image
    /// reference — `text` is then the alt text, and `link` the image's
    /// destination, distinct from an ordinary `[text](url)` link run so
    /// callers can apply SPEC 10.1's separate image-loading policy
    /// instead of treating it as a clickable link.
    public var isImage = false
    public var link: MarkdownDestination?
    public var linkTitle: String?

    public init(
        text: String,
        isBold: Bool = false,
        isItalic: Bool = false,
        isStrikethrough: Bool = false,
        isCode: Bool = false,
        isSoftBreak: Bool = false,
        isHardBreak: Bool = false,
        isImage: Bool = false,
        link: MarkdownDestination? = nil,
        linkTitle: String? = nil
    ) {
        self.text = text
        self.isBold = isBold
        self.isItalic = isItalic
        self.isStrikethrough = isStrikethrough
        self.isCode = isCode
        self.isSoftBreak = isSoftBreak
        self.isHardBreak = isHardBreak
        self.isImage = isImage
        self.link = link
        self.linkTitle = linkTitle
    }
}

/// The rendered (as opposed to source) form of one block-level Markdown
/// node, ready for a native attributed/document renderer (SPEC 10.1
/// prefers this over WebKit).
public indirect enum MarkdownRenderBlock: Equatable, Sendable {
    case heading(level: Int, runs: [MarkdownRenderRun])
    case paragraph(runs: [MarkdownRenderRun])
    case blockquote([MarkdownRenderBlock])
    case list(kind: MarkdownListKind, isTight: Bool, items: [MarkdownRenderBlock])
    case listItem(checked: Bool?, blocks: [MarkdownRenderBlock])
    case codeBlock(language: String?, sourceText: String, highlightedRuns: [MarkdownCodeRun])
    case thematicBreak
    case table(alignments: [MarkdownTableAlignment], header: [[MarkdownRenderRun]], rows: [[[MarkdownRenderRun]]])
    case rawHTML(String)
    case image(destination: MarkdownDestination, title: String?, altText: String)
}

public struct MarkdownRenderDocument: Equatable, Sendable {
    public let blocks: [MarkdownRenderBlock]
    public let sanitizerDiagnostics: [String]

    public init(blocks: [MarkdownRenderBlock], sanitizerDiagnostics: [String]) {
        self.blocks = blocks
        self.sanitizerDiagnostics = sanitizerDiagnostics
    }
}

public enum MarkdownRenderer {
    /// Renders a parsed `MarkdownDocument` into `MarkdownRenderDocument`,
    /// syntax-highlighting each fenced code block through the exact same
    /// `SyntaxCore`/`ThemeCore` pipeline `CodeViewport` uses for full
    /// source files — SPEC 10.1's "Reuse SourceModel, CodeViewport,
    /// SyntaxCore, ThemeCore; do not create a second source rendering
    /// path" applies as much to fenced code as it does to a whole file.
    /// `async` only because that highlighting goes through the real,
    /// actor-isolated `SyntaxEngine`; a fenced block in a language Kod
    /// does not compile a grammar for, or one that fails to parse, still
    /// renders — as plain, unhighlighted monospaced text.
    public static func render(_ document: MarkdownDocument, theme: KodTheme) async -> MarkdownRenderDocument {
        let engine = SyntaxEngine()
        var blocks: [MarkdownRenderBlock] = []
        for block in document.blocks {
            blocks.append(await render(block, theme: theme, engine: engine))
        }
        return MarkdownRenderDocument(blocks: blocks, sanitizerDiagnostics: document.sanitizerDiagnostics)
    }

    private static func render(_ block: MarkdownBlock, theme: KodTheme, engine: SyntaxEngine) async -> MarkdownRenderBlock {
        switch block {
        case .heading(let level, let inlines):
            return .heading(level: level, runs: renderRuns(inlines))
        case .paragraph(let inlines):
            return .paragraph(runs: renderRuns(inlines))
        case .blockquote(let inner):
            var rendered: [MarkdownRenderBlock] = []
            for child in inner {
                rendered.append(await render(child, theme: theme, engine: engine))
            }
            return .blockquote(rendered)
        case .list(let kind, let isTight, let items):
            var itemBlocks: [MarkdownRenderBlock] = []
            for item in items {
                var blocksForItem: [MarkdownRenderBlock] = []
                for child in item.blocks {
                    blocksForItem.append(await render(child, theme: theme, engine: engine))
                }
                itemBlocks.append(.listItem(checked: item.checked, blocks: blocksForItem))
            }
            return .list(kind: kind, isTight: isTight, items: itemBlocks)
        case .codeBlock(let language, let code):
            let runs = await highlightedRuns(code: code, language: language, theme: theme, engine: engine)
            return .codeBlock(language: language, sourceText: code, highlightedRuns: runs)
        case .thematicBreak:
            return .thematicBreak
        case .table(let alignments, let header, let rows):
            return .table(
                alignments: alignments,
                header: header.cells.map(renderRuns),
                rows: rows.map { $0.cells.map(renderRuns) }
            )
        case .sanitizedHTMLBlock(let text):
            return .rawHTML(text)
        }
    }

    private static func renderRuns(_ inlines: [MarkdownInline]) -> [MarkdownRenderRun] {
        var runs: [MarkdownRenderRun] = []
        func walk(_ nodes: [MarkdownInline], bold: Bool, italic: Bool, strikethrough: Bool, link: MarkdownDestination?, linkTitle: String?) {
            for node in nodes {
                switch node {
                case .text(let text):
                    runs.append(MarkdownRenderRun(text: text, isBold: bold, isItalic: italic, isStrikethrough: strikethrough, link: link, linkTitle: linkTitle))
                case .softBreak:
                    runs.append(MarkdownRenderRun(text: "", isSoftBreak: true, link: link))
                case .hardBreak:
                    runs.append(MarkdownRenderRun(text: "", isHardBreak: true, link: link))
                case .emphasis(let children):
                    walk(children, bold: bold, italic: true, strikethrough: strikethrough, link: link, linkTitle: linkTitle)
                case .strong(let children):
                    walk(children, bold: true, italic: italic, strikethrough: strikethrough, link: link, linkTitle: linkTitle)
                case .strikethrough(let children):
                    walk(children, bold: bold, italic: italic, strikethrough: true, link: link, linkTitle: linkTitle)
                case .code(let code):
                    runs.append(MarkdownRenderRun(text: code, isCode: true, link: link, linkTitle: linkTitle))
                case .link(let destination, let title, let children):
                    walk(children, bold: bold, italic: italic, strikethrough: strikethrough, link: destination, linkTitle: title)
                case .image(let destination, let title, let altText):
                    runs.append(MarkdownRenderRun(text: altText, isImage: true, link: destination, linkTitle: title))
                case .sanitizedHTML(let text):
                    runs.append(MarkdownRenderRun(text: text, link: link, linkTitle: linkTitle))
                }
            }
        }
        walk(inlines, bold: false, italic: false, strikethrough: false, link: nil, linkTitle: nil)
        return runs
    }

    private static func highlightedRuns(
        code: String,
        language: String?,
        theme: KodTheme,
        engine: SyntaxEngine
    ) async -> [MarkdownCodeRun] {
        guard let syntaxLanguage = MarkdownFenceLanguage.syntaxLanguage(forFenceLanguage: language) else {
            return []
        }
        let snapshot = SourceSnapshot(text: code)
        guard SourceRenderingSafetyPolicy.codeViewportDefault.reason(
            fileByteCount: snapshot.originalData.count,
            longestLineUTF8Length: snapshot.longestLineUTF8Length
        ) == nil else {
            return []
        }
        do {
            let tree = try await engine.parse(snapshot: snapshot, language: syntaxLanguage)
            let captures = tree.captures(inByteRange: 0..<snapshot.utf8Count)
            return captures.map { capture in
                MarkdownCodeRun(utf8Range: capture.utf8Range, style: theme.lexicalStyle(forCapture: capture.name))
            }
        } catch {
            // Parsing a small fenced snippet failing never blocks the
            // rest of the document; the code still renders as plain
            // monospaced text.
            return []
        }
    }
}
