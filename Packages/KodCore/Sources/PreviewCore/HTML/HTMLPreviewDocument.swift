import Foundation

/// Prepares an HTML source document for Kod's static WebKit preview.
/// JavaScript is separately disabled in `HTMLPreviewViewController`; this
/// policy also prevents remote/local filesystem access, frames, plug-ins,
/// forms, and network-capable CSS from becoming alternate escape paths.
public enum HTMLPreviewDocument {
    public static let resourceScheme = "kod-preview-resource"

    public static let contentSecurityPolicy = [
        "default-src 'none'",
        "img-src \(resourceScheme): data:",
        "media-src \(resourceScheme): data:",
        "font-src \(resourceScheme): data:",
        "style-src 'unsafe-inline' \(resourceScheme):",
        "script-src 'none'",
        "connect-src 'none'",
        "frame-src 'none'",
        "object-src 'none'",
        "base-uri 'none'",
        "form-action 'none'"
    ].joined(separator: "; ")

    public static func looksLikeHTML(_ data: Data) -> Bool {
        var source = String(decoding: data, as: UTF8.self)
        source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.hasPrefix("\u{feff}") {
            source.removeFirst()
            source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        while source.hasPrefix("<!--"),
              let end = source.range(of: "-->") {
            source.removeSubrange(source.startIndex..<end.upperBound)
            source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let prefix = source.prefix(512).lowercased()
        return prefix.hasPrefix("<!doctype html")
            || prefix.hasPrefix("<html")
            || prefix.hasPrefix("<head")
            || prefix.hasPrefix("<body")
    }

    public static func securedHTML(from data: Data) -> String? {
        guard let source = String(data: data, encoding: .utf8) else {
            return nil
        }
        let policy = contentSecurityPolicy
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let meta = """
        <meta http-equiv="Content-Security-Policy" content="\(policy)">
        """
        let fallbackInsertion = source.first == "\u{feff}"
            ? source.index(after: source.startIndex)
            : source.startIndex
        let insertion = insertionIndexAfterLeadingDoctype(in: source)
            ?? fallbackInsertion
        var secured = source
        secured.insert(contentsOf: "\n\(meta)\n", at: insertion)
        return secured
    }

    private static func insertionIndexAfterLeadingDoctype(
        in source: String
    ) -> String.Index? {
        var cursor = source.startIndex
        if cursor < source.endIndex, source[cursor] == "\u{feff}" {
            cursor = source.index(after: cursor)
        }

        while cursor < source.endIndex {
            while cursor < source.endIndex, source[cursor].isWhitespace {
                cursor = source.index(after: cursor)
            }
            guard source[cursor...].hasPrefix("<!--"),
                  let end = source.range(
                    of: "-->",
                    range: cursor..<source.endIndex
                  ) else {
                break
            }
            cursor = end.upperBound
        }

        guard let doctype = source.range(
            of: "<!doctype",
            options: [.caseInsensitive, .anchored],
            range: cursor..<source.endIndex
        ) else {
            return nil
        }
        let boundary = doctype.upperBound
        guard boundary == source.endIndex
                || source[boundary] == ">"
                || source[boundary].isWhitespace,
              let end = source[boundary...].firstIndex(of: ">") else {
            return nil
        }
        return source.index(after: end)
    }
}
