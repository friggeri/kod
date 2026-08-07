import Foundation

/// Removes the *entire* content of dangerous HTML/SVG elements — start
/// tag, body, and end tag — via a direct, case-insensitive substring scan,
/// before any tokenizer sees the markup at all.
///
/// This exists as a defense-in-depth layer ahead of
/// `LenientXMLTokenizer`/the allow-list sanitizers: a token-based
/// skip-until-matching-end-tag approach can be tricked by malformed nested
/// markup *inside* a `<script>` body (script/CSS content is not itself
/// well-formed XML, so it can contain `<`/`>` sequences that desynchronize
/// naive tag-depth counting and let part of the payload leak back out as
/// "text"). Finding the element by its literal, case-insensitive name and
/// deleting everything up to its closing tag (or to the end of the
/// document, if unterminated) has no such desynchronization failure mode.
enum DangerousElementStripper {
    struct Result {
        let text: String
        let removedConstructs: [String]
    }

    static func strip(_ text: String, elementNames: [String]) -> Result {
        var working = text
        var removed: [String] = []

        for name in elementNames {
            var searchStart = working.startIndex
            while let openRange = firstTagOpen(name, in: working, from: searchStart) {
                // Find the end of the opening tag itself (`>`), then the
                // matching close tag, case-insensitively.
                guard let tagCloseIndex = working[openRange.lowerBound...].firstIndex(of: ">") else {
                    // Unterminated opening tag: drop everything from here
                    // to the end of the document rather than leave a
                    // dangling, ambiguous fragment.
                    removed.append("removed unterminated <\(name)> element and trailing content")
                    working.removeSubrange(openRange.lowerBound..<working.endIndex)
                    break
                }
                let closeTagPattern = "</\(name)"
                if let endOpenRange = working.range(
                    of: closeTagPattern,
                    options: [.caseInsensitive],
                    range: working.index(after: tagCloseIndex)..<working.endIndex
                ) {
                    let endTagCloseIndex = working[endOpenRange.lowerBound...].firstIndex(of: ">") ?? working.endIndex
                    let removalEnd = endTagCloseIndex == working.endIndex ? working.endIndex : working.index(after: endTagCloseIndex)
                    working.removeSubrange(openRange.lowerBound..<removalEnd)
                    removed.append("removed <\(name)> element")
                } else {
                    removed.append("removed unterminated <\(name)> element and trailing content")
                    working.removeSubrange(openRange.lowerBound..<working.endIndex)
                    break
                }
                searchStart = working.startIndex
            }
        }

        return Result(text: working, removedConstructs: removed)
    }

    private static func firstTagOpen(_ name: String, in text: String, from start: String.Index) -> Range<String.Index>? {
        guard let range = text.range(of: "<\(name)", options: [.caseInsensitive], range: start..<text.endIndex) else {
            return nil
        }
        // Require the match to be followed by whitespace, `>`, or `/` so
        // `<scriptx>` does not falsely match a strip for `<script>`.
        let afterIndex = range.upperBound
        if afterIndex < text.endIndex {
            let next = text[afterIndex]
            guard next.isWhitespace || next == ">" || next == "/" else {
                return firstTagOpen(name, in: text, from: range.upperBound)
            }
        }
        return range
    }
}
