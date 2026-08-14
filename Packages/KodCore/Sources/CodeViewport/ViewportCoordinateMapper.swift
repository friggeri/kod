import Foundation

struct ViewportSourceIdentity: Equatable {
    let line: Int
    let segmentIndex: Int
}

/// Maps source lines, base visual rows, and display rows. Embedded view-zone
/// rows have no source identity and are inserted only at the display layer.
struct ViewportCoordinateMapper {
    let visualRowStarts: [Int]?
    let lineCount: Int
    let viewZoneAfterLine: Int?
    let viewZoneHeight: Int

    var baseTotalRows: Int {
        visualRowStarts?.last ?? lineCount
    }

    var totalRows: Int {
        baseTotalRows + viewZoneHeight
    }

    var viewZoneStartBaseRow: Int? {
        guard let afterLine = viewZoneAfterLine else {
            return nil
        }
        guard afterLine >= 0 else {
            return 0
        }
        return baseRowRange(forLine: afterLine).upperBound
    }

    var viewZoneDisplayRows: Range<Int>? {
        guard let start = viewZoneStartBaseRow else {
            return nil
        }
        return start..<(start + viewZoneHeight)
    }

    func baseRowRange(forLine line: Int) -> Range<Int> {
        guard let starts = visualRowStarts, starts.indices.contains(line + 1) else {
            return line..<(line + 1)
        }
        return starts[line]..<starts[line + 1]
    }

    func displayRowRange(forLine line: Int) -> Range<Int> {
        let base = baseRowRange(forLine: line)
        guard let zoneStart = viewZoneStartBaseRow,
              base.lowerBound >= zoneStart else {
            return base
        }
        return (base.lowerBound + viewZoneHeight)..<(base.upperBound + viewZoneHeight)
    }

    func isViewZoneRow(_ displayRow: Int) -> Bool {
        viewZoneDisplayRows?.contains(displayRow) == true
    }

    func baseRow(forDisplayRow displayRow: Int) -> Int? {
        guard let zoneRows = viewZoneDisplayRows else {
            return displayRow
        }
        if zoneRows.contains(displayRow) {
            return nil
        }
        return displayRow >= zoneRows.upperBound
            ? displayRow - zoneRows.count
            : displayRow
    }

    func sourceIdentity(forDisplayRow row: Int) -> ViewportSourceIdentity {
        guard let baseRow = baseRow(forDisplayRow: row) else {
            let anchor = viewZoneAfterLine ?? -1
            return ViewportSourceIdentity(
                line: max(0, min(anchor, max(0, lineCount - 1))),
                segmentIndex: 0
            )
        }
        return sourceIdentity(forBaseRow: baseRow)
    }

    func sourceIdentity(forBaseRow row: Int) -> ViewportSourceIdentity {
        guard let starts = visualRowStarts, lineCount > 0 else {
            return ViewportSourceIdentity(
                line: max(0, min(row, max(0, lineCount - 1))),
                segmentIndex: 0
            )
        }

        var lowerBound = 0
        var upperBound = starts.count - 1
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound + 1) / 2
            if starts[midpoint] <= row {
                lowerBound = midpoint
            } else {
                upperBound = midpoint - 1
            }
        }
        let line = max(0, min(lowerBound, lineCount - 1))
        return ViewportSourceIdentity(
            line: line,
            segmentIndex: max(0, row - starts[line])
        )
    }
}
