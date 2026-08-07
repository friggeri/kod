import SourceModel
import XCTest
@testable import SyntaxCore

final class SyntaxEngineTests: XCTestCase {
    func testParsesSwiftAndProducesKeywordCapture() async throws {
        let engine = SyntaxEngine()
        let snapshot = SourceSnapshot(text: "func greet() {\n    let name = \"world\"\n    print(name)\n}\n")
        let tree = try await engine.parse(snapshot: snapshot, language: .swift)
        XCTAssertEqual(tree.snapshotVersion, snapshot.version)

        let captures = tree.captures(inByteRange: 0..<snapshot.utf8Count)
        XCTAssertFalse(captures.isEmpty)
        XCTAssertTrue(captures.contains { $0.name.hasPrefix("keyword") })
        XCTAssertTrue(captures.contains { $0.name.hasPrefix("string") })
        XCTAssertTrue(captures.contains { $0.name.hasPrefix("function") })
    }

    func testAllLaunchLanguagesProduceAtLeastOneCapture() async throws {
        let engine = SyntaxEngine()
        let samples: [SyntaxLanguage: String] = [
            .swift: "func f() -> Int { return 1 }\n",
            .typescript: "function f(x: number): number { return x + 1; }\n",
            .javascript: "function f(x) { return x + 1; }\n",
            .html: "<html><body><p>hi</p></body></html>\n",
            .css: "body { color: red; }\n",
            .python: "def f(x):\n    return x + 1\n",
            .rust: "fn f(x: i32) -> i32 { x + 1 }\n"
        ]

        for language in SyntaxLanguage.allCases {
            guard let source = samples[language] else {
                XCTFail("missing sample for \(language)")
                continue
            }
            let snapshot = SourceSnapshot(text: source)
            let tree = try await engine.parse(snapshot: snapshot, language: language)
            let captures = tree.captures(inByteRange: 0..<snapshot.utf8Count)
            XCTAssertFalse(captures.isEmpty, "\(language) produced no captures")
        }
    }

    func testHighlightPrioritizesViewportThenFull() async throws {
        let engine = SyntaxEngine()
        let source = String(repeating: "let x = 1\n", count: 200)
        let snapshot = SourceSnapshot(text: source)
        let tree = try await engine.parse(snapshot: snapshot, language: .swift)

        let viewportRange = 0..<50
        let (viewport, full) = try await engine.highlight(
            tree: tree,
            viewportByteRange: viewportRange,
            fullByteRange: 0..<snapshot.utf8Count
        )
        XCTAssertFalse(viewport.isEmpty)
        XCTAssertTrue(full.count >= viewport.count)
        XCTAssertTrue(full.allSatisfy { $0.utf8Range.lowerBound >= 0 && $0.utf8Range.upperBound <= snapshot.utf8Count })
    }

    func testFoldRangesSpanMultipleLines() async throws {
        let engine = SyntaxEngine()
        let snapshot = SourceSnapshot(text: "func f() {\n    let x = 1\n    print(x)\n}\n")
        let tree = try await engine.parse(snapshot: snapshot, language: .swift)
        let folds = tree.foldRanges()
        XCTAssertTrue(folds.contains { $0.headerLine == 0 && $0.endLine == 3 })
    }

    func testEnclosingScopesReturnsOutermostFirst() async throws {
        let engine = SyntaxEngine()
        let snapshot = SourceSnapshot(text: "func outer() {\n    func inner() {\n        let x = 1\n    }\n}\n")
        let tree = try await engine.parse(snapshot: snapshot, language: .swift)
        // Byte offset inside "let x = 1"
        guard let offset = snapshot.text.range(of: "let x") else {
            return XCTFail("fixture text changed")
        }
        let utf8Offset = snapshot.text.utf8.distance(from: snapshot.text.utf8.startIndex, to: offset.lowerBound.samePosition(in: snapshot.text.utf8)!)
        let scopes = tree.enclosingScopes(atByteOffset: utf8Offset)
        XCTAssertFalse(scopes.isEmpty)
        XCTAssertEqual(scopes.first?.startLine, 0)
    }
}
