import CoreGraphics
import Foundation
import SourceModel

/// Pure wrap/fold layout state. Core Text lines remain owned by `CodeViewport`;
/// this engine caches only value-type row and UTF-8 segment mappings.
struct TextLayoutEngine {
    struct CacheKey: Equatable {
        let wrapColumns: Int?
        let foldVersion: Int
    }

    private(set) var visualRowStarts: [Int]?
    private(set) var wrapColumnsUsed = 0
    private(set) var hiddenLines: [Bool] = []
    private(set) var cacheKey: CacheKey?
    private var wrappedSegments: [Int: [Range<Int>]] = [:]

    mutating func invalidate() {
        visualRowStarts = nil
        wrapColumnsUsed = 0
        hiddenLines = []
        cacheKey = nil
        wrappedSegments.removeAll(keepingCapacity: true)
    }

    /// Returns whether cached Core Text lines must also be discarded.
    @discardableResult
    mutating func rebuildIfNeeded(
        snapshot: SourceSnapshot,
        wrapEnabled: Bool,
        maximumColumns: Int,
        folds: FoldState
    ) -> Bool {
        guard wrapEnabled || folds.isActive else {
            guard visualRowStarts != nil else {
                return false
            }
            invalidate()
            return true
        }
        guard !wrapEnabled || maximumColumns > 0 else {
            return false
        }

        let key = CacheKey(
            wrapColumns: wrapEnabled ? maximumColumns : nil,
            foldVersion: folds.version
        )
        guard visualRowStarts == nil || cacheKey != key else {
            return false
        }

        let hidden = folds.hiddenLines(lineCount: snapshot.lineCount)
        var starts = [Int](repeating: 0, count: snapshot.lineCount + 1)
        for line in 0..<snapshot.lineCount {
            let rowCount: Int
            if hidden.indices.contains(line), hidden[line] {
                rowCount = 0
            } else if wrapEnabled {
                rowCount = Self.wrapUnitRanges(
                    snapshot.line(at: line) ?? "",
                    maxColumns: maximumColumns
                ).count
            } else {
                rowCount = 1
            }
            starts[line + 1] = starts[line] + rowCount
        }
        visualRowStarts = starts
        hiddenLines = hidden
        wrapColumnsUsed = maximumColumns
        cacheKey = key
        wrappedSegments.removeAll(keepingCapacity: true)
        return true
    }

    mutating func segments(
        forLine line: Int,
        snapshot: SourceSnapshot,
        wrapEnabled: Bool
    ) -> [Range<Int>] {
        guard let lineRange = snapshot.utf8RangeForLine(line) else {
            return []
        }
        guard wrapEnabled, visualRowStarts != nil, wrapColumnsUsed > 0 else {
            return [lineRange]
        }
        if let cached = wrappedSegments[line] {
            return cached
        }

        let unitRanges = Self.wrapUnitRanges(
            snapshot.line(at: line) ?? "",
            maxColumns: wrapColumnsUsed
        )
        var utf8Segments: [Range<Int>] = []
        utf8Segments.reserveCapacity(unitRanges.count)
        for (index, unitRange) in unitRanges.enumerated() {
            let startOffset: Int
            if unitRange.lowerBound == 0 {
                startOffset = lineRange.lowerBound
            } else {
                startOffset = (try? snapshot.utf8Offset(
                    for: SourcePosition(line: line, character: unitRange.lowerBound),
                    encoding: .utf16
                )) ?? lineRange.lowerBound
            }
            let endOffset: Int
            if index == unitRanges.count - 1 {
                endOffset = lineRange.upperBound
            } else {
                endOffset = (try? snapshot.utf8Offset(
                    for: SourcePosition(line: line, character: unitRange.upperBound),
                    encoding: .utf16
                )) ?? lineRange.upperBound
            }
            utf8Segments.append(startOffset..<max(startOffset, endOffset))
        }

        let segments = utf8Segments.isEmpty ? [lineRange] : utf8Segments
        wrappedSegments[line] = segments
        return segments
    }

    static func maximumColumns(
        viewportWidth: CGFloat,
        gutterWidth: CGFloat,
        rightPadding: CGFloat,
        characterWidth: CGFloat
    ) -> Int {
        let availableWidth = max(
            viewportWidth,
            gutterWidth + rightPadding + characterWidth
        )
        return max(
            1,
            Int(floor((availableWidth - gutterWidth - rightPadding) / characterWidth))
        )
    }

    static func contentWidth(
        viewportWidth: CGFloat,
        gutterWidth: CGFloat,
        rightPadding: CGFloat,
        characterWidth: CGFloat,
        longestLineUTF8Length: Int,
        wraps: Bool
    ) -> CGFloat {
        if wraps {
            return max(viewportWidth, gutterWidth + rightPadding + characterWidth)
        }
        return max(
            viewportWidth,
            gutterWidth + CGFloat(longestLineUTF8Length) * characterWidth + rightPadding
        )
    }

    static func wrapUnitRanges(_ text: String, maxColumns: Int) -> [Range<Int>] {
        let units = Array(text.utf16)
        let unitCount = units.count
        guard unitCount > maxColumns else {
            return [0..<unitCount]
        }

        var ranges: [Range<Int>] = []
        var start = 0
        while start < unitCount {
            let hardEnd = min(start + maxColumns, unitCount)
            var breakUnit = hardEnd
            if hardEnd < unitCount {
                var candidate = hardEnd
                while candidate > start, !isWrapWhitespace(units[candidate - 1]) {
                    candidate -= 1
                }
                if candidate > start {
                    breakUnit = candidate
                }
            }
            ranges.append(start..<breakUnit)
            start = breakUnit
        }
        return ranges.isEmpty ? [0..<unitCount] : ranges
    }

    private static func isWrapWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09
    }
}
