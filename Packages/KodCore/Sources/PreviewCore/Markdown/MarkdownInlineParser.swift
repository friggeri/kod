import Foundation

/// Parses one block's worth of inline Markdown text into `[MarkdownInline]`.
///
/// This uses a straightforward recursive-descent scan rather than
/// CommonMark's reference delimiter-stack algorithm, so some rarely-used
/// emphasis edge cases (mismatched flanking runs like `a**b*c**d*`) may
/// resolve differently than a spec-perfect implementation. Every
/// security-relevant behavior is still exact: raw inline HTML is always
/// routed through the supplied `sanitize` closure before becoming
/// `.sanitizedHTML`, and every link/image destination is classified
/// through `MarkdownDestination`.
enum MarkdownInlineParser {
    static func parse(
        _ text: Substring,
        depth: Int,
        limits: MarkdownLimits
    ) -> (inlines: [MarkdownInline], sanitizerDiagnostics: [String]) {
        guard depth <= limits.maximumInlineDepth else {
            return ([.text(String(text))], [])
        }
        var scanner = Scanner(characters: Array(text), limits: limits)
        let inlines = scanner.parseInlines(depth: depth, stopCharacters: [])
        return (inlines, scanner.diagnostics)
    }

    private struct Scanner {
        let characters: [Character]
        let limits: MarkdownLimits
        var index = 0
        var diagnostics: [String] = []

        init(characters: [Character], limits: MarkdownLimits) {
            self.characters = characters
            self.limits = limits
        }

        var isAtEnd: Bool { index >= characters.count }

        mutating func parseInlines(depth: Int, stopCharacters: Set<Character>) -> [MarkdownInline] {
            var result: [MarkdownInline] = []
            var textBuffer = ""

            func flushText() {
                if !textBuffer.isEmpty {
                    result.append(.text(textBuffer))
                    textBuffer = ""
                }
            }

            while !isAtEnd {
                let character = characters[index]
                if stopCharacters.contains(character) {
                    break
                }

                switch character {
                case "\u{2028}":
                    flushText()
                    result.append(.hardBreak)
                    index += 1

                case "\n":
                    flushText()
                    result.append(.softBreak)
                    index += 1

                case "\\":
                    if index + 1 < characters.count, Self.escapableCharacters.contains(characters[index + 1]) {
                        textBuffer.append(characters[index + 1])
                        index += 2
                    } else {
                        textBuffer.append(character)
                        index += 1
                    }

                case "`":
                    if let (code, newIndex) = parseCodeSpan(from: index) {
                        flushText()
                        result.append(.code(code))
                        index = newIndex
                    } else {
                        textBuffer.append(character)
                        index += 1
                    }

                case "<":
                    if let (html, newIndex) = parseAutolinkOrHTML(from: index) {
                        flushText()
                        switch html {
                        case .autolink(let destination):
                            result.append(.link(destination: destination, title: nil, children: [.text(destination.rawValue)]))
                        case .rawHTML(let raw):
                            let sanitized = MarkdownHTMLSanitizer.sanitize(raw)
                            diagnostics.append(contentsOf: sanitized.removedConstructs)
                            result.append(.sanitizedHTML(sanitized.sanitizedText))
                        }
                        index = newIndex
                    } else {
                        textBuffer.append(character)
                        index += 1
                    }

                case "!":
                    if index + 1 < characters.count, characters[index + 1] == "[",
                       let image = parseImage(from: index, depth: depth) {
                        flushText()
                        result.append(image.node)
                        index = image.nextIndex
                    } else {
                        textBuffer.append(character)
                        index += 1
                    }

                case "[":
                    if let link = parseLink(from: index, depth: depth) {
                        flushText()
                        result.append(link.node)
                        index = link.nextIndex
                    } else {
                        textBuffer.append(character)
                        index += 1
                    }

                case "*", "_", "~":
                    if let (node, newIndex) = parseEmphasisRun(from: index, depth: depth) {
                        flushText()
                        result.append(node)
                        index = newIndex
                    } else {
                        // Not a matched emphasis run: consume the *entire*
                        // consecutive run of this marker character as
                        // literal text in one step. Advancing only one
                        // character here would make the caller retry
                        // `parseEmphasisRun` (which itself rescans the
                        // whole remaining run to measure its length) once
                        // per leftover character, turning a long
                        // pathological run of `*`/`_`/`~` into O(n²) work
                        // — exactly the kind of unbounded-latency
                        // hostile-input case SPEC 11.6 rules out.
                        var runEnd = index
                        while runEnd < characters.count, characters[runEnd] == character {
                            runEnd += 1
                        }
                        textBuffer.append(contentsOf: characters[index..<runEnd])
                        index = runEnd
                    }

                case "&":
                    if let (decoded, newIndex) = parseEntity(from: index) {
                        textBuffer.append(decoded)
                        index = newIndex
                    } else {
                        textBuffer.append(character)
                        index += 1
                    }

                default:
                    textBuffer.append(character)
                    index += 1
                }
            }

            flushText()
            return result
        }

        private static let escapableCharacters = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

        // MARK: - Code spans

        mutating func parseCodeSpan(from start: Int) -> (String, Int)? {
            var backtickCount = 0
            var i = start
            while i < characters.count, characters[i] == "`" {
                backtickCount += 1
                i += 1
            }
            let contentStart = i
            while i < characters.count {
                if characters[i] == "`" {
                    var closingCount = 0
                    var j = i
                    while j < characters.count, characters[j] == "`" {
                        closingCount += 1
                        j += 1
                    }
                    if closingCount == backtickCount {
                        var content = String(characters[contentStart..<i])
                        if content.hasPrefix(" "), content.hasSuffix(" "), content.trimmingCharacters(in: .whitespaces).isEmpty == false {
                            content = String(content.dropFirst().dropLast())
                        }
                        return (content.replacingOccurrences(of: "\n", with: " "), j)
                    }
                    i = j
                } else {
                    i += 1
                }
            }
            return nil
        }

        // MARK: - Autolinks / raw inline HTML

        enum AngleResult {
            case autolink(MarkdownDestination)
            case rawHTML(String)
        }

        func parseAutolinkOrHTML(from start: Int) -> (AngleResult, Int)? {
            guard let closeIndex = characters[start...].firstIndex(of: ">") else {
                return nil
            }
            let inner = String(characters[(start + 1)..<closeIndex])
            guard !inner.isEmpty, !inner.contains("\n") else {
                return nil
            }

            // Tag-shaped (`</name>`, `<!--...`, `<?...`) is checked first
            // and unconditionally, regardless of whether `inner` contains
            // whitespace (a tag with attributes, e.g.
            // `<img src="x" onerror="y">`, always will) — this must not
            // fall through to the autolink checks below, which only make
            // sense for a bare `scheme:...`/`user@host` payload.
            if inner.first == "/" || inner.first == "!" || inner.first == "?" {
                return (.rawHTML(String(characters[start...closeIndex])), closeIndex + 1)
            }
            guard let first = inner.first, first.isLetter else {
                return nil
            }
            if !inner.contains(" "), inner.contains("@"), !inner.contains("://") {
                return (.autolink(MarkdownDestination(rawValue: "mailto:\(inner)")), closeIndex + 1)
            }
            if !inner.contains(" "),
               let colonIndex = inner.firstIndex(of: ":"),
               inner[inner.startIndex..<colonIndex].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) {
                return (.autolink(MarkdownDestination(rawValue: inner)), closeIndex + 1)
            }
            // A plain tag name (with or without attributes/self-closing
            // slash) that is neither a mailto nor a scheme autolink —
            // e.g. `<b>`, `<div class="x">`, `<br/>`.
            return (.rawHTML(String(characters[start...closeIndex])), closeIndex + 1)
        }

        // MARK: - Entities

        private static let namedEntities: [String: Character] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
            "nbsp": "\u{00A0}", "copy": "\u{00A9}", "reg": "\u{00AE}",
            "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "\u{2026}"
        ]

        func parseEntity(from start: Int) -> (Character, Int)? {
            guard start + 1 < characters.count else {
                return nil
            }
            var i = start + 1
            if characters[i] == "#" {
                i += 1
                var isHex = false
                if i < characters.count, characters[i] == "x" || characters[i] == "X" {
                    isHex = true
                    i += 1
                }
                let digitsStart = i
                while i < characters.count, characters[i] != ";", i - digitsStart < 8 {
                    i += 1
                }
                guard i < characters.count, characters[i] == ";", i > digitsStart else {
                    return nil
                }
                let digits = String(characters[digitsStart..<i])
                guard let value = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(value) else {
                    return nil
                }
                return (Character(scalar), i + 1)
            }
            let nameStart = i
            while i < characters.count, characters[i] != ";", i - nameStart < 32 {
                i += 1
            }
            guard i < characters.count, characters[i] == ";" else {
                return nil
            }
            let name = String(characters[nameStart..<i])
            guard let resolved = Self.namedEntities[name] else {
                return nil
            }
            return (resolved, i + 1)
        }

        // MARK: - Links / images

        struct LinkParseResult {
            let node: MarkdownInline
            let nextIndex: Int
        }

        mutating func parseLink(from start: Int, depth: Int) -> LinkParseResult? {
            guard let labelEnd = findMatchingBracket(from: start) else {
                return nil
            }
            let labelText = String(characters[(start + 1)..<labelEnd])
            guard let (destination, title, afterIndex) = parseInlineDestination(from: labelEnd + 1) else {
                return nil
            }
            var subScanner = Scanner(characters: Array(labelText), limits: limits)
            let children = subScanner.parseInlines(depth: depth + 1, stopCharacters: [])
            diagnostics.append(contentsOf: subScanner.diagnostics)
            return LinkParseResult(
                node: .link(destination: destination, title: title, children: children),
                nextIndex: afterIndex
            )
        }

        mutating func parseImage(from start: Int, depth: Int) -> LinkParseResult? {
            guard let labelEnd = findMatchingBracket(from: start + 1) else {
                return nil
            }
            let altText = String(characters[(start + 2)..<labelEnd])
            guard let (destination, title, afterIndex) = parseInlineDestination(from: labelEnd + 1) else {
                return nil
            }
            return LinkParseResult(
                node: .image(destination: destination, title: title, altText: altText),
                nextIndex: afterIndex
            )
        }

        /// Finds the `]` matching the `[` at `start`, respecting nested
        /// brackets (for link text containing an image, etc.) up to a
        /// bounded nesting depth.
        func findMatchingBracket(from start: Int) -> Int? {
            guard start < characters.count, characters[start] == "[" else {
                return nil
            }
            var depth = 0
            var i = start
            while i < characters.count {
                if characters[i] == "\\" {
                    i += 2
                    continue
                }
                if characters[i] == "[" {
                    depth += 1
                } else if characters[i] == "]" {
                    depth -= 1
                    if depth == 0 {
                        return i
                    }
                }
                i += 1
            }
            return nil
        }

        /// Parses `(destination "title")` immediately following a link or
        /// image label's closing `]`. Returns `nil` (not a link) if the
        /// next non-whitespace character is not `(`.
        func parseInlineDestination(from start: Int) -> (MarkdownDestination, String?, Int)? {
            guard start < characters.count, characters[start] == "(" else {
                return nil
            }
            var i = start + 1
            while i < characters.count, characters[i] == " " || characters[i] == "\n" {
                i += 1
            }
            var destination = ""
            if i < characters.count, characters[i] == "<" {
                i += 1
                while i < characters.count, characters[i] != ">" {
                    destination.append(characters[i])
                    i += 1
                }
                guard i < characters.count else {
                    return nil
                }
                i += 1
            } else {
                var parenDepth = 0
                while i < characters.count {
                    let c = characters[i]
                    if c == "\\", i + 1 < characters.count {
                        destination.append(characters[i + 1])
                        i += 2
                        continue
                    }
                    if c == "(" {
                        parenDepth += 1
                    } else if c == ")" {
                        if parenDepth == 0 { break }
                        parenDepth -= 1
                    } else if c == " " || c == "\n" {
                        break
                    }
                    destination.append(c)
                    i += 1
                }
            }

            while i < characters.count, characters[i] == " " || characters[i] == "\n" {
                i += 1
            }

            var title: String?
            if i < characters.count, characters[i] == "\"" || characters[i] == "'" {
                let quote = characters[i]
                i += 1
                var titleText = ""
                while i < characters.count, characters[i] != quote {
                    titleText.append(characters[i])
                    i += 1
                }
                guard i < characters.count else {
                    return nil
                }
                i += 1
                title = titleText
                while i < characters.count, characters[i] == " " || characters[i] == "\n" {
                    i += 1
                }
            }

            guard i < characters.count, characters[i] == ")" else {
                return nil
            }
            return (MarkdownDestination(rawValue: destination), title, i + 1)
        }

        // MARK: - Emphasis / strong / strikethrough

        mutating func parseEmphasisRun(from start: Int, depth: Int) -> (MarkdownInline, Int)? {
            guard depth <= limits.maximumInlineDepth else {
                return nil
            }
            let marker = characters[start]
            var runLength = 0
            var i = start
            while i < characters.count, characters[i] == marker {
                runLength += 1
                i += 1
            }
            guard marker != "~" || runLength >= 2 else {
                return nil
            }
            // `***word***` (a 3-run) is strong+emphasis combined; cap at
            // 3 delimiter characters so the search below always starts
            // immediately after however many delimiters actually open
            // this run (never skipping past unconsumed marker
            // characters into the content, which previously produced a
            // stray leading `*` inside `***word***`).
            let openLength = marker == "~" ? 2 : min(runLength, 3)
            let searchStart = start + openLength
            guard let closeIndex = findClosingRun(marker: marker, length: openLength, from: searchStart) else {
                return nil
            }

            let innerText = String(characters[searchStart..<closeIndex])
            guard !innerText.isEmpty else {
                return nil
            }
            var subScanner = Scanner(characters: Array(innerText), limits: limits)
            let children = subScanner.parseInlines(depth: depth + 1, stopCharacters: [])
            diagnostics.append(contentsOf: subScanner.diagnostics)
            let nextIndex = closeIndex + openLength

            if marker == "~" {
                return (.strikethrough(children), nextIndex)
            }
            switch openLength {
            case 3:
                return (.strong([.emphasis(children)]), nextIndex)
            case 2:
                return (.strong(children), nextIndex)
            default:
                return (.emphasis(children), nextIndex)
            }
        }

        func findClosingRun(marker: Character, length: Int, from start: Int) -> Int? {
            var i = start
            while i < characters.count {
                if characters[i] == marker {
                    var runLength = 0
                    var j = i
                    while j < characters.count, characters[j] == marker {
                        runLength += 1
                        j += 1
                    }
                    if runLength >= length {
                        return i
                    }
                    i = j
                } else if characters[i] == "\n" && (i == start || characters[i - 1] == "\n") {
                    // A blank line ends the search: emphasis never spans
                    // a paragraph break.
                    return nil
                } else {
                    i += 1
                }
            }
            return nil
        }
    }
}
