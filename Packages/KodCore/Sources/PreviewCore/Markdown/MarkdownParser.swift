import Foundation

/// Parses Markdown source text into a `MarkdownDocument`: CommonMark's
/// core block/inline model plus GitHub-flavored tables, task lists, and
/// fenced code (SPEC 10.1).
///
/// This is a from-scratch, line-oriented recursive-descent parser, not a
/// full CommonMark-spec-test-suite-conformant implementation — it does not
/// implement every corner of the reference algorithm (list-item lazy
/// continuation across blockquotes, link-reference-definition backtracking
/// across nested containers, and CommonMark's precise emphasis
/// flanking-rule edge cases are all simplified). What it does guarantee,
/// unconditionally, is the security contract in SPEC 10.1: raw HTML is
/// always sanitized through `MarkdownHTMLSanitizer` before it reaches the
/// AST, every link/image destination is classified through
/// `MarkdownDestination` so the renderer can enforce link/image policy,
/// and every recursive descent (blockquotes, nested lists, nested
/// emphasis) is bounded by `MarkdownLimits` so a pathological document
/// cannot overflow the stack or allocate without bound.
public enum MarkdownParser {
    public static func parse(_ source: String, limits: MarkdownLimits = .default) -> MarkdownDocument {
        guard source.utf8.count <= limits.maximumSourceByteCount else {
            return MarkdownDocument(
                blocks: [.paragraph([.text("Source exceeds the \(limits.maximumSourceByteCount)-byte Markdown preview limit; showing source view only.")])],
                sanitizerDiagnostics: []
            )
        }

        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")

        // Strip genuinely dangerous elements (`<script>`, `<style>`,
        // `<iframe>`, ...) across the *entire raw source* before any
        // block/inline boundary is even determined. This has to happen
        // up front rather than inside per-fragment HTML sanitization:
        // CommonMark's inline-HTML model treats each `<tag>` as its own
        // independent span, with ordinary text in between — so a
        // `<script>` opening tag and its `</script>` closing tag are two
        // *separate* inline HTML spans with the actual script body
        // sitting between them as plain paragraph text, never reaching
        // any per-tag sanitizer at all. A single whole-document textual
        // strip (matching same-name open/close tags directly,
        // independent of block/inline parsing) is what actually removes
        // the dangerous payload regardless of where it appears.
        let prepass = DangerousElementStripper.strip(
            normalized,
            elementNames: ["script", "style", "iframe", "object", "embed", "template", "noscript", "form"]
        )
        let lines = prepass.text.split(separator: "\n", omittingEmptySubsequences: false).map { Substring($0) }

        var context = ParseContext(limits: limits)
        context.sanitizerDiagnostics.append(contentsOf: prepass.removedConstructs)
        let blocks = context.parseBlocks(lines[...], depth: 0)
        return MarkdownDocument(blocks: blocks, sanitizerDiagnostics: context.sanitizerDiagnostics)
    }
}

/// Mutable parsing state threaded through the recursive block parser:
/// accumulated sanitizer diagnostics and a running node-count guard.
private struct ParseContext {
    let limits: MarkdownLimits
    var sanitizerDiagnostics: [String] = []
    var blockCount = 0

    mutating func countBlock() -> Bool {
        blockCount += 1
        return blockCount <= limits.maximumBlockCount
    }

    mutating func parseBlocks(_ lines: ArraySlice<Substring>, depth: Int) -> [MarkdownBlock] {
        guard depth <= limits.maximumBlockDepth else {
            return [.paragraph([.text("(nesting too deep; truncated)")])]
        }
        var blocks: [MarkdownBlock] = []
        var index = lines.startIndex

        while index < lines.endIndex {
            guard countBlock() else {
                blocks.append(.paragraph([.text("(document truncated at the block-count preview limit)")]))
                break
            }
            let line = lines[index]

            if isBlankLine(line) {
                index += 1
                continue
            }

            if let breakConsumed = tryThematicBreak(line) {
                blocks.append(.thematicBreak)
                index += breakConsumed
                continue
            }

            if let (level, inlineText) = tryATXHeading(line) {
                blocks.append(.heading(level: level, inlines: parseInline(inlineText, depth: 0)))
                index += 1
                continue
            }

            if let fenceResult = tryFencedCodeBlock(lines, from: index) {
                blocks.append(.codeBlock(language: fenceResult.language, code: fenceResult.code))
                index = fenceResult.nextIndex
                continue
            }

            if isIndentedCodeLine(line), !isInsideListContext {
                let result = consumeIndentedCodeBlock(lines, from: index)
                blocks.append(.codeBlock(language: nil, code: result.code))
                index = result.nextIndex
                continue
            }

            if isBlockquoteStart(line) {
                let result = consumeBlockquote(lines, from: index)
                let innerBlocks = parseBlocks(result.innerLines[...], depth: depth + 1)
                blocks.append(.blockquote(innerBlocks))
                index = result.nextIndex
                continue
            }

            if let htmlResult = tryHTMLBlock(lines, from: index) {
                let sanitized = MarkdownHTMLSanitizer.sanitize(htmlResult.rawHTML)
                sanitizerDiagnostics.append(contentsOf: sanitized.removedConstructs)
                blocks.append(.sanitizedHTMLBlock(sanitized.sanitizedText))
                index = htmlResult.nextIndex
                continue
            }

            if let listResult = tryList(lines, from: index, depth: depth) {
                blocks.append(listResult.block)
                index = listResult.nextIndex
                continue
            }

            if let tableResult = tryTable(lines, from: index) {
                blocks.append(tableResult.block)
                index = tableResult.nextIndex
                continue
            }

            let paragraphResult = consumeParagraph(lines, from: index)
            if let level = paragraphResult.setextLevel {
                blocks.append(.heading(level: level, inlines: parseInline(paragraphResult.text, depth: 0)))
            } else {
                blocks.append(.paragraph(parseInline(paragraphResult.text, depth: 0)))
            }
            index = paragraphResult.nextIndex
        }

        return blocks
    }

    // MARK: - Line classification

    private var isInsideListContext: Bool { false }

    func isBlankLine(_ line: Substring) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    func leadingSpaceCount(_ line: Substring) -> Int {
        var count = 0
        for character in line {
            if character == " " {
                count += 1
            } else if character == "\t" {
                count += 4
            } else {
                break
            }
        }
        return count
    }

    func tryThematicBreak(_ line: Substring) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard leadingSpaceCount(line) < 4, trimmed.count >= 3 else {
            return nil
        }
        guard let marker = trimmed.first, "-*_".contains(marker) else {
            return nil
        }
        let stripped = trimmed.filter { $0 != " " }
        guard stripped.count >= 3, stripped.allSatisfy({ $0 == marker }) else {
            return nil
        }
        return 1
    }

    func tryATXHeading(_ line: Substring) -> (level: Int, text: Substring)? {
        guard leadingSpaceCount(line) < 4 else {
            return nil
        }
        var chars = line.drop { $0 == " " }
        var level = 0
        while chars.first == "#", level < 6 {
            level += 1
            chars.removeFirst()
        }
        guard level > 0, level <= 6 else {
            return nil
        }
        guard chars.isEmpty || chars.first == " " || chars.first == "\t" else {
            return nil // e.g. "#hashtag" is not a heading
        }
        var text = chars.drop { $0 == " " || $0 == "\t" }
        // Strip a trailing closing sequence of '#' characters.
        var trimmedEnd = Substring(text)
        while trimmedEnd.last == " " {
            trimmedEnd.removeLast()
        }
        var closingCount = 0
        var scan = trimmedEnd
        while scan.last == "#" {
            closingCount += 1
            scan.removeLast()
        }
        if closingCount > 0, (scan.isEmpty || scan.last == " ") {
            trimmedEnd = scan
            while trimmedEnd.last == " " {
                trimmedEnd.removeLast()
            }
        }
        text = trimmedEnd
        return (level, text)
    }

    // MARK: - Fenced code blocks

    struct FenceResult {
        let language: String?
        let code: String
        let nextIndex: Int
    }

    func tryFencedCodeBlock(_ lines: ArraySlice<Substring>, from start: Int) -> FenceResult? {
        let line = lines[start]
        guard leadingSpaceCount(line) < 4 else {
            return nil
        }
        let trimmed = line.drop { $0 == " " }
        guard let fenceChar = trimmed.first, fenceChar == "`" || fenceChar == "~" else {
            return nil
        }
        var fenceLength = 0
        var rest = trimmed
        while rest.first == fenceChar {
            fenceLength += 1
            rest.removeFirst()
        }
        guard fenceLength >= 3 else {
            return nil
        }
        if fenceChar == "`", rest.contains("`") {
            return nil // backtick info strings may not contain another backtick
        }
        let infoString = rest.trimmingCharacters(in: .whitespaces)
        let language = infoString.split(separator: " ").first.map { String($0).lowercased() }
        let normalizedLanguage = (language?.isEmpty ?? true) ? nil : language

        var codeLines: [Substring] = []
        var index = start + 1
        while index < lines.endIndex {
            let candidate = lines[index]
            let candidateTrimmed = candidate.drop { $0 == " " }
            if leadingSpaceCount(candidate) < 4,
               candidateTrimmed.allSatisfy({ $0 == fenceChar }),
               candidateTrimmed.count >= fenceLength {
                index += 1
                break
            }
            codeLines.append(candidate)
            index += 1
        }
        return FenceResult(
            language: normalizedLanguage,
            code: codeLines.map(String.init).joined(separator: "\n"),
            nextIndex: index
        )
    }

    // MARK: - Indented code blocks

    func isIndentedCodeLine(_ line: Substring) -> Bool {
        leadingSpaceCount(line) >= 4 && !isBlankLine(line)
    }

    struct IndentedCodeResult {
        let code: String
        let nextIndex: Int
    }

    func consumeIndentedCodeBlock(_ lines: ArraySlice<Substring>, from start: Int) -> IndentedCodeResult {
        var codeLines: [String] = []
        var index = start
        while index < lines.endIndex, isIndentedCodeLine(lines[index]) || isBlankLine(lines[index]) {
            let line = lines[index]
            if isBlankLine(line) {
                codeLines.append("")
            } else {
                codeLines.append(stripIndent(line, count: 4))
            }
            index += 1
        }
        while codeLines.last == "" {
            codeLines.removeLast()
            index -= 1
        }
        return IndentedCodeResult(code: codeLines.joined(separator: "\n"), nextIndex: max(index, start + 1))
    }

    func stripIndent(_ line: Substring, count: Int) -> String {
        var remaining = count
        var chars = line
        while remaining > 0, let first = chars.first, first == " " || first == "\t" {
            remaining -= (first == "\t") ? 4 : 1
            chars.removeFirst()
        }
        return String(chars)
    }

    // MARK: - Blockquotes

    func isBlockquoteStart(_ line: Substring) -> Bool {
        guard leadingSpaceCount(line) < 4 else {
            return false
        }
        let trimmed = line.drop { $0 == " " }
        return trimmed.first == ">"
    }

    struct BlockquoteResult {
        let innerLines: [Substring]
        let nextIndex: Int
    }

    func consumeBlockquote(_ lines: ArraySlice<Substring>, from start: Int) -> BlockquoteResult {
        var innerLines: [Substring] = []
        var index = start
        while index < lines.endIndex {
            let line = lines[index]
            if isBlockquoteStart(line) {
                var rest = line.drop { $0 == " " }
                rest.removeFirst() // '>'
                if rest.first == " " {
                    rest.removeFirst()
                }
                innerLines.append(rest)
                index += 1
            } else if isBlankLine(line) {
                break
            } else {
                // Lazy continuation: a following non-blank, non-`>` line
                // is treated as part of the quote's last paragraph.
                innerLines.append(line)
                index += 1
            }
        }
        return BlockquoteResult(innerLines: innerLines, nextIndex: index)
    }

    // MARK: - HTML blocks

    private static let htmlBlockTagNames: Set<String> = [
        "address", "article", "aside", "base", "blockquote", "body", "caption",
        "center", "col", "colgroup", "dd", "details", "dialog", "dir", "div",
        "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form",
        "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head",
        "header", "hr", "html", "iframe", "legend", "li", "link", "main",
        "menu", "menuitem", "nav", "noframes", "ol", "optgroup", "option",
        "p", "param", "section", "summary", "table", "tbody", "td",
        "tfoot", "th", "thead", "title", "tr", "track", "ul", "script",
        "style", "pre"
    ]

    struct HTMLBlockResult {
        let rawHTML: String
        let nextIndex: Int
    }

    func tryHTMLBlock(_ lines: ArraySlice<Substring>, from start: Int) -> HTMLBlockResult? {
        let line = lines[start]
        guard leadingSpaceCount(line) < 4 else {
            return nil
        }
        let trimmed = line.drop { $0 == " " }
        guard trimmed.first == "<" else {
            return nil
        }
        var afterBracket = trimmed.dropFirst()
        if afterBracket.first == "/" {
            afterBracket.removeFirst()
        }
        let tagName = String(afterBracket.prefix { $0.isLetter || $0.isNumber }).lowercased()
        guard !tagName.isEmpty, Self.htmlBlockTagNames.contains(tagName) || trimmed.hasPrefix("<!--") else {
            return nil
        }

        var rawLines: [Substring] = []
        var index = start
        while index < lines.endIndex, !isBlankLine(lines[index]) {
            rawLines.append(lines[index])
            index += 1
        }
        return HTMLBlockResult(rawHTML: rawLines.map(String.init).joined(separator: "\n"), nextIndex: index)
    }

    // MARK: - Lists

    struct ListMarker {
        let kind: MarkdownListKind
        let contentStart: Int // column offset (in the original line) where item content begins
        let checked: Bool?
        let contentAfterMarker: Substring
    }

    func parseListMarker(_ line: Substring) -> ListMarker? {
        guard leadingSpaceCount(line) < 4 else {
            return nil
        }
        var chars = line.drop { $0 == " " }
        let leadingSpaces = leadingSpaceCount(line)
        let kind: MarkdownListKind
        var consumed = 0

        if let first = chars.first, "-*+".contains(first) {
            let next = chars.dropFirst().first
            guard chars.dropFirst().isEmpty || next == " " || next == "\t" else {
                return nil
            }
            kind = .unordered(marker: first)
            consumed = 1
            chars.removeFirst()
        } else {
            var digits = ""
            var scan = chars
            while let first = scan.first, first.isNumber, digits.count < 9 {
                digits.append(first)
                scan.removeFirst()
            }
            guard !digits.isEmpty, let delimiter = scan.first, delimiter == "." || delimiter == ")" else {
                return nil
            }
            let afterDelimiter = scan.dropFirst().first
            guard scan.dropFirst().isEmpty || afterDelimiter == " " || afterDelimiter == "\t" else {
                return nil
            }
            kind = .ordered(start: Int(digits) ?? 1, delimiter: delimiter)
            consumed = digits.count + 1
            chars.removeFirst(consumed)
        }

        var spacesAfterMarker = 0
        while chars.first == " " || chars.first == "\t" {
            spacesAfterMarker += (chars.first == "\t") ? 4 : 1
            chars.removeFirst()
        }
        if spacesAfterMarker == 0, !chars.isEmpty {
            return nil // marker must be followed by whitespace (or be the whole line)
        }
        let contentStart = leadingSpaces + consumed + max(spacesAfterMarker, chars.isEmpty ? 1 : spacesAfterMarker)

        var checked: Bool?
        if chars.first == "[", chars.count >= 3 {
            let markerChar = chars[chars.index(chars.startIndex, offsetBy: 1)]
            let closeChar = chars[chars.index(chars.startIndex, offsetBy: 2)]
            if closeChar == "]", (markerChar == " " || markerChar == "x" || markerChar == "X") {
                checked = markerChar != " "
                chars.removeFirst(3)
                if chars.first == " " {
                    chars.removeFirst()
                }
            }
        }

        return ListMarker(kind: kind, contentStart: contentStart, checked: checked, contentAfterMarker: chars)
    }

    struct ListResult {
        let block: MarkdownBlock
        let nextIndex: Int
    }

    mutating func tryList(_ lines: ArraySlice<Substring>, from start: Int, depth: Int) -> ListResult? {
        guard let firstMarker = parseListMarker(lines[start]) else {
            return nil
        }
        var items: [MarkdownListItem] = []
        var index = start
        var isTight = true
        var sawBlankBetweenItems = false
        let sameKind: (MarkdownListKind, MarkdownListKind) -> Bool = { a, b in
            switch (a, b) {
            case (.unordered(let m1), .unordered(let m2)): return m1 == m2
            case (.ordered(_, let d1), .ordered(_, let d2)): return d1 == d2
            default: return false
            }
        }

        while index < lines.endIndex {
            guard let marker = parseListMarker(lines[index]), sameKind(marker.kind, firstMarker.kind) else {
                break
            }
            var itemLines: [Substring] = [marker.contentAfterMarker]
            index += 1
            var trailingBlankCount = 0
            while index < lines.endIndex {
                let line = lines[index]
                if isBlankLine(line) {
                    trailingBlankCount += 1
                    itemLines.append("")
                    index += 1
                    continue
                }
                if parseListMarker(line) != nil, leadingSpaceCount(line) < marker.contentStart + 4 {
                    break
                }
                if leadingSpaceCount(line) >= marker.contentStart {
                    itemLines.append(Substring(stripIndent(line, count: marker.contentStart)))
                    index += 1
                    trailingBlankCount = 0
                    continue
                }
                break
            }
            while itemLines.last == "" {
                itemLines.removeLast()
            }
            if trailingBlankCount > 0, index < lines.endIndex {
                sawBlankBetweenItems = true
            }
            let innerBlocks = parseBlocks(itemLines[...], depth: depth + 1)
            items.append(MarkdownListItem(checked: marker.checked, blocks: innerBlocks))
        }

        if sawBlankBetweenItems {
            isTight = false
        }
        return ListResult(block: .list(kind: firstMarker.kind, isTight: isTight, items: items), nextIndex: index)
    }

    // MARK: - Tables (GFM)

    struct TableResult {
        let block: MarkdownBlock
        let nextIndex: Int
    }

    mutating func tryTable(_ lines: ArraySlice<Substring>, from start: Int) -> TableResult? {
        guard start + 1 < lines.endIndex else {
            return nil
        }
        let headerLine = lines[start]
        let delimiterLine = lines[start + 1]
        guard headerLine.contains("|"), let alignments = parseTableDelimiterRow(delimiterLine) else {
            return nil
        }
        let headerCells = splitTableRow(headerLine)
        guard headerCells.count == alignments.count else {
            return nil
        }

        var rows: [MarkdownTableRow] = []
        var index = start + 2
        while index < lines.endIndex, !isBlankLine(lines[index]), lines[index].contains("|") {
            let cells = splitTableRow(lines[index])
            let padded = (0..<alignments.count).map { columnIndex -> [MarkdownInline] in
                columnIndex < cells.count ? parseInline(cells[columnIndex], depth: 0) : []
            }
            rows.append(MarkdownTableRow(cells: padded))
            index += 1
        }

        let header = MarkdownTableRow(cells: headerCells.map { parseInline($0, depth: 0) })
        return TableResult(
            block: .table(alignments: alignments, header: header, rows: rows),
            nextIndex: index
        )
    }

    func parseTableDelimiterRow(_ line: Substring) -> [MarkdownTableAlignment]? {
        let cells = splitTableRow(line)
        guard !cells.isEmpty, cells.count <= limits.maximumTableColumns else {
            return nil
        }
        var alignments: [MarkdownTableAlignment] = []
        for cell in cells {
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                return nil
            }
            let hasLeftColon = trimmed.first == ":"
            let hasRightColon = trimmed.last == ":"
            let dashes = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else {
                return nil
            }
            switch (hasLeftColon, hasRightColon) {
            case (true, true): alignments.append(.center)
            case (true, false): alignments.append(.left)
            case (false, true): alignments.append(.right)
            case (false, false): alignments.append(.none)
            }
        }
        return alignments
    }

    func splitTableRow(_ line: Substring) -> [Substring] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)[...]
        if trimmed.first == "|" {
            trimmed.removeFirst()
        }
        if trimmed.last == "|" {
            trimmed.removeLast()
        }
        var cells: [Substring] = []
        var current = ""
        var escaped = false
        for character in trimmed {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                current.append(character)
                escaped = true
                continue
            }
            if character == "|" {
                cells.append(Substring(current.trimmingCharacters(in: .whitespaces)))
                current = ""
                continue
            }
            current.append(character)
        }
        cells.append(Substring(current.trimmingCharacters(in: .whitespaces)))
        return cells
    }

    // MARK: - Paragraphs (with setext heading lookahead)

    struct ParagraphResult {
        let text: Substring
        let setextLevel: Int?
        let nextIndex: Int
    }

    /// A trailing hard line break (SPEC: two-or-more trailing spaces, or a
    /// trailing backslash) must be detected against the *raw* line before
    /// it is trimmed for display, so this sentinel — never legitimately
    /// produced by ordinary Markdown text — records that fact across the
    /// trim. `MarkdownInlineParser` turns it back into `.hardBreak`.
    static let hardBreakSentinel = "\u{2028}"

    func rawLineHasHardBreak(_ line: Substring) -> Bool {
        if line.hasSuffix("\\") {
            return true
        }
        var trailingSpaces = 0
        for character in line.reversed() {
            if character == " " {
                trailingSpaces += 1
            } else {
                break
            }
        }
        return trailingSpaces >= 2
    }

    func consumeParagraph(_ lines: ArraySlice<Substring>, from start: Int) -> ParagraphResult {
        var rawLines: [Substring] = [lines[start]]
        var index = start + 1
        while index < lines.endIndex {
            let line = lines[index]
            if isBlankLine(line) { break }
            if rawLines.count == 1, setextLevel(line) != nil { break }
            if tryThematicBreak(line) != nil { break }
            if tryATXHeading(line) != nil { break }
            if isBlockquoteStart(line) { break }
            if parseListMarker(line) != nil { break }
            if tryFencedCodeBlock(lines, from: index) != nil { break }
            rawLines.append(line)
            index += 1
        }

        if rawLines.count == 1, index < lines.endIndex, let level = setextLevel(lines[index]) {
            let trimmed = rawLines[0].trimmingCharacters(in: .whitespaces)
            return ParagraphResult(text: Substring(trimmed), setextLevel: level, nextIndex: index + 1)
        }

        var joined = ""
        for (position, rawLine) in rawLines.enumerated() {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)
            joined += trimmedLine
            if position < rawLines.count - 1 {
                joined += rawLineHasHardBreak(rawLine) ? Self.hardBreakSentinel : "\n"
            }
        }

        return ParagraphResult(text: Substring(joined), setextLevel: nil, nextIndex: index)
    }

    func setextLevel(_ line: Substring) -> Int? {
        guard leadingSpaceCount(line) < 4 else {
            return nil
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return nil
        }
        if trimmed.allSatisfy({ $0 == "=" }) {
            return 1
        }
        if trimmed.allSatisfy({ $0 == "-" }) {
            return 2
        }
        return nil
    }

    // MARK: - Inline parsing

    mutating func parseInline(_ text: Substring, depth: Int) -> [MarkdownInline] {
        let (inlines, diagnostics) = MarkdownInlineParser.parse(text, depth: depth, limits: limits)
        sanitizerDiagnostics.append(contentsOf: diagnostics)
        return inlines
    }
}
