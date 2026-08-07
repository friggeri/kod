import Foundation

/// A matched pair of bracket byte offsets (each pointing at the single
/// bracket byte itself, not a range).
public struct BracketMatch: Equatable, Sendable {
    public let opening: Int
    public let closing: Int

    public init(opening: Int, closing: Int) {
        self.opening = opening
        self.closing = closing
    }
}

/// Finds the matching bracket for `(`, `)`, `{`, `}`, `[`, `]` by scanning
/// the raw byte stream while skipping any byte that falls inside a
/// `string`- or `comment`-classified highlight capture. This is
/// intentionally grammar-agnostic: rather than requiring per-language
/// knowledge of which node types represent a paired delimiter (which
/// differs across all seven launch grammars), it reuses the highlight
/// captures Kod already computes to exclude bracket-like bytes that are
/// actually inside string or comment content, then matches the remaining
/// brackets purely lexically. This is correct for any well-formed source
/// file, which is what bracket navigation is for.
public enum BracketMatcher {
    private static let openingToClosing: [UInt8: UInt8] = [
        UInt8(ascii: "("): UInt8(ascii: ")"),
        UInt8(ascii: "{"): UInt8(ascii: "}"),
        UInt8(ascii: "["): UInt8(ascii: "]")
    ]
    private static let closingToOpening: [UInt8: UInt8] = Dictionary(
        uniqueKeysWithValues: openingToClosing.map { ($1, $0) }
    )

    /// Finds the bracket match for the bracket byte at or immediately
    /// before `utf8Offset` (so a caret placed just after a bracket still
    /// matches it, matching common editor behavior).
    public static func match(
        utf8: Data,
        utf8Offset: Int,
        excluding excludedRanges: [Range<Int>]
    ) -> BracketMatch? {
        guard let (offset, byte) = bracketByte(in: utf8, near: utf8Offset, excluding: excludedRanges) else {
            return nil
        }

        if let closingByte = openingToClosing[byte] {
            return findForward(
                utf8: utf8,
                from: offset,
                opening: byte,
                closing: closingByte,
                excludedRanges: excludedRanges
            ).map { BracketMatch(opening: offset, closing: $0) }
        }
        if let openingByte = closingToOpening[byte] {
            return findBackward(
                utf8: utf8,
                from: offset,
                opening: openingByte,
                closing: byte,
                excludedRanges: excludedRanges
            ).map { BracketMatch(opening: $0, closing: offset) }
        }
        return nil
    }

    private static func bracketByte(
        in utf8: Data,
        near utf8Offset: Int,
        excluding excludedRanges: [Range<Int>]
    ) -> (offset: Int, byte: UInt8)? {
        for candidate in [utf8Offset, utf8Offset - 1] {
            guard candidate >= 0, candidate < utf8.count, !isExcluded(candidate, excludedRanges) else {
                continue
            }
            let byte = utf8[utf8.startIndex + candidate]
            if openingToClosing[byte] != nil || closingToOpening[byte] != nil {
                return (candidate, byte)
            }
        }
        return nil
    }

    private static func findForward(
        utf8: Data,
        from start: Int,
        opening: UInt8,
        closing: UInt8,
        excludedRanges: [Range<Int>]
    ) -> Int? {
        var depth = 0
        var index = start
        let base = utf8.startIndex
        while index < utf8.count {
            defer { index += 1 }
            guard !isExcluded(index, excludedRanges) else {
                continue
            }
            let byte = utf8[base + index]
            if byte == opening {
                depth += 1
            } else if byte == closing {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
        }
        return nil
    }

    private static func findBackward(
        utf8: Data,
        from start: Int,
        opening: UInt8,
        closing: UInt8,
        excludedRanges: [Range<Int>]
    ) -> Int? {
        var depth = 0
        var index = start
        let base = utf8.startIndex
        while index >= 0 {
            defer { index -= 1 }
            guard !isExcluded(index, excludedRanges) else {
                continue
            }
            let byte = utf8[base + index]
            if byte == closing {
                depth += 1
            } else if byte == opening {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
        }
        return nil
    }

    private static func isExcluded(_ offset: Int, _ ranges: [Range<Int>]) -> Bool {
        ranges.contains { $0.contains(offset) }
    }
}
