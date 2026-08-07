import Foundation
import XCTest
@testable import SearchCore

final class RipgrepStreamParserTests: XCTestCase {
    func testDecodesBeginMatchAndEndLines() throws {
        var parser = RipgrepStreamParser()
        let input = Data(
            """
            {"type":"begin","data":{"path":{"text":"/root/file.txt"}}}
            {"type":"match","data":{"path":{"text":"/root/file.txt"},"lines":{"text":"needle here\\n"},"line_number":3,"submatches":[{"match":{"text":"needle"},"start":0,"end":6}]}}
            {"type":"end","data":{"path":{"text":"/root/file.txt"},"binary_offset":null,"stats":{}}}
            {"type":"summary","data":{}}

            """.utf8
        )

        let lines = try parser.consume(input)

        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], .begin)
        guard case .match(
            let path,
            let lineNumber,
            let text,
            let isValidUTF8,
            let ranges
        ) = lines[1] else {
            return XCTFail("expected a match line")
        }
        XCTAssertEqual(path, "/root/file.txt")
        XCTAssertEqual(lineNumber, 3)
        XCTAssertEqual(text, "needle here")
        XCTAssertTrue(isValidUTF8)
        XCTAssertEqual(ranges, [SearchMatchRange(utf8Range: 0..<6)])
        XCTAssertEqual(lines[2], .end)
        XCTAssertEqual(lines[3], .summary)
    }

    func testLineSpanningMultipleChunksDecodesOnceComplete() throws {
        var parser = RipgrepStreamParser()
        let full = Data(
            """
            {"type":"match","data":{"path":{"text":"/root/a.txt"},"lines":{"text":"needle\\n"},"line_number":1,"submatches":[{"match":{"text":"needle"},"start":0,"end":6}]}}

            """.utf8
        )
        let splitPoint = full.count / 2
        let firstHalf = full.prefix(splitPoint)
        let secondHalf = full.suffix(from: splitPoint)

        let firstResult = try parser.consume(Data(firstHalf))
        XCTAssertEqual(firstResult, [])

        let secondResult = try parser.consume(Data(secondHalf))
        XCTAssertEqual(secondResult.count, 1)
    }

    func testDecodesNonUTF8LineViaBase64BytesFallback() throws {
        var parser = RipgrepStreamParser()
        let rawLine = Data("needle \u{FF}\u{FE} tail\n".utf8)
        // Deliberately not valid UTF-8: build the raw bytes directly.
        var invalidBytes = Data("needle ".utf8)
        invalidBytes.append(contentsOf: [0xFF, 0xFE])
        invalidBytes.append(contentsOf: Data(" tail\n".utf8))
        let base64 = invalidBytes.base64EncodedString()

        let json = """
        {"type":"match","data":{"path":{"text":"/root/binary.dat"},"lines":{"bytes":"\(base64)"},"line_number":1,"submatches":[{"match":{"text":"needle"},"start":0,"end":6}]}}

        """
        _ = rawLine

        let lines = try parser.consume(Data(json.utf8))

        XCTAssertEqual(lines.count, 1)
        guard case .match(_, _, let text, let isValidUTF8, let ranges) = lines[0] else {
            return XCTFail("expected a match line")
        }
        XCTAssertFalse(isValidUTF8)
        XCTAssertTrue(text.hasPrefix("needle "))
        XCTAssertEqual(ranges, [SearchMatchRange(utf8Range: 0..<6)])
    }

    func testMalformedJSONLineThrows() {
        var parser = RipgrepStreamParser()
        let input = Data("not json at all\n".utf8)

        XCTAssertThrowsError(try parser.consume(input)) { error in
            guard case RipgrepStreamParser.ParseError.invalidJSON = error else {
                return XCTFail("expected invalidJSON, got \(error)")
            }
        }
    }

    func testUnknownMessageTypeThrows() {
        var parser = RipgrepStreamParser()
        let input = Data((#"{"type":"mystery","data":{}}"# + "\n").utf8)

        XCTAssertThrowsError(try parser.consume(input))
    }

    func testOversizedSingleLineThrowsBoundedError() {
        var parser = RipgrepStreamParser(maxLineByteCount: 64)
        // No newline at all: an unbounded, hostile single "line".
        let hostile = Data(repeating: 0x41, count: 128)

        XCTAssertThrowsError(try parser.consume(hostile)) { error in
            guard case RipgrepStreamParser.ParseError.lineExceedsBufferLimit = error else {
                return XCTFail("expected lineExceedsBufferLimit, got \(error)")
            }
        }
    }

    func testUnterminatedTrailingDataAtFinishThrows() throws {
        var parser = RipgrepStreamParser()
        // No trailing newline: rg always terminates every line, so this is
        // itself an explicit malformed-output signal at process exit.
        let input = Data(#"{"type":"begin","data":{"path":{"text":"x"}}}"#.utf8)
        XCTAssertEqual(try parser.consume(input), [])

        XCTAssertThrowsError(try parser.finish()) { error in
            guard case RipgrepStreamParser.ParseError.invalidJSON = error else {
                return XCTFail("expected invalidJSON, got \(error)")
            }
        }
    }

    func testEmptyBufferAtFinishDoesNotThrow() throws {
        var parser = RipgrepStreamParser()
        _ = try parser.consume(Data((#"{"type":"begin","data":{"path":{"text":"x"}}}"# + "\n").utf8))
        XCTAssertNoThrow(try parser.finish())
    }

    func testContextLinesAreIgnoredRatherThanRejected() throws {
        var parser = RipgrepStreamParser()
        let input = Data((#"{"type":"context","data":{"path":{"text":"x"},"lines":{"text":"noise\n"},"line_number":1}}"# + "\n").utf8)
        let lines = try parser.consume(input)
        XCTAssertEqual(lines, [RipgrepLine]())
    }
}
