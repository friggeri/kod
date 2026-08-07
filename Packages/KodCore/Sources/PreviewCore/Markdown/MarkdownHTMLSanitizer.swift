import Foundation

/// Sanitizes raw HTML embedded in a Markdown document (SPEC 10.1: "Raw
/// HTML is sanitized; scripts never run").
///
/// The output is plain text meant for literal, monospace-ish display
/// inside `MarkdownBlock.sanitizedHTMLBlock`/`MarkdownInline.sanitizedHTML`
/// — Kod's Markdown renderer is a native attributed-run model, not an HTML
/// engine, so sanitized raw HTML is shown as readable tag text rather than
/// being re-interpreted as live markup. This still matters: without
/// sanitization, a raw `<script>` block or an `onerror=` handler would sit
/// in the document's stored text verbatim, one future rendering-path
/// change away from executing. Sanitizing at parse time, once, removes
/// that entire risk class regardless of how the sanitized text is later
/// displayed.
public enum MarkdownHTMLSanitizer {
    public struct Result: Equatable, Sendable {
        public let sanitizedText: String
        public let removedConstructs: [String]
    }

    private static let textuallyStrippedElements = [
        "script", "style", "iframe", "object", "embed", "template", "noscript", "form"
    ]

    private static let deniedElements: Set<String> = [
        "script", "style", "iframe", "object", "embed", "template", "noscript", "form",
        "meta", "link", "base", "svg", "math", "video", "audio", "source"
    ]

    /// Formatting elements kept (with attributes filtered) — a
    /// deliberately small allow-list of tags with no scripting surface.
    private static let allowedElements: Set<String> = [
        "b", "i", "em", "strong", "code", "pre", "br", "hr", "p", "div", "span",
        "sub", "sup", "kbd", "del", "ins", "mark", "small", "blockquote",
        "ul", "ol", "li", "table", "thead", "tbody", "tr", "td", "th",
        "h1", "h2", "h3", "h4", "h5", "h6", "a", "img", "details", "summary"
    ]

    private static let alwaysAllowedAttributes: Set<String> = [
        "id", "class", "align", "colspan", "rowspan", "start", "type"
    ]

    public static func sanitize(_ html: String) -> Result {
        let prepass = DangerousElementStripper.strip(html, elementNames: textuallyStrippedElements)
        var removed = prepass.removedConstructs
        let tokens = LenientXMLTokenizer.tokenize(prepass.text)
        var output = ""
        var skipDepth = 0

        for token in tokens {
            switch token {
            case .text(let text):
                if skipDepth == 0 {
                    output += text
                }
            case .comment:
                removed.append("removed HTML comment")
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
                let (filtered, removedHere) = filterAttributes(attributes, elementName: name)
                removed.append(contentsOf: removedHere)
                output += "<\(name)\(renderAttributes(filtered))\(isSelfClosing ? "/" : "")>"
            case .endElement(let name):
                if skipDepth > 0 {
                    skipDepth -= 1
                    continue
                }
                // Markdown's inline-HTML model hands each `<tag>` to the
                // sanitizer as its own independent fragment (CommonMark
                // treats a start tag, the ordinary text after it, and its
                // end tag as three separate constructs), so there is no
                // reliable open/close *pairing* to check here. What is
                // reliable, and sufficient: an end tag is only ever
                // re-emitted for a name on the same fixed allow-list a
                // start tag would need — never for a denied or
                // unrecognized name — so a lone `</script>` or
                // `</marquee>` can never survive just because its
                // matching start tag happened to arrive in a different
                // sanitize call.
                guard allowedElements.contains(name.lowercased()) else {
                    removed.append("removed unrecognized or unsafe closing tag </\(name)>")
                    continue
                }
                output += "</\(name)>"
            case .processingInstruction:
                removed.append("removed processing instruction")
            }
        }

        return Result(sanitizedText: output, removedConstructs: removed)
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
            if lowerName == "href" {
                let destination = MarkdownDestination(rawValue: value)
                if case .unsafeOrUnrecognized = destination.scheme {
                    removed.append("removed unsafe href=\"\(value)\" on <\(elementName)>")
                    continue
                }
                kept.append((name, value))
                continue
            }
            if lowerName == "src" {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if trimmed.hasPrefix("data:image/") || !trimmed.contains(":") {
                    kept.append((name, value))
                } else {
                    removed.append("removed unsafe src=\"\(value)\" on <\(elementName)>")
                }
                continue
            }
            if lowerName == "style" {
                removed.append("removed style attribute on <\(elementName)>")
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
