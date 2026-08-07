import Foundation

/// Sanitizes untrusted SVG source text so it can be rasterized (by the App
/// layer, via a script-free system renderer) without ever executing script
/// or fetching a remote resource (SPEC 10.2: "SVG rendered without scripts
/// or external resources").
///
/// This is a real allow-list sanitizer, not a denylist: only elements and
/// attributes known to be pure vector-drawing markup pass through.
/// Everything else — `<script>`, `<foreignObject>`, `<style>` (CSS can
/// itself load external resources via `url(...)` and `@import`), event
/// handler attributes (`on*`), and any URL-valued attribute
/// (`href`/`xlink:href`/`src`) that is not a same-document `#fragment` or
/// an inline `data:image/...` URI — is dropped entirely. Sanitization
/// failure is never silent: `sanitize` reports exactly what it removed so
/// callers (and hostile-input tests) can see the mitigation actually fired
/// rather than merely hoping it did.
public enum SVGSanitizer {
    public struct Result: Equatable, Sendable {
        public let sanitizedXML: String
        /// Human-readable descriptions of every element/attribute removed,
        /// e.g. `"removed <script> element"` or
        /// `"removed onload attribute on <svg>"`.
        public let removedConstructs: [String]

        public init(sanitizedXML: String, removedConstructs: [String]) {
            self.sanitizedXML = sanitizedXML
            self.removedConstructs = removedConstructs
        }
    }

    /// Element names that are pure vector-drawing/structure markup and are
    /// always kept (subject to their own attributes still being filtered).
    private static let allowedElements: Set<String> = [
        "svg", "g", "path", "rect", "circle", "ellipse", "line", "polyline",
        "polygon", "defs", "clippath", "mask", "lineargradient", "radialgradient",
        "stop", "symbol", "use", "title", "desc", "text", "tspan", "textpath",
        "marker", "pattern"
    ]

    /// Attribute names allowed on any kept element, beyond the per-element
    /// presentation attributes below. `id`/`class` are needed for
    /// `<use>`/gradient references and CSS-free styling; none of these can
    /// reach the network or execute code.
    private static let alwaysAllowedAttributes: Set<String> = [
        "id", "class", "viewbox", "width", "height", "x", "y", "x1", "y1", "x2", "y2",
        "cx", "cy", "r", "rx", "ry", "d", "points", "transform", "fill", "stroke",
        "stroke-width", "stroke-linecap", "stroke-linejoin", "stroke-dasharray",
        "opacity", "fill-opacity", "stroke-opacity", "fill-rule", "clip-rule",
        "offset", "stop-color", "stop-opacity", "gradientunits", "gradienttransform",
        "preserveaspectratio", "font-family", "font-size", "font-weight", "text-anchor",
        "xmlns", "version", "clip-path", "mask", "marker-start", "marker-mid", "marker-end"
    ]

    /// Elements dropped outright regardless of attributes — anything that
    /// can execute code, load remote CSS, or otherwise escape pure vector
    /// drawing.
    private static let deniedElements: Set<String> = [
        "script", "foreignobject", "style", "iframe", "object", "embed",
        "video", "audio", "animate", "animatetransform", "animatemotion",
        "set", "handler", "listener", "a"
    ]

    /// Element names whose entire content is stripped textually, ahead of
    /// tokenizing, per `DangerousElementStripper` — the defense-in-depth
    /// layer that cannot be desynchronized by malformed markup smuggled
    /// inside a script/style body.
    private static let textuallyStrippedElements = [
        "script", "style", "foreignObject", "iframe", "object", "embed", "template", "noscript"
    ]

    public static func sanitize(_ xml: String) -> Result {
        var removed: [String] = []
        let prepass = DangerousElementStripper.strip(xml, elementNames: textuallyStrippedElements)
        removed.append(contentsOf: prepass.removedConstructs)
        let document = LenientXMLTokenizer.tokenize(prepass.text)
        var output = ""
        var skipDepth = 0

        for token in document {
            switch token {
            case .text(let text):
                if skipDepth == 0 {
                    output += text
                }
            case .comment:
                // Comments never round-trip: an attacker-controlled
                // comment is a classic vector for smuggling
                // otherwise-filtered markup past a naive scan, and
                // dropping them costs nothing for a rendering pipeline.
                removed.append("removed XML comment")
            case .startElement(let name, let attributes, let isSelfClosing):
                let lowerName = name.lowercased()
                if skipDepth > 0 {
                    if !isSelfClosing {
                        skipDepth += 1
                    }
                    continue
                }
                if deniedElements.contains(lowerName) {
                    removed.append("removed <\(name)> element")
                    if !isSelfClosing {
                        skipDepth += 1
                    }
                    continue
                }
                guard allowedElements.contains(lowerName) else {
                    removed.append("removed unrecognized <\(name)> element")
                    if !isSelfClosing {
                        skipDepth += 1
                    }
                    continue
                }
                let (filteredAttributes, removedHere) = filterAttributes(attributes, elementName: name)
                removed.append(contentsOf: removedHere)
                output += "<\(name)\(renderAttributes(filteredAttributes))\(isSelfClosing ? "/" : "")>"
            case .endElement(let name):
                if skipDepth > 0 {
                    skipDepth -= 1
                    continue
                }
                // Same reasoning as `MarkdownHTMLSanitizer`: only ever
                // re-emit a closing tag whose name is itself on the fixed
                // allow-list, never based on tracking a pairing that a
                // hostile or malformed document could desynchronize.
                guard allowedElements.contains(name.lowercased()) else {
                    removed.append("removed unrecognized or unsafe closing tag </\(name)>")
                    continue
                }
                output += "</\(name)>"
            case .processingInstruction(let raw):
                if skipDepth == 0 {
                    output += raw
                }
            }
        }

        return Result(sanitizedXML: output, removedConstructs: removed)
    }

    private static func filterAttributes(
        _ attributes: [(name: String, value: String)],
        elementName: String
    ) -> (kept: [(name: String, value: String)], removed: [String]) {
        var kept: [(name: String, value: String)] = []
        var removed: [String] = []

        for (name, value) in attributes {
            let lowerName = name.lowercased()
            if lowerName.hasPrefix("on") {
                removed.append("removed \(name) event-handler attribute on <\(elementName)>")
                continue
            }
            if lowerName == "href" || lowerName == "xlink:href" {
                if isSafeReferenceURL(value) {
                    kept.append((name, value))
                } else {
                    removed.append("removed unsafe \(name)=\"\(value)\" on <\(elementName)>")
                }
                continue
            }
            if lowerName == "style" {
                // Inline CSS can itself carry `url(...)`/`@import` remote
                // references or `expression()`-style legacy script
                // hooks; dropping it entirely is simpler and safer than
                // trying to sub-parse CSS here.
                removed.append("removed style attribute on <\(elementName)>")
                continue
            }
            if lowerName == "xmlns:xlink" {
                kept.append((name, value))
                continue
            }
            guard alwaysAllowedAttributes.contains(lowerName) else {
                removed.append("removed unrecognized \(name) attribute on <\(elementName)>")
                continue
            }
            kept.append((name, value))
        }
        return (kept, removed)
    }

    /// A reference URL is safe only if it is a same-document fragment
    /// (`#gradientA`) or an inline `data:image/...` URI. Anything with a
    /// scheme reaching outside the document (`http(s):`, `file:`,
    /// `javascript:`, protocol-relative `//host/...`) is rejected — this
    /// is what actually enforces "no external resources" and "no scripts"
    /// for `<use>`/gradient/image references.
    private static func isSafeReferenceURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") {
            return true
        }
        if trimmed.lowercased().hasPrefix("data:image/") {
            return true
        }
        return false
    }

    private static func renderAttributes(_ attributes: [(name: String, value: String)]) -> String {
        guard !attributes.isEmpty else {
            return ""
        }
        return " " + attributes.map { name, value in
            let escaped = value
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return "\(name)=\"\(escaped)\""
        }.joined(separator: " ")
    }
}

/// A minimal, dependency-free XML tokenizer used only for SVG
/// sanitization. It is deliberately not a general-purpose XML parser: it
/// never resolves entities beyond the five predefined XML ones, never
/// fetches a DTD, and treats anything it cannot confidently tokenize as
/// plain text rather than guessing — the opposite failure mode of a lax
/// parser that might reinterpret malformed markup as valid elements.
enum LenientXMLTokenizer {
    enum Token {
        case text(String)
        case comment(String)
        case startElement(name: String, attributes: [(name: String, value: String)], isSelfClosing: Bool)
        case endElement(name: String)
        case processingInstruction(String)
    }

    /// Hard ceiling on emitted tokens, independent of input size, so a
    /// pathological input (e.g. millions of empty `<a/>` elements) cannot
    /// build an unbounded token array.
    private static let maximumTokens = 200_000

    static func tokenize(_ xml: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(xml)
        var index = 0

        func peekMatches(_ literal: String) -> Bool {
            let literalChars = Array(literal)
            guard index + literalChars.count <= chars.count else {
                return false
            }
            return Array(chars[index..<(index + literalChars.count)]) == literalChars
        }

        while index < chars.count, tokens.count < maximumTokens {
            if chars[index] == "<" {
                if peekMatches("<!--") {
                    guard let endRange = findClosing("-->", in: chars, from: index + 4) else {
                        tokens.append(.comment(String(chars[(index + 4)...])))
                        break
                    }
                    tokens.append(.comment(String(chars[(index + 4)..<endRange])))
                    index = endRange + 3
                    continue
                }
                if peekMatches("<![CDATA[") {
                    guard let endRange = findClosing("]]>", in: chars, from: index + 9) else {
                        tokens.append(.text(String(chars[(index + 9)...])))
                        break
                    }
                    tokens.append(.text(String(chars[(index + 9)..<endRange])))
                    index = endRange + 3
                    continue
                }
                if peekMatches("<!") {
                    // DOCTYPE or other markup declaration: never emitted,
                    // never followed for entity expansion.
                    guard let endIndex = chars[index...].firstIndex(of: ">") else {
                        break
                    }
                    index = endIndex + 1
                    continue
                }
                if peekMatches("<?") {
                    guard let endRange = findClosing("?>", in: chars, from: index + 2) else {
                        break
                    }
                    tokens.append(.processingInstruction(String(chars[index..<(endRange + 2)])))
                    index = endRange + 2
                    continue
                }
                if index + 1 < chars.count, chars[index + 1] == "/" {
                    guard let closeIndex = chars[index...].firstIndex(of: ">") else {
                        break
                    }
                    let name = String(chars[(index + 2)..<closeIndex]).trimmingCharacters(in: .whitespaces)
                    tokens.append(.endElement(name: name))
                    index = closeIndex + 1
                    continue
                }
                guard let closeIndex = chars[index...].firstIndex(of: ">") else {
                    break
                }
                var inner = chars[(index + 1)..<closeIndex]
                var isSelfClosing = false
                if inner.last == "/" {
                    isSelfClosing = true
                    inner = inner[inner.startIndex..<inner.index(before: inner.endIndex)]
                }
                let (name, attributes) = parseTag(String(inner))
                tokens.append(.startElement(name: name, attributes: attributes, isSelfClosing: isSelfClosing))
                index = closeIndex + 1
                continue
            }

            guard let nextTag = chars[index...].firstIndex(of: "<") else {
                tokens.append(.text(decodeEntities(String(chars[index...]))))
                break
            }
            tokens.append(.text(decodeEntities(String(chars[index..<nextTag]))))
            index = nextTag
        }

        return tokens
    }

    private static func findClosing(_ literal: String, in chars: [Character], from start: Int) -> Int? {
        let literalChars = Array(literal)
        guard start <= chars.count else {
            return nil
        }
        var index = start
        while index + literalChars.count <= chars.count {
            if Array(chars[index..<(index + literalChars.count)]) == literalChars {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func parseTag(_ raw: String) -> (name: String, attributes: [(name: String, value: String)]) {
        var characters = Substring(raw)
        characters = characters.drop { $0.isWhitespace }
        var name = ""
        while let first = characters.first, !first.isWhitespace {
            name.append(first)
            characters.removeFirst()
        }

        var attributes: [(String, String)] = []
        while true {
            characters = characters.drop { $0.isWhitespace }
            guard !characters.isEmpty else {
                break
            }
            var attributeName = ""
            while let first = characters.first, first != "=", !first.isWhitespace {
                attributeName.append(first)
                characters.removeFirst()
            }
            characters = characters.drop { $0.isWhitespace }
            guard characters.first == "=" else {
                // Boolean-style attribute with no value; safely ignored
                // since no allow-listed SVG attribute is boolean.
                if attributeName.isEmpty {
                    break
                }
                continue
            }
            characters.removeFirst() // consume '='
            characters = characters.drop { $0.isWhitespace }
            guard let quote = characters.first, quote == "\"" || quote == "'" else {
                break
            }
            characters.removeFirst()
            var value = ""
            while let next = characters.first, next != quote {
                value.append(next)
                characters.removeFirst()
            }
            if characters.first == quote {
                characters.removeFirst()
            }
            if !attributeName.isEmpty {
                attributes.append((attributeName, decodeEntities(value)))
            }
        }
        return (name, attributes)
    }

    private static func decodeEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
