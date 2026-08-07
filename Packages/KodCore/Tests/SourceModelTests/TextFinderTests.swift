import Foundation
import XCTest
@testable import SourceModel

final class TextFinderTests: XCTestCase {
    func testPlainTextFindIsCaseInsensitiveByDefault() throws {
        let snapshot = SourceSnapshot(text: "Alpha alpha ALPHA\nbeta")

        let matches = try TextFinder.find(in: snapshot, query: "alpha")

        XCTAssertEqual(matches.count, 3)
        XCTAssertEqual(try snapshot.text(inUTF8Range: matches[0].utf8Range), "Alpha")
        XCTAssertEqual(try snapshot.text(inUTF8Range: matches[1].utf8Range), "alpha")
        XCTAssertEqual(try snapshot.text(inUTF8Range: matches[2].utf8Range), "ALPHA")
    }

    func testMatchCaseNarrowsResults() throws {
        let snapshot = SourceSnapshot(text: "Alpha alpha ALPHA")

        let matches = try TextFinder.find(
            in: snapshot,
            query: "alpha",
            options: FindOptions(matchCase: true)
        )

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(try snapshot.text(inUTF8Range: matches[0].utf8Range), "alpha")
    }

    func testWholeWordExcludesSubstringMatches() throws {
        let snapshot = SourceSnapshot(text: "cat catalog concatenate cat")

        let matches = try TextFinder.find(
            in: snapshot,
            query: "cat",
            options: FindOptions(wholeWord: true)
        )

        XCTAssertEqual(matches.count, 2)
        for match in matches {
            XCTAssertEqual(try snapshot.text(inUTF8Range: match.utf8Range), "cat")
        }
    }

    func testRegexModeSupportsCapturePatterns() throws {
        let snapshot = SourceSnapshot(text: "value1 value22 value333")

        let matches = try TextFinder.find(
            in: snapshot,
            query: "value\\d{2,}",
            options: FindOptions(useRegex: true)
        )

        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(try snapshot.text(inUTF8Range: matches[0].utf8Range), "value22")
        XCTAssertEqual(try snapshot.text(inUTF8Range: matches[1].utf8Range), "value333")
    }

    func testInvalidRegexThrowsWithoutCrashing() {
        let snapshot = SourceSnapshot(text: "anything")

        XCTAssertThrowsError(
            try TextFinder.find(
                in: snapshot,
                query: "(unterminated",
                options: FindOptions(useRegex: true)
            )
        ) { error in
            XCTAssertEqual(error as? FindError, .invalidPattern)
        }
    }

    func testEmptyQueryProducesNoMatches() throws {
        let snapshot = SourceSnapshot(text: "some text")
        XCTAssertEqual(try TextFinder.find(in: snapshot, query: ""), [])
    }

    func testMatchesAcrossUnicodeAndEmojiOffsetsRemainValidUTF8Boundaries() throws {
        let snapshot = SourceSnapshot(text: "a😀b needle 😀 needle end")

        let matches = try TextFinder.find(in: snapshot, query: "needle")

        XCTAssertEqual(matches.count, 2)
        for match in matches {
            // Decoding must not throw SourceSnapshotError.invalidCharacterBoundary.
            XCTAssertEqual(try snapshot.text(inUTF8Range: match.utf8Range), "needle")
        }
    }

    func testFindWithinLargeFileStaysWellUnderPerformanceBudget() throws {
        var text = ""
        text.reserveCapacity(2_000_000)
        for line in 0..<50_000 {
            text += "line \(line) contains a target token and more filler text\n"
        }
        let snapshot = SourceSnapshot(text: text)

        let start = ContinuousClock.now
        let matches = try TextFinder.find(in: snapshot, query: "target")
        let elapsed = ContinuousClock.now - start

        XCTAssertEqual(matches.count, 50_000)
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    /// SPEC 12.2 sets a 75 ms p95 budget (on the reference Apple-silicon
    /// machine, in an optimized build) for Find in File's first result in a
    /// 10 MB file. This is a pathological worst case — a match on almost
    /// every line — that exercises the UTF-16-to-UTF-8 offset conversion
    /// across the entire file, not just a rare single match. Debug XCTest
    /// binaries on shared/virtualized hardware run slower than the
    /// optimized reference measurement, so this regression gate uses a
    /// looser bound that still fails hard if the O(n) single-pass offset
    /// cursor regresses back to a full precomputed table (which measured
    /// over 1 second on the same input before this optimization).
    func testFindWithinTenMegabyteFileStaysWithinPerformanceBudget() throws {
        var text = ""
        text.reserveCapacity(10 * 1_024 * 1_024 + 1_024)
        var lineCount = 0
        while text.utf8.count < 10 * 1_024 * 1_024 {
            text += "line \(lineCount) contains a target token and more filler text padding padding\n"
            lineCount += 1
        }
        let snapshot = SourceSnapshot(text: text)

        let start = ContinuousClock.now
        let matches = try TextFinder.find(in: snapshot, query: "target")
        let elapsed = ContinuousClock.now - start

        XCTAssertEqual(matches.count, lineCount)
        XCTAssertLessThan(elapsed, .milliseconds(250))
        for match in matches.prefix(5) + matches.suffix(5) {
            XCTAssertEqual(try snapshot.text(inUTF8Range: match.utf8Range), "target")
        }
    }

    func testFindOffsetsRemainCorrectWithNonASCIIContentBeforeMatches() throws {
        var text = "café π 日本語 emoji 😀 line\n"
        text += String(repeating: "filler ", count: 200)
        text += "needle at the end\n"
        let snapshot = SourceSnapshot(text: text)

        let matches = try TextFinder.find(in: snapshot, query: "needle")

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(try snapshot.text(inUTF8Range: matches[0].utf8Range), "needle")
    }
}
