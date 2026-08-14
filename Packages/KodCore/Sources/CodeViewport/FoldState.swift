import SyntaxCore

/// Owns fold discovery and the user's collapsed-header selection.
///
/// Pending headers intentionally survive syntax-tree replacement: reload can
/// restore folds before the first compatible parse has completed.
struct FoldState {
    private(set) var rangesByHeaderLine: [Int: FoldRange] = [:]
    private(set) var foldedHeaderLines: Set<Int> = []
    private(set) var pendingHeaderLines: Set<Int> = []
    private(set) var version = 0

    var isActive: Bool {
        !foldedHeaderLines.isEmpty
    }

    var foldableHeaderLines: Set<Int> {
        Set(rangesByHeaderLine.keys)
    }

    func isFoldable(_ line: Int) -> Bool {
        rangesByHeaderLine[line] != nil
    }

    func isFolded(_ line: Int) -> Bool {
        foldedHeaderLines.contains(line)
    }

    mutating func apply(_ tree: SyntaxTree) {
        apply(ranges: tree.foldRanges())
    }

    mutating func apply(ranges: [FoldRange]) {
        rangesByHeaderLine = Self.ranges(from: ranges)
        foldedHeaderLines = foldedHeaderLines.union(pendingHeaderLines)
            .filter { rangesByHeaderLine[$0] != nil }
        version += 1
    }

    @discardableResult
    mutating func restore(_ lines: Set<Int>) -> Bool {
        pendingHeaderLines = lines
        let applicable = lines.filter { rangesByHeaderLine[$0] != nil }
        guard !applicable.isEmpty else {
            return false
        }
        foldedHeaderLines.formUnion(applicable)
        version += 1
        return true
    }

    @discardableResult
    mutating func toggle(_ line: Int) -> Bool {
        guard rangesByHeaderLine[line] != nil else {
            return false
        }
        if foldedHeaderLines.contains(line) {
            foldedHeaderLines.remove(line)
        } else {
            foldedHeaderLines.insert(line)
        }
        version += 1
        return true
    }

    func hiddenLines(lineCount: Int) -> [Bool] {
        guard isActive, lineCount > 0 else {
            return []
        }
        var hidden = [Bool](repeating: false, count: lineCount)
        for header in foldedHeaderLines {
            guard let range = rangesByHeaderLine[header] else {
                continue
            }
            let start = range.headerLine + 1
            let end = min(range.endLine, lineCount - 1)
            guard start <= end else {
                continue
            }
            for line in start...end {
                hidden[line] = true
            }
        }
        return hidden
    }

    func visibleHeader(containing line: Int) -> Int? {
        foldedHeaderLines
            .filter { header in
                guard let fold = rangesByHeaderLine[header] else {
                    return false
                }
                return line > fold.headerLine && line <= fold.endLine
            }
            .max()
    }

    @discardableResult
    mutating func reveal(line: Int) -> Bool {
        let containingHeaders = foldedHeaderLines.filter { header in
            guard let range = rangesByHeaderLine[header] else {
                return false
            }
            return line > range.headerLine && line <= range.endLine
        }
        guard !containingHeaders.isEmpty else {
            return false
        }
        foldedHeaderLines.subtract(containingHeaders)
        version += 1
        return true
    }

    static func ranges(from ranges: [FoldRange]) -> [Int: FoldRange] {
        var byHeader: [Int: FoldRange] = [:]
        for range in ranges {
            if let existing = byHeader[range.headerLine], existing.endLine >= range.endLine {
                continue
            }
            byHeader[range.headerLine] = range
        }
        return byHeader
    }
}
