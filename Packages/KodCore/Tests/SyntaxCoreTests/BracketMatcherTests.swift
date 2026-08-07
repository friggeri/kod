import Foundation
import XCTest
@testable import SyntaxCore

final class BracketMatcherTests: XCTestCase {
    func testMatchesSimpleParentheses() {
        let source = "foo(bar)"
        let data = Data(source.utf8)
        let openOffset = source.utf8.distance(from: source.utf8.startIndex, to: source.utf8.firstIndex(of: UInt8(ascii: "("))!)
        let match = BracketMatcher.match(utf8: data, utf8Offset: openOffset, excluding: [])
        XCTAssertEqual(match?.opening, openOffset)
        XCTAssertEqual(match?.closing, source.utf8.count - 1)
    }

    func testIgnoresBracketsInsideExcludedStringRange() {
        let source = "f(\"a)b\", c)"
        let data = Data(source.utf8)
        // The string literal "a)b" spans bytes 2..<9 (including quotes);
        // exclude it so the `)` inside it is not treated as real.
        let stringRange = 2..<9
        let openOffset = 1
        let match = BracketMatcher.match(utf8: data, utf8Offset: openOffset, excluding: [stringRange])
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.opening, 1)
        XCTAssertEqual(match?.closing, source.utf8.count - 1)
    }

    func testMatchesFromClosingBracketBackward() {
        let source = "{ nested }"
        let data = Data(source.utf8)
        let closeOffset = source.utf8.count - 1
        let match = BracketMatcher.match(utf8: data, utf8Offset: closeOffset, excluding: [])
        XCTAssertEqual(match?.opening, 0)
        XCTAssertEqual(match?.closing, closeOffset)
    }

    func testReturnsNilWhenUnbalanced() {
        let source = "(unbalanced"
        let data = Data(source.utf8)
        XCTAssertNil(BracketMatcher.match(utf8: data, utf8Offset: 0, excluding: []))
    }

    func testMatchesNestedBracketsAtCorrectDepth() {
        let source = "([{}])"
        let data = Data(source.utf8)
        // Outer parens at 0 and 5
        let outer = BracketMatcher.match(utf8: data, utf8Offset: 0, excluding: [])
        XCTAssertEqual(outer, BracketMatch(opening: 0, closing: 5))
        // Inner brace at 2 and 3
        let inner = BracketMatcher.match(utf8: data, utf8Offset: 2, excluding: [])
        XCTAssertEqual(inner, BracketMatch(opening: 2, closing: 3))
    }
}
