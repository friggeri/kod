import Foundation
import TextDecorationModel
import ThemeCore

struct MinimapPresentationSnapshotBuilder {
    struct Row {
        let visualRow: Int
        let sourceLine: Int?
        let segmentIndex: Int?
        let utf8Range: Range<Int>?
        let text: String
        let decorationRuns: [DecorationRun]
        let isViewZone: Bool
    }

    let maximumColumns: Int
    let defaultForeground: ThemeColor

    func build(
        totalVisualRows: Int,
        requestedRows: Range<Int>,
        rows: [Row]
    ) -> CodeMinimapPresentation {
        let mappedRows = rows.map { row in
            guard let segmentRange = row.utf8Range, !row.isViewZone else {
                return CodeMinimapVisualRow(
                    visualRow: row.visualRow,
                    sourceLine: row.sourceLine,
                    segmentIndex: row.segmentIndex,
                    utf8Range: row.utf8Range,
                    text: "",
                    tokenSpans: [],
                    isViewZone: row.isViewZone
                )
            }
            return CodeMinimapVisualRow(
                visualRow: row.visualRow,
                sourceLine: row.sourceLine,
                segmentIndex: row.segmentIndex,
                utf8Range: segmentRange,
                text: Self.cappedText(row.text, maxColumns: maximumColumns),
                tokenSpans: tokenSpans(
                    text: row.text,
                    segmentRange: segmentRange,
                    runs: row.decorationRuns
                ),
                isViewZone: false
            )
        }
        return CodeMinimapPresentation(
            totalVisualRows: totalVisualRows,
            rows: mappedRows,
            requestedRows: requestedRows
        )
    }

    private func tokenSpans(
        text: String,
        segmentRange: Range<Int>,
        runs: [DecorationRun]
    ) -> [CodeMinimapTokenSpan] {
        runs.compactMap { run in
            let lower = max(segmentRange.lowerBound, run.utf8Range.lowerBound)
            let upper = min(segmentRange.upperBound, run.utf8Range.upperBound)
            guard lower < upper else {
                return nil
            }
            let lowerColumn = Self.displayColumn(
                in: text,
                utf8Offset: lower - segmentRange.lowerBound,
                maximum: maximumColumns
            )
            let upperColumn = Self.displayColumn(
                in: text,
                utf8Offset: upper - segmentRange.lowerBound,
                maximum: maximumColumns
            )
            guard lowerColumn < upperColumn else {
                return nil
            }
            return CodeMinimapTokenSpan(
                columns: lowerColumn..<upperColumn,
                color: run.attributes.foreground ?? defaultForeground
            )
        }
    }

    static func cappedText(_ text: String, maxColumns: Int) -> String {
        var result = ""
        var column = 0
        for character in text {
            if character == "\t" {
                let width = 4 - (column % 4)
                guard column + width <= maxColumns else {
                    break
                }
                result.append(character)
                column += width
                continue
            }
            let width = CodeMinimapGlyphAtlas.shared.glyph(for: character).columns
            guard column + width <= maxColumns else {
                break
            }
            result.append(character)
            column += width
        }
        return result
    }

    static func displayColumn(
        in text: String,
        utf8Offset: Int,
        maximum: Int
    ) -> Int {
        var consumedBytes = 0
        var column = 0
        for character in text {
            guard consumedBytes < utf8Offset, column < maximum else {
                break
            }
            consumedBytes += String(character).utf8.count
            if character == "\t" {
                column += 4 - (column % 4)
            } else {
                column += CodeMinimapGlyphAtlas.shared.glyph(for: character).columns
            }
        }
        return min(maximum, column)
    }
}
