import XCTest
@testable import PreviewCore

final class StructuredSearchAndPathTests: XCTestCase {
    func testKeyPathDisplayStringUsesDotAndBracketNotation() {
        let path: StructuredPath = [.key("root"), .index(2), .key("odd key")]
        XCTAssertEqual(path.displayString, "root.root[2][\"odd key\"]")
    }

    func testSearchFindsMatchingKeysAndValues() throws {
        let json = #"{"name": "Kod", "nested": {"target": "found me"}, "list": ["nope", "target value"]}"#
        guard case .valid(let root) = JSONParser.parse(Data(json.utf8)) else {
            return XCTFail("expected valid parse")
        }
        let matches = StructuredSearch.search(root, query: "target")
        XCTAssertTrue(matches.contains { $0.path == [.key("nested"), .key("target")] && $0.location == .key })
        XCTAssertTrue(matches.contains { $0.location == .value && $0.node == .string("target value") })
    }

    func testSearchIsCaseInsensitive() throws {
        let json = #"{"Name": "KOD"}"#
        guard case .valid(let root) = JSONParser.parse(Data(json.utf8)) else {
            return XCTFail("expected valid parse")
        }
        XCTAssertFalse(StructuredSearch.search(root, query: "kod").isEmpty)
        XCTAssertFalse(StructuredSearch.search(root, query: "name").isEmpty)
    }

    func testEmptyQueryReturnsNoMatches() throws {
        guard case .valid(let root) = JSONParser.parse(Data(#"{"a": 1}"#.utf8)) else {
            return XCTFail("expected valid parse")
        }
        XCTAssertEqual(StructuredSearch.search(root, query: ""), [])
    }

    func testSearchOverPathologicallyWideDocumentIsBoundedAndDoesNotHang() {
        // Every one of 200,000 keys matches "k" — the result count must
        // still be capped rather than building an unbounded array.
        let json = "{" + (0..<200_000).map { "\"k\($0)\": \($0)" }.joined(separator: ",") + "}"
        let limits = StructuredDataLimits(maximumNodeCount: 1_000_000)
        guard case .valid(let root) = JSONParser.parse(Data(json.utf8), limits: limits) else {
            return XCTFail("expected valid parse")
        }
        let matches = StructuredSearch.search(root, query: "k")
        XCTAssertEqual(matches.count, StructuredSearch.maximumMatches)
    }

    func testSearchOverDeepDocumentDoesNotOverflowStack() {
        // Bounded by the parser's own default depth limit (so building
        // this fixture cannot itself overflow the real call stack); the
        // point of this test is that `StructuredSearch`'s walk is
        // iterative (an explicit stack), not recursive, and completes
        // cleanly at that bound.
        let depth = 400
        let json = String(repeating: "[", count: depth) + "\"leaf\"" + String(repeating: "]", count: depth)
        guard case .valid(let root) = JSONParser.parse(Data(json.utf8)) else {
            return XCTFail("expected valid parse within the default depth limit")
        }
        let matches = StructuredSearch.search(root, query: "leaf")
        XCTAssertEqual(matches.count, 1)
    }
}
