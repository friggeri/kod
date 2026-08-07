import XCTest
@testable import PreviewCore

final class JSONParserTests: XCTestCase {
    // MARK: - Golden

    func testParsesFlatObject() throws {
        let json = #"{"a": 1, "b": "two", "c": true, "d": false, "e": null}"#
        let result = JSONParser.parse(Data(json.utf8))
        guard case .valid(.object(let members)) = result else {
            return XCTFail("expected a valid object, got \(result)")
        }
        XCTAssertEqual(members.map(\.key), ["a", "b", "c", "d", "e"])
        XCTAssertEqual(members[0].value, .number("1"))
        XCTAssertEqual(members[1].value, .string("two"))
        XCTAssertEqual(members[2].value, .bool(true))
        XCTAssertEqual(members[3].value, .bool(false))
        XCTAssertEqual(members[4].value, .null)
    }

    func testPreservesKeyOrderAcrossManyKeys() {
        let keys = (0..<50).map { "key\($0)" }
        let json = "{" + keys.map { "\"\($0)\": \($0.count)" }.joined(separator: ",") + "}"
        guard case .valid(.object(let members)) = JSONParser.parse(Data(json.utf8)) else {
            return XCTFail("expected valid object")
        }
        XCTAssertEqual(members.map(\.key), keys, "member order must be stable source order, not resorted")
    }

    func testParsesNestedArraysAndObjects() {
        let json = #"{"items": [1, 2, {"nested": [true, false, null]}]}"#
        guard case .valid(let node) = JSONParser.parse(Data(json.utf8)) else {
            return XCTFail("expected valid")
        }
        guard case .object(let members) = node, case .array(let items) = members[0].value else {
            return XCTFail("expected items array")
        }
        XCTAssertEqual(items.count, 3)
        guard case .object(let nestedMembers) = items[2], case .array(let nestedItems) = nestedMembers[0].value else {
            return XCTFail("expected nested array")
        }
        XCTAssertEqual(nestedItems, [.bool(true), .bool(false), .null])
    }

    func testParsesUnicodeEscapesIncludingSurrogatePairs() {
        let json = #"{"emoji": "\ud83d\ude00", "simple": "\u00e9"}"#
        guard case .valid(.object(let members)) = JSONParser.parse(Data(json.utf8)) else {
            return XCTFail("expected valid object")
        }
        XCTAssertEqual(members[0].value, .string("😀"))
        XCTAssertEqual(members[1].value, .string("é"))
    }

    func testParsesNumberVariants() {
        let json = "[0, -1, 1.5, -1.5e10, 2E-3, 1e+5]"
        guard case .valid(.array(let elements)) = JSONParser.parse(Data(json.utf8)) else {
            return XCTFail("expected valid array")
        }
        XCTAssertEqual(elements, [
            .number("0"), .number("-1"), .number("1.5"), .number("-1.5e10"), .number("2E-3"), .number("1e+5")
        ])
    }

    func testWhitespaceInsignificantAroundStructure() {
        let json = "  {  \"a\"  :  1  ,  \"b\"  :  2  }  "
        guard case .valid(.object(let members)) = JSONParser.parse(Data(json.utf8)) else {
            return XCTFail("expected valid object")
        }
        XCTAssertEqual(members.count, 2)
    }

    // MARK: - Hostile / diagnostics

    func testDuplicateKeyIsReportedNotSilentlyOverwritten() {
        let json = #"{"a": 1, "a": 2}"#
        let result = JSONParser.parse(Data(json.utf8))
        guard case .invalid(.duplicateKey(let key, _)) = result else {
            return XCTFail("expected duplicateKey diagnostic, got \(result)")
        }
        XCTAssertEqual(key, "a")
    }

    func testTruncatedObjectReportsUnexpectedEndOfInput() {
        let json = #"{"a": 1"#
        guard case .invalid(.unexpectedEndOfInput) = JSONParser.parse(Data(json.utf8)) else {
            return XCTFail("expected unexpectedEndOfInput diagnostic")
        }
    }

    func testTrailingContentIsRejected() {
        let json = #"{"a": 1} garbage"#
        guard case .invalid(.trailingContent) = JSONParser.parse(Data(json.utf8)) else {
            return XCTFail("expected trailingContent diagnostic")
        }
    }

    func testInvalidEscapeSequenceIsRejected() {
        let json = #"{"a": "\q"}"#
        guard case .invalid(.invalidEscapeSequence) = JSONParser.parse(Data(json.utf8)) else {
            return XCTFail("expected invalidEscapeSequence diagnostic")
        }
    }

    func testLoneHighSurrogateIsRejected() {
        let json = #"{"a": "\ud83d"}"#
        guard case .invalid = JSONParser.parse(Data(json.utf8)) else {
            return XCTFail("expected a lone surrogate to be rejected, not silently accepted")
        }
    }

    func testUnterminatedStringIsRejected() {
        let json = #"{"a": "unterminated"#
        guard case .invalid = JSONParser.parse(Data(json.utf8)) else {
            return XCTFail("expected invalid result")
        }
    }

    func testControlCharacterInStringIsRejected() {
        let json = "{\"a\": \"line\nbreak\"}"
        guard case .invalid = JSONParser.parse(Data(json.utf8)) else {
            return XCTFail("expected raw control characters in a string to be rejected")
        }
    }

    func testDeeplyNestedArrayExceedsDepthLimit() {
        let depth = 10_000
        let json = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        let limits = StructuredDataLimits(maximumDepth: 500)
        guard case .invalid(.depthLimitExceeded(let limit, _)) = JSONParser.parse(Data(json.utf8), limits: limits) else {
            return XCTFail("expected depthLimitExceeded for a 10,000-deep array against a 500 limit")
        }
        XCTAssertEqual(limit, 500)
    }

    func testDeeplyNestedArrayDoesNotCrashTheProcess() {
        // A stack-overflow crash is not a "diagnostic" outcome — this
        // proves the depth guard actually stops recursion before the
        // real call stack would.
        let depth = 2_000_000
        let json = String(repeating: "[", count: depth)
        let result = JSONParser.parse(Data(json.utf8))
        XCTAssertNotNil(result.diagnostic, "a pathologically deep unterminated array must fail with a diagnostic, not hang or crash")
    }

    func testManyKeysExceedsNodeCountLimit() {
        let json = "{" + (0..<10_000).map { "\"k\($0)\": \($0)" }.joined(separator: ",") + "}"
        let limits = StructuredDataLimits(maximumNodeCount: 100)
        guard case .invalid(.nodeCountLimitExceeded) = JSONParser.parse(Data(json.utf8), limits: limits) else {
            return XCTFail("expected nodeCountLimitExceeded")
        }
    }

    func testOversizedStringExceedsStringLimit() {
        let json = "{\"a\": \"\(String(repeating: "x", count: 10_000))\"}"
        let limits = StructuredDataLimits(maximumStringLength: 100)
        guard case .invalid(.stringTooLong) = JSONParser.parse(Data(json.utf8), limits: limits) else {
            return XCTFail("expected stringTooLong")
        }
    }

    func testSourceTooLargeIsRejectedBeforeParsing() {
        let json = "[" + String(repeating: "1,", count: 1_000) + "1]"
        let limits = StructuredDataLimits(maximumSourceLength: 10)
        guard case .invalid(.sourceTooLarge) = JSONParser.parse(Data(json.utf8), limits: limits) else {
            return XCTFail("expected sourceTooLarge")
        }
    }

    func testInvalidUTF8IsRejectedRatherThanSubstituted() {
        var bytes = Array(#"{"a": ""#.utf8)
        bytes.append(0xFF) // invalid UTF-8 continuation byte
        bytes.append(contentsOf: Array(#""}"#.utf8))
        guard case .invalid = JSONParser.parse(Data(bytes)) else {
            return XCTFail("expected invalid UTF-8 to be rejected")
        }
    }

    func testEmptyInputIsInvalidNotEmptySuccess() {
        guard case .invalid = JSONParser.parse(Data()) else {
            return XCTFail("empty input must be an explicit diagnostic, never a silently-empty success value")
        }
    }
}
