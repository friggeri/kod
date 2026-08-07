import Foundation

public struct FindOptions: Equatable, Sendable {
    public var matchCase: Bool
    public var wholeWord: Bool
    public var useRegex: Bool

    public init(
        matchCase: Bool = false,
        wholeWord: Bool = false,
        useRegex: Bool = false
    ) {
        self.matchCase = matchCase
        self.wholeWord = wholeWord
        self.useRegex = useRegex
    }
}

public enum FindError: Error, Equatable {
    case invalidPattern
}

public struct FindMatch: Equatable, Sendable {
    public let utf8Range: Range<Int>

    public init(utf8Range: Range<Int>) {
        self.utf8Range = utf8Range
    }
}

/// Finds plain-text, case-sensitive, whole-word, and regular-expression matches
/// against a `SourceSnapshot`'s immutable text without mutating anything.
///
/// Plain-text and whole-word queries are compiled as an escaped regular
/// expression so that a single, well-tested matching engine backs every mode.
public enum TextFinder {
    public static func find(
        in snapshot: SourceSnapshot,
        query: String,
        options: FindOptions = FindOptions()
    ) throws -> [FindMatch] {
        guard !query.isEmpty else {
            return []
        }

        let text = snapshot.text
        let escaped = options.useRegex ? query : NSRegularExpression.escapedPattern(for: query)
        let pattern = options.wholeWord ? "\\b(?:\(escaped))\\b" : escaped

        var regexOptions: NSRegularExpression.Options = []
        if !options.matchCase {
            regexOptions.insert(.caseInsensitive)
        }

        guard let regex = try? NSRegularExpression(pattern: pattern, options: regexOptions) else {
            throw FindError.invalidPattern
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        // NSRegularExpression reports UTF-16 code-unit ranges, but
        // `SourceSnapshot` addresses everything in UTF-8 byte offsets.
        // `enumerateMatches` always visits matches in increasing location
        // order, so a single monotonically advancing `String.Index` cursor
        // converts every match's UTF-16 offsets to UTF-8 offsets in one
        // forward pass over the text (total work proportional to the text
        // length, not to the match count), instead of precomputing a
        // full UTF-16-code-unit-sized lookup table up front. That table
        // approach cost over a second on a 10 MB file; this cursor keeps
        // Find in File within its 75 ms first-result budget (see
        // `TextFinderPerformanceTests`).
        var cursorIndex = text.utf16.startIndex
        var cursorUTF16Offset = 0
        var cursorUTF8Offset = 0

        func utf8Offset(forUTF16Offset target: Int) -> Int {
            guard target != cursorUTF16Offset else {
                return cursorUTF8Offset
            }
            let targetIndex = text.utf16.index(cursorIndex, offsetBy: target - cursorUTF16Offset)
            cursorUTF8Offset += text.utf8.distance(from: cursorIndex, to: targetIndex)
            cursorIndex = targetIndex
            cursorUTF16Offset = target
            return cursorUTF8Offset
        }

        var matches: [FindMatch] = []
        regex.enumerateMatches(in: text, options: [], range: fullRange) { result, _, _ in
            guard let result else {
                return
            }
            let range = result.range
            guard range.location != NSNotFound,
                  range.location + range.length <= nsText.length else {
                return
            }
            let lowerUTF8 = utf8Offset(forUTF16Offset: range.location)
            let upperUTF8 = utf8Offset(forUTF16Offset: range.location + range.length)
            guard lowerUTF8 <= upperUTF8 else {
                return
            }
            matches.append(FindMatch(utf8Range: lowerUTF8..<upperUTF8))
        }

        return matches
    }
}
