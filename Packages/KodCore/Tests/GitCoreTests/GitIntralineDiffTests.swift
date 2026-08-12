import Foundation
@testable import GitCore
import XCTest

final class GitIntralineDiffTests: XCTestCase {
    func testHighlightsChangedCharactersOnPairedLines() throws {
        let hunk = makeHunk(
            removed: "let timeout = 30",
            added: "let timeout = 45"
        )

        let removed = try highlight(at: 0, in: hunk)
        let added = try highlight(at: 1, in: hunk)

        XCTAssertEqual(substrings(in: hunk.lines[0].text, ranges: removed.utf16Ranges), ["30"])
        XCTAssertEqual(substrings(in: hunk.lines[1].text, ranges: added.utf16Ranges), ["45"])
    }

    func testProducesNSStringCompatibleRangesForUnicodeCharacters() throws {
        let hunk = makeHunk(removed: "state 🟢", added: "state 🟡")

        let removed = try highlight(at: 0, in: hunk)
        let added = try highlight(at: 1, in: hunk)

        XCTAssertEqual(removed.utf16Ranges, [6..<8])
        XCTAssertEqual(added.utf16Ranges, [6..<8])
        XCTAssertEqual(substrings(in: hunk.lines[0].text, ranges: removed.utf16Ranges), ["🟢"])
        XCTAssertEqual(substrings(in: hunk.lines[1].text, ranges: added.utf16Ranges), ["🟡"])
    }

    func testExtendsFragmentedMatchesToWholeWords() throws {
        let hunk = makeHunk(
            removed: "value seconds now",
            added: "value semantic now"
        )

        let removed = try highlight(at: 0, in: hunk)
        let added = try highlight(at: 1, in: hunk)

        XCTAssertEqual(
            substrings(in: hunk.lines[0].text, ranges: removed.utf16Ranges),
            ["seconds"]
        )
        XCTAssertEqual(
            substrings(in: hunk.lines[1].text, ranges: added.utf16Ranges),
            ["semantic"]
        )
    }

    func testKeepsSmallSubwordChangesPrecise() throws {
        let hunk = makeHunk(removed: "Voice input", added: "voice input")

        let removed = try highlight(at: 0, in: hunk)
        let added = try highlight(at: 1, in: hunk)

        XCTAssertEqual(
            substrings(in: hunk.lines[0].text, ranges: removed.utf16Ranges),
            ["V"]
        )
        XCTAssertEqual(
            substrings(in: hunk.lines[1].text, ranges: added.utf16Ranges),
            ["v"]
        )
    }

    func testPairsAcrossNoNewlineMarker() throws {
        let hunk = GitDiffHunk(
            oldStart: 1,
            oldCount: 1,
            newStart: 1,
            newCount: 1,
            sectionHeading: nil,
            lines: [
                GitDiffLine(kind: .removed, oldLineNumber: 1, newLineNumber: nil, text: "before"),
                GitDiffLine(
                    kind: .noNewlineAtEndOfFile,
                    oldLineNumber: nil,
                    newLineNumber: nil,
                    text: " No newline at end of file"
                ),
                GitDiffLine(kind: .added, oldLineNumber: nil, newLineNumber: 1, text: "after")
            ]
        )

        let removed = try highlight(at: 0, in: hunk)
        let added = try highlight(at: 2, in: hunk)

        XCTAssertFalse(removed.utf16Ranges.isEmpty)
        XCTAssertFalse(added.utf16Ranges.isEmpty)
    }

    func testDoesNotAddIntralineRangesForUnpairedAdditions() {
        let hunk = GitDiffHunk(
            oldStart: 0,
            oldCount: 0,
            newStart: 1,
            newCount: 1,
            sectionHeading: nil,
            lines: [
                GitDiffLine(kind: .added, oldLineNumber: nil, newLineNumber: 1, text: "new")
            ]
        )

        XCTAssertTrue(GitIntralineDiff.highlights(for: hunk).isEmpty)
    }

    func testComputesChangesAcrossTheWholeMultilineBlock() throws {
        let hunk = GitDiffHunk(
            oldStart: 1,
            oldCount: 2,
            newStart: 1,
            newCount: 3,
            sectionHeading: nil,
            lines: [
                GitDiffLine(
                    kind: .removed,
                    oldLineNumber: 1,
                    newLineNumber: nil,
                    text: "Voice input for the Director composer and free-form input requests, transcribed"
                ),
                GitDiffLine(
                    kind: .removed,
                    oldLineNumber: 2,
                    newLineNumber: nil,
                    text: "server-side and reviewed for three seconds before sending"
                ),
                GitDiffLine(
                    kind: .added,
                    oldLineNumber: nil,
                    newLineNumber: 1,
                    text: "Continuous voice input for the Director composer and free-form input requests,"
                ),
                GitDiffLine(
                    kind: .added,
                    oldLineNumber: nil,
                    newLineNumber: 2,
                    text: "segmented by server-side semantic voice activity detection and sent as ordinary"
                ),
                GitDiffLine(
                    kind: .added,
                    oldLineNumber: nil,
                    newLineNumber: 3,
                    text: "Director messages"
                )
            ]
        )

        let thirdAddedLine = try highlight(at: 4, in: hunk)

        XCTAssertFalse(thirdAddedLine.utf16Ranges.isEmpty)
    }

    func testLineReflowDoesNotCreateWordHighlights() {
        let hunk = GitDiffHunk(
            oldStart: 1,
            oldCount: 2,
            newStart: 1,
            newCount: 2,
            sectionHeading: nil,
            lines: [
                GitDiffLine(kind: .removed, oldLineNumber: 1, newLineNumber: nil, text: "alpha beta"),
                GitDiffLine(kind: .removed, oldLineNumber: 2, newLineNumber: nil, text: "gamma"),
                GitDiffLine(kind: .added, oldLineNumber: nil, newLineNumber: 1, text: "alpha"),
                GitDiffLine(kind: .added, oldLineNumber: nil, newLineNumber: 2, text: "beta gamma")
            ]
        )

        XCTAssertTrue(GitIntralineDiff.highlights(for: hunk).isEmpty)
    }

    private func makeHunk(removed: String, added: String) -> GitDiffHunk {
        GitDiffHunk(
            oldStart: 1,
            oldCount: 1,
            newStart: 1,
            newCount: 1,
            sectionHeading: nil,
            lines: [
                GitDiffLine(kind: .removed, oldLineNumber: 1, newLineNumber: nil, text: removed),
                GitDiffLine(kind: .added, oldLineNumber: nil, newLineNumber: 1, text: added)
            ]
        )
    }

    private func substrings(in text: String, ranges: [Range<Int>]) -> [String] {
        let text = text as NSString
        return ranges.map {
            text.substring(with: NSRange(location: $0.lowerBound, length: $0.count))
        }
    }

    private func highlight(
        at lineIndex: Int,
        in hunk: GitDiffHunk
    ) throws -> GitIntralineHighlight {
        try XCTUnwrap(
            GitIntralineDiff.highlights(for: hunk).first { $0.lineIndex == lineIndex }
        )
    }
}
