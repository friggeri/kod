import CCMarkGFMExtensions
import Foundation

/// Parses formal GitHub Flavored Markdown through the pinned, vendored
/// cmark-gfm implementation and converts its tree into Kod's renderer-neutral,
/// security-focused AST.
public enum MarkdownParser {
    public static func parse(_ source: String, limits: MarkdownLimits = .default) -> MarkdownDocument {
        guard source.utf8.count <= limits.maximumSourceByteCount else {
            return MarkdownDocument(
                blocks: [.paragraph([.text("Source exceeds the \(limits.maximumSourceByteCount)-byte Markdown preview limit; showing source view only.")])],
                sanitizerDiagnostics: []
            )
        }

        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let prepass = DangerousElementStripper.strip(
            normalized,
            elementNames: ["script", "style", "iframe", "object", "embed", "template", "noscript", "form"]
        )

        let root = prepass.text.utf8CString.withUnsafeBufferPointer { buffer in
            kod_cmark_parse_gfm(buffer.baseAddress, max(0, buffer.count - 1))
        }
        guard let root else {
            return MarkdownDocument(
                blocks: [.paragraph([.text("Markdown preview could not parse this document; showing source view only.")])],
                sanitizerDiagnostics: prepass.removedConstructs + ["cmark-gfm failed to create a document tree"]
            )
        }
        defer { cmark_node_free(root) }

        var converter = CMarkConverter(
            limits: limits,
            sanitizerDiagnostics: prepass.removedConstructs
        )
        return MarkdownDocument(
            blocks: converter.convertDocument(root),
            sanitizerDiagnostics: converter.sanitizerDiagnostics
        )
    }
}

private struct CMarkConverter {
    typealias Node = UnsafeMutablePointer<cmark_node>

    let limits: MarkdownLimits
    var sanitizerDiagnostics: [String]
    private var blockCount = 0
    private var didReportNodeLimit = false

    init(limits: MarkdownLimits, sanitizerDiagnostics: [String]) {
        self.limits = limits
        self.sanitizerDiagnostics = sanitizerDiagnostics
    }

    mutating func convertDocument(_ root: Node) -> [MarkdownBlock] {
        guard kod_cmark_node_get_kind(root) == KOD_CMARK_DOCUMENT else {
            sanitizerDiagnostics.append("cmark-gfm returned a non-document root")
            return [.paragraph([.text("(invalid Markdown tree)")])]
        }
        return convertBlockChildren(of: root, depth: 0)
    }

    private mutating func convertBlockChildren(of parent: Node, depth: Int) -> [MarkdownBlock] {
        guard depth <= limits.maximumBlockDepth else {
            sanitizerDiagnostics.append("Markdown container nesting exceeded the preview depth limit")
            return [.paragraph([.text("(nesting too deep; truncated)")])]
        }

        var blocks: [MarkdownBlock] = []
        var child = cmark_node_first_child(parent)
        while let node = child {
            guard consumeNode() else {
                blocks.append(.paragraph([.text("(document truncated at the block-count preview limit)")]))
                break
            }
            if let block = convertBlock(node, depth: depth) {
                blocks.append(block)
            }
            child = cmark_node_next(node)
        }
        return blocks
    }

    private mutating func convertBlock(_ node: Node, depth: Int) -> MarkdownBlock? {
        switch kod_cmark_node_get_kind(node) {
        case KOD_CMARK_PARAGRAPH:
            return .paragraph(convertInlineChildren(of: node, depth: 0))
        case KOD_CMARK_HEADING:
            return .heading(
                level: Int(cmark_node_get_heading_level(node)),
                inlines: convertInlineChildren(of: node, depth: 0)
            )
        case KOD_CMARK_BLOCK_QUOTE:
            return .blockquote(convertBlockChildren(of: node, depth: depth + 1))
        case KOD_CMARK_LIST:
            return convertList(node, depth: depth)
        case KOD_CMARK_CODE_BLOCK:
            let info = cString(cmark_node_get_fence_info(node))
            let language = info?
                .split(whereSeparator: \.isWhitespace)
                .first
                .map { String($0).lowercased() }
            var code = cString(cmark_node_get_literal(node)) ?? ""
            if code.hasSuffix("\n") {
                code.removeLast()
            }
            return .codeBlock(language: language?.isEmpty == false ? language : nil, code: code)
        case KOD_CMARK_HTML_BLOCK:
            let sanitized = MarkdownHTMLSanitizer.sanitize(cString(cmark_node_get_literal(node)) ?? "")
            sanitizerDiagnostics.append(contentsOf: sanitized.removedConstructs)
            return .sanitizedHTMLBlock(sanitized.sanitizedText)
        case KOD_CMARK_THEMATIC_BREAK:
            return .thematicBreak
        case KOD_CMARK_TABLE:
            return convertTable(node, depth: depth)
        case KOD_CMARK_UNKNOWN:
            sanitizerDiagnostics.append("Skipped unsupported Markdown block \(nodeTypeName(node))")
            return nil
        default:
            sanitizerDiagnostics.append("Skipped unexpected inline node \(nodeTypeName(node)) at block level")
            return nil
        }
    }

    private mutating func convertList(_ node: Node, depth: Int) -> MarkdownBlock {
        let kind: MarkdownListKind
        if cmark_node_get_list_type(node) == CMARK_ORDERED_LIST {
            let delimiter: Character = cmark_node_get_list_delim(node) == CMARK_PAREN_DELIM ? ")" : "."
            kind = .ordered(start: max(0, Int(cmark_node_get_list_start(node))), delimiter: delimiter)
        } else {
            kind = .unordered(marker: "-")
        }

        var items: [MarkdownListItem] = []
        var child = cmark_node_first_child(node)
        while let itemNode = child {
            guard consumeNode() else {
                items.append(MarkdownListItem(
                    checked: nil,
                    blocks: [.paragraph([.text("(list truncated at the block-count preview limit)")])]
                ))
                break
            }
            if kod_cmark_node_get_kind(itemNode) == KOD_CMARK_ITEM {
                let taskState = kod_cmark_task_state(itemNode)
                let checked: Bool? = taskState < 0 ? nil : taskState == 1
                items.append(MarkdownListItem(
                    checked: checked,
                    blocks: convertBlockChildren(of: itemNode, depth: depth + 1)
                ))
            } else {
                sanitizerDiagnostics.append("Skipped non-item child in Markdown list")
            }
            child = cmark_node_next(itemNode)
        }
        return .list(kind: kind, isTight: cmark_node_get_list_tight(node) != 0, items: items)
    }

    private mutating func convertTable(_ node: Node, depth: Int) -> MarkdownBlock {
        var rowNodes: [Node] = []
        var child = cmark_node_first_child(node)
        while let row = child {
            guard consumeNode() else { break }
            if kod_cmark_node_get_kind(row) == KOD_CMARK_TABLE_ROW {
                rowNodes.append(row)
            }
            child = cmark_node_next(row)
        }

        let declaredColumnCount = rowNodes.first.map { countChildren(of: $0) } ?? 0
        guard declaredColumnCount <= limits.maximumTableColumns else {
            sanitizerDiagnostics.append("GFM table exceeded the \(limits.maximumTableColumns)-column preview limit")
            return .paragraph([.text("(table truncated at the column preview limit)")])
        }

        let alignments = (0..<declaredColumnCount).map { index -> MarkdownTableAlignment in
            switch UnicodeScalar(UInt8(bitPattern: kod_cmark_table_alignment(node, Int32(index)))) {
            case "l": return .left
            case "c": return .center
            case "r": return .right
            default: return .none
            }
        }
        let convertedRows = rowNodes.map { row in
            MarkdownTableRow(cells: convertTableCells(row, depth: depth + 1))
        }
        let header = convertedRows.first ?? MarkdownTableRow(cells: [])
        return .table(alignments: alignments, header: header, rows: Array(convertedRows.dropFirst()))
    }

    private mutating func convertTableCells(_ row: Node, depth: Int) -> [[MarkdownInline]] {
        var cells: [[MarkdownInline]] = []
        var child = cmark_node_first_child(row)
        while let cell = child {
            guard consumeNode() else { break }
            if kod_cmark_node_get_kind(cell) == KOD_CMARK_TABLE_CELL {
                cells.append(convertInlineChildren(of: cell, depth: depth))
            }
            child = cmark_node_next(cell)
        }
        return cells
    }

    private func countChildren(of node: Node) -> Int {
        var count = 0
        var child = cmark_node_first_child(node)
        while let current = child {
            count += 1
            child = cmark_node_next(current)
        }
        return count
    }

    private mutating func convertInlineChildren(of parent: Node, depth: Int) -> [MarkdownInline] {
        guard depth <= limits.maximumInlineDepth else {
            sanitizerDiagnostics.append("Markdown inline nesting exceeded the preview depth limit")
            return [.text("(inline nesting too deep; truncated)")]
        }
        var inlines: [MarkdownInline] = []
        var child = cmark_node_first_child(parent)
        while let node = child {
            if let inline = convertInline(node, depth: depth) {
                inlines.append(inline)
            }
            child = cmark_node_next(node)
        }
        return inlines
    }

    private mutating func convertInline(_ node: Node, depth: Int) -> MarkdownInline? {
        switch kod_cmark_node_get_kind(node) {
        case KOD_CMARK_TEXT:
            return .text(cString(cmark_node_get_literal(node)) ?? "")
        case KOD_CMARK_SOFTBREAK:
            return .softBreak
        case KOD_CMARK_LINEBREAK:
            return .hardBreak
        case KOD_CMARK_CODE:
            return .code(cString(cmark_node_get_literal(node)) ?? "")
        case KOD_CMARK_HTML_INLINE:
            let sanitized = MarkdownHTMLSanitizer.sanitize(cString(cmark_node_get_literal(node)) ?? "")
            sanitizerDiagnostics.append(contentsOf: sanitized.removedConstructs)
            return .sanitizedHTML(sanitized.sanitizedText)
        case KOD_CMARK_EMPH:
            return .emphasis(convertInlineChildren(of: node, depth: depth + 1))
        case KOD_CMARK_STRONG:
            return .strong(convertInlineChildren(of: node, depth: depth + 1))
        case KOD_CMARK_STRIKETHROUGH:
            return .strikethrough(convertInlineChildren(of: node, depth: depth + 1))
        case KOD_CMARK_LINK:
            return .link(
                destination: MarkdownDestination(rawValue: cString(cmark_node_get_url(node)) ?? ""),
                title: nonEmpty(cString(cmark_node_get_title(node))),
                children: convertInlineChildren(of: node, depth: depth + 1)
            )
        case KOD_CMARK_IMAGE:
            return .image(
                destination: MarkdownDestination(rawValue: cString(cmark_node_get_url(node)) ?? ""),
                title: nonEmpty(cString(cmark_node_get_title(node))),
                altText: plainText(of: node)
            )
        case KOD_CMARK_UNKNOWN:
            sanitizerDiagnostics.append("Skipped unsupported Markdown inline \(nodeTypeName(node))")
            return nil
        default:
            sanitizerDiagnostics.append("Skipped unexpected block node \(nodeTypeName(node)) at inline level")
            return nil
        }
    }

    private mutating func plainText(of parent: Node) -> String {
        var result = ""
        var stack = childNodes(of: parent).reversed().map { ($0, 0) }
        while let (node, depth) = stack.popLast() {
            guard depth <= limits.maximumInlineDepth else {
                sanitizerDiagnostics.append("Markdown image alt text exceeded the inline depth limit")
                result += "(alt text truncated)"
                continue
            }
            switch kod_cmark_node_get_kind(node) {
            case KOD_CMARK_TEXT, KOD_CMARK_CODE:
                result += cString(cmark_node_get_literal(node)) ?? ""
            case KOD_CMARK_SOFTBREAK, KOD_CMARK_LINEBREAK:
                result += " "
            default:
                stack.append(contentsOf: childNodes(of: node).reversed().map { ($0, depth + 1) })
            }
        }
        return result
    }

    private func childNodes(of parent: Node) -> [Node] {
        var nodes: [Node] = []
        var child = cmark_node_first_child(parent)
        while let node = child {
            nodes.append(node)
            child = cmark_node_next(node)
        }
        return nodes
    }

    private mutating func consumeNode() -> Bool {
        guard blockCount < limits.maximumBlockCount else {
            if !didReportNodeLimit {
                sanitizerDiagnostics.append("Markdown block count exceeded the preview limit")
                didReportNodeLimit = true
            }
            return false
        }
        blockCount += 1
        return true
    }

    private func cString(_ pointer: UnsafePointer<CChar>?) -> String? {
        pointer.map(String.init(cString:))
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func nodeTypeName(_ node: Node) -> String {
        cString(cmark_node_get_type_string(node)) ?? "<unknown>"
    }
}
