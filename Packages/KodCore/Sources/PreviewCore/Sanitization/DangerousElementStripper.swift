import Foundation

/// Removes the *entire* content of dangerous HTML/SVG elements — start
/// tag, body, and end tag — via a direct, case-insensitive scan, before
/// any tokenizer sees the markup at all.
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
///
/// The invariant the layer exists to provide is that **no recognizable
/// opening tag for any listed element survives in the output**, and that
/// stripping is a fixed point (a second pass removes nothing more).
/// Deleting a region can splice two previously-separated fragments
/// together and so *create* a tag that was never present in the input
/// (`<scr` + `ipt>`, or `<scr` + `<style>…</style>` + `ipt>` across two
/// different element names), and truncating an unterminated element can
/// leave a `<script` that is now dangerous because nothing follows it.
///
/// Both are handled structurally rather than by rescanning: the scan
/// matches opening tags against the bytes **already written to the
/// output**, which by construction already reflect every earlier removal,
/// and it re-checks that output tail after each removal before consuming
/// any more input. Every element name is considered in the same single
/// pass, so removals never depend on the order names are listed in. Each
/// input byte is therefore appended at most once and each removal
/// advances the read cursor, keeping the total work linear in the input
/// length — the earlier implementation restarted the whole scan from the
/// start of the document after every removal, which was quadratic and
/// trivially weaponizable with a large input full of small dangerous
/// elements.
enum DangerousElementStripper {
    struct Result {
        let text: String
        let removedConstructs: [String]
    }

    /// One element name to strip, kept alongside its ASCII-lowercased
    /// UTF-8 bytes so matching is a plain byte compare.
    private struct DangerousTag {
        let name: String
        /// Lowercase ASCII bytes: every stripped element name is ASCII
        /// letters, so `byte | 0x20` is an exact case-insensitive compare.
        let lowercasedBytes: [UInt8]
    }

    private static let lessThan: UInt8 = 0x3C
    private static let greaterThan: UInt8 = 0x3E
    private static let slash: UInt8 = 0x2F

    static func strip(_ text: String, elementNames: [String]) -> Result {
        let tags: [DangerousTag] = elementNames.compactMap { name in
            let bytes = Array(name.utf8).map { $0 | 0x20 }
            guard !bytes.isEmpty else {
                return nil
            }
            return DangerousTag(name: name, lowercasedBytes: bytes)
        }
        guard !tags.isEmpty else {
            return Result(text: text, removedConstructs: [])
        }

        let stream = Array(text.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(stream.count)
        var removed: [String] = []
        var cursor = 0
        var isTruncated = false

        while true {
            // Resolve every dangerous opening tag currently visible at the
            // end of the output — the one just completed by the byte
            // appended below, and any that a removal has since spliced
            // together out of previously separated fragments.
            while let tag = completedOpeningTag(in: output, tags: tags),
                  isNameDelimiter(stream, at: cursor) {
                let tagStart = output.count - tag.lowercasedBytes.count - 1
                output.removeLast(output.count - tagStart)

                guard !isTruncated,
                      let openTagEnd = index(of: greaterThan, in: stream, from: cursor),
                      let closeTagStart = indexOfCloseTag(
                          stream,
                          from: openTagEnd + 1,
                          tag: tag.lowercasedBytes
                      ) else {
                    // Unterminated: drop everything from the opening tag
                    // to the end of the document rather than leave a
                    // dangling, ambiguous fragment. The loop then runs
                    // again, because the truncation itself can expose a
                    // `<name` that is now at the end of the document.
                    removed.append(
                        "removed unterminated <\(tag.name)> element and trailing content"
                    )
                    cursor = stream.count
                    isTruncated = true
                    continue
                }

                removed.append("removed <\(tag.name)> element")
                cursor = index(of: greaterThan, in: stream, from: closeTagStart)
                    .map { $0 + 1 } ?? stream.count
            }

            guard !isTruncated, cursor < stream.count else {
                break
            }
            output.append(stream[cursor])
            cursor += 1
        }

        return Result(
            text: String(decoding: output, as: UTF8.self),
            removedConstructs: removed
        )
    }

    /// The tag whose opening `<name` the output currently ends with, if
    /// any. Matching against the output rather than the input is what
    /// makes spliced and cross-element-name tags impossible to miss: the
    /// output already *is* the spliced document.
    ///
    /// At most one tag can match, because a match requires `<`
    /// immediately before the name, so two matches would have to be the
    /// same length and therefore the same name.
    private static func completedOpeningTag(
        in output: [UInt8],
        tags: [DangerousTag]
    ) -> DangerousTag? {
        for tag in tags {
            let nameStart = output.count - tag.lowercasedBytes.count
            guard nameStart > 0,
                  output[nameStart - 1] == lessThan,
                  matchesName(output, at: nameStart, tag: tag.lowercasedBytes) else {
                continue
            }
            return tag
        }
        return nil
    }

    /// Whether what follows an element name ends that name: whitespace,
    /// `>`, `/`, or the end of the document. Requiring one of these is
    /// what keeps `<scriptx>` from matching a strip for `<script>`; the
    /// end-of-document case is included because a trailing `<script` is
    /// exactly the unterminated element this stripper refuses to leave
    /// behind.
    private static func isNameDelimiter(_ stream: [UInt8], at index: Int) -> Bool {
        guard index < stream.count else {
            return true
        }
        let byte = stream[index]
        return byte == greaterThan
            || byte == slash
            || isWhitespace(in: stream, at: index)
    }

    /// The index of the next `</name` at or after `start`. Deliberately
    /// does not require a delimiter after the name: a close tag ends the
    /// dangerous region however it is spelled.
    private static func indexOfCloseTag(
        _ stream: [UInt8],
        from start: Int,
        tag: [UInt8]
    ) -> Int? {
        guard start < stream.count else {
            return nil
        }
        for index in start..<stream.count {
            guard stream[index] == lessThan,
                  index + 1 < stream.count,
                  stream[index + 1] == slash,
                  matchesName(stream, at: index + 2, tag: tag) else {
                continue
            }
            return index
        }
        return nil
    }

    private static func matchesName(
        _ stream: [UInt8],
        at start: Int,
        tag: [UInt8]
    ) -> Bool {
        guard start >= 0, start + tag.count <= stream.count else {
            return false
        }
        for offset in 0..<tag.count {
            guard (stream[start + offset] | 0x20) == tag[offset] else {
                return false
            }
        }
        return true
    }

    private static func index(
        of byte: UInt8,
        in stream: [UInt8],
        from start: Int
    ) -> Int? {
        guard start < stream.count else {
            return nil
        }
        for index in start..<stream.count where stream[index] == byte {
            return index
        }
        return nil
    }

    private static func isWhitespace(
        in stream: [UInt8],
        at index: Int
    ) -> Bool {
        let byte = stream[index]
        switch byte {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20:
            return true
        case 0x80...0xFF:
            let end = min(stream.count, index + 4)
            return String(decoding: stream[index..<end], as: UTF8.self)
                .first?.isWhitespace == true
        default:
            return false
        }
    }
}
