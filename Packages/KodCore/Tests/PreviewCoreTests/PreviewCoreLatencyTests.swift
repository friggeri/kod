import Foundation
import ThemeCore
import XCTest
@testable import PreviewCore

/// Latency budgets at Kod's own documented preview size limits (SPEC
/// 12/10.3). These are functional pass/fail gates (a generous ceiling far
/// above the actual measured cost), not micro-benchmarks — the intent is
/// to catch an accidental quadratic-or-worse regression (like the one
/// caught and fixed during this phase's own development, where a
/// pathological emphasis run went from milliseconds to over ten seconds)
/// before it reaches users, not to track fine-grained performance.
final class PreviewCoreLatencyTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment[
            "KOD_RUN_LARGE_FILE_BENCHMARKS"
        ] == "1" else {
            throw XCTSkip(
                "Set KOD_RUN_LARGE_FILE_BENCHMARKS=1 to run 10 MB benchmarks."
            )
        }
    }

    func testMarkdownAtMaximumDocumentedSizeParsesAndRendersWithinBudget() async throws {
        let limits = MarkdownLimits.default
        // Build a realistic-shaped (not pathological) document right at
        // the documented 10 MB source limit: repeated paragraphs,
        // headings, lists, and fenced code, so this exercises the whole
        // parser/renderer pipeline rather than one degenerate construct.
        var source = ""
        let unit = """
        ## Section

        Some **bold** and *italic* text with a [link](https://example.com) and `code`.

        - one
        - two
        - three

        ```swift
        let value = 1 + 2
        ```

        """
        while source.utf8.count < limits.maximumSourceByteCount - unit.utf8.count {
            source += unit
        }

        let clock = ContinuousClock()
        let start = clock.now
        let document = MarkdownParser.parse(source, limits: limits)
        _ = await MarkdownRenderer.render(document, theme: BundledThemes.dark)
        let elapsed = clock.now - start

        XCTAssertLessThan(elapsed, .seconds(20), "parsing+rendering a full 10 MB realistic Markdown document took \(elapsed), above the latency budget")
    }

    func testJSONAtMaximumDocumentedNodeCountParsesWithinBudget() {
        let limits = StructuredDataLimits.default
        let entryCount = 100_000
        let json = "{" + (0..<entryCount).map { "\"key\($0)\": [\($0), \($0 + 1), \($0 + 2)]" }.joined(separator: ",") + "}"

        let clock = ContinuousClock()
        let start = clock.now
        let result = JSONParser.parse(Data(json.utf8), limits: limits)
        let elapsed = clock.now - start

        XCTAssertNotNil(result.node)
        XCTAssertLessThan(elapsed, .seconds(10), "parsing a \(entryCount)-key JSON document took \(elapsed), above the latency budget")
    }

    func testImageAtMaximumDocumentedDimensionDecodesWithinBudget() throws {
        // A real, moderately large bitmap (not the full 20,000px ceiling,
        // which would make this test itself slow/expensive to generate) —
        // chosen to exercise the real ImageIO decode path within a
        // reasonable test budget while still being clearly non-trivial.
        let data = try ImageFixture.makePNG(width: 2_000, height: 2_000)

        let clock = ContinuousClock()
        let start = clock.now
        let result = ImageDecoder.decode(data)
        let elapsed = clock.now - start

        guard case .decoded = result else {
            return XCTFail("expected a 2000x2000 PNG within default limits to decode")
        }
        XCTAssertLessThan(elapsed, .seconds(5), "decoding a 2000x2000 PNG took \(elapsed), above the latency budget")
    }

    func testStructuredSearchOverMaximumDocumentedNodeCountStaysWithinBudget() {
        let entryCount = 100_000
        let json = "{" + (0..<entryCount).map { "\"key\($0)\": \($0)" }.joined(separator: ",") + "}"
        guard case .valid(let root) = JSONParser.parse(Data(json.utf8)) else {
            return XCTFail("expected valid parse")
        }

        let clock = ContinuousClock()
        let start = clock.now
        _ = StructuredSearch.search(root, query: "key99999")
        let elapsed = clock.now - start

        XCTAssertLessThan(elapsed, .seconds(5), "searching a \(entryCount)-key document took \(elapsed), above the latency budget")
    }
}
