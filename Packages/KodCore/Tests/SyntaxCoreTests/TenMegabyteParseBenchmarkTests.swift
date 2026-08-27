import Foundation
import SourceModel
import XCTest
@testable import SyntaxCore

/// Headless parse/highlight benchmarks against a synthetic 10 MB source
/// file, per SPEC 12.1 ("Representative 1 MB and 10 MB source files").
/// Each test times a single real pass and asserts a generous absolute
/// ceiling, so a genuine regression or hang fails the suite without
/// paying the cost of `XCTest.measure`'s ten-iteration default against
/// files this large.
final class TenMegabyteParseBenchmarkTests: XCTestCase {
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

    private func tenMegabyteSwiftSource() -> String {
        let unit = "func compute(_ value: Int) -> Int {\n    return value * 2 + 1\n}\n\n"
        let unitByteCount = unit.utf8.count
        let repeats = (10 * 1_024 * 1_024) / unitByteCount
        return String(repeating: unit, count: repeats)
    }

    func testParsingTenMegabyteSwiftSourceCompletesWithinBudget() throws {
        let source = tenMegabyteSwiftSource()
        let snapshot = SourceSnapshot(text: source, url: URL(fileURLWithPath: "/ten-megabytes.swift"))
        XCTAssertNil(snapshot.safetyModeReason, "fixture must exercise the full-fidelity, non-safety-mode path")

        let start = CFAbsoluteTimeGetCurrent()
        _ = try TreeSitterParser.parse(utf8: snapshot.utf8Data, language: .swift)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThan(elapsed, 10.0, "10 MB parse alone took \(elapsed)s")
    }

    func testParsingAndFullFileCaptureOfTenMegabyteSourceStaysUnderBudget() throws {
        let source = tenMegabyteSwiftSource()
        let snapshot = SourceSnapshot(text: source, url: URL(fileURLWithPath: "/ten-megabytes.swift"))

        let start = CFAbsoluteTimeGetCurrent()
        let treeBox = try TreeSitterParser.parse(utf8: snapshot.utf8Data, language: .swift)
        let tree = SyntaxTree(
            treeBox: treeBox,
            utf8: snapshot.utf8Data,
            language: .swift,
            snapshotVersion: snapshot.version
        )
        let captures = tree.captures(inByteRange: 0..<snapshot.utf8Count)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertFalse(captures.isEmpty)
        XCTAssertLessThan(
            elapsed,
            10.0,
            "10 MB parse + full-file capture took \(elapsed)s, which is far outside any reasonable budget"
        )
    }

    func testViewportPrioritizedHighlightReturnsQuicklyEvenForTenMegabyteFile() async throws {
        let source = tenMegabyteSwiftSource()
        let snapshot = SourceSnapshot(text: source, url: URL(fileURLWithPath: "/ten-megabytes.swift"))
        let engine = SyntaxEngine()
        let tree = try await engine.parse(snapshot: snapshot, language: .swift)

        let start = CFAbsoluteTimeGetCurrent()
        let (viewportCaptures, _) = try await engine.highlight(
            tree: tree,
            viewportByteRange: 0..<2_000,
            fullByteRange: 0..<snapshot.utf8Count
        )
        let viewportElapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertFalse(viewportCaptures.isEmpty)
        XCTAssertLessThan(
            viewportElapsed,
            10.0,
            "viewport-prioritized highlight (which also awaits the full-file pass in this test) took \(viewportElapsed)s"
        )
    }
}
