import Foundation
import SourceModel
import XCTest
@testable import LanguageClient

/// Pure conversion coverage for wire → UTF-8 normalization, exercised
/// directly rather than through a live server.
final class LSPRangeNormalizerTests: XCTestCase {
    private func range(
        _ startLine: Int,
        _ startCharacter: Int,
        _ endLine: Int,
        _ endCharacter: Int
    ) -> LSPRange {
        LSPRange(
            start: LSPPosition(line: startLine, character: startCharacter),
            end: LSPPosition(line: endLine, character: endCharacter)
        )
    }

    /// The same wire range means different bytes depending on the
    /// negotiated encoding: `é` is one UTF-16 code unit but two UTF-8
    /// bytes. Converting with the wrong encoding lands on the wrong text.
    func testConversionUsesTheNegotiatedEncoding() throws {
        let snapshot = SourceSnapshot(text: "éabc\n", version: 1)
        let wire = range(0, 0, 0, 3)

        let utf16 = try XCTUnwrap(
            LSPRangeNormalizer.utf8Range(wire, in: snapshot, encoding: .utf16)
        )
        XCTAssertEqual(utf16, 0..<4)
        XCTAssertEqual(try snapshot.text(inUTF8Range: utf16), "éab")

        let utf8 = try XCTUnwrap(
            LSPRangeNormalizer.utf8Range(wire, in: snapshot, encoding: .utf8)
        )
        XCTAssertEqual(utf8, 0..<3)
        XCTAssertEqual(try snapshot.text(inUTF8Range: utf8), "éa")
    }

    func testRangesOutsideTheSnapshotAreDiscarded() {
        let snapshot = SourceSnapshot(text: "let x = 1\n", version: 1)
        XCTAssertNil(
            LSPRangeNormalizer.utf8Range(range(9, 0, 9, 1), in: snapshot, encoding: .utf16)
        )
        XCTAssertNil(
            LSPRangeNormalizer.utf8Range(range(0, 0, 0, 999), in: snapshot, encoding: .utf16)
        )
    }

    func testInvertedRangesAreDiscarded() {
        let snapshot = SourceSnapshot(text: "let x = 1\nlet y = 2\n", version: 1)
        XCTAssertNil(
            LSPRangeNormalizer.utf8Range(range(1, 2, 0, 1), in: snapshot, encoding: .utf16)
        )
    }

    func testStructuralValidationRejectsNegativeAndInvertedRanges() {
        XCTAssertTrue(LSPRangeNormalizer.isStructurallyValid(range(0, 0, 0, 0)))
        XCTAssertTrue(LSPRangeNormalizer.isStructurallyValid(range(2, 4, 9, 0)))
        XCTAssertFalse(LSPRangeNormalizer.isStructurallyValid(range(-1, 0, 0, 1)))
        XCTAssertFalse(LSPRangeNormalizer.isStructurallyValid(range(0, -1, 0, 1)))
        XCTAssertFalse(LSPRangeNormalizer.isStructurallyValid(range(0, 5, 0, 4)))
        XCTAssertFalse(LSPRangeNormalizer.isStructurallyValid(range(3, 0, 2, 0)))
    }

    func testDiagnosticsOutsideTheSnapshotAreDroppedNotClamped() {
        let snapshot = SourceSnapshot(text: "éabc\n", version: 9)
        let diagnostics = [
            Diagnostic(
                range: range(0, 0, 0, 3),
                severity: .warning,
                code: nil,
                source: "fake",
                message: "inside"
            ),
            Diagnostic(
                range: range(42, 0, 42, 1),
                severity: .error,
                code: nil,
                source: "fake",
                message: "outside"
            )
        ]

        let normalized = LSPRangeNormalizer.normalizedDiagnostics(
            diagnostics,
            snapshot: snapshot,
            encoding: .utf16
        )
        XCTAssertEqual(normalized.count, 1)
        XCTAssertEqual(normalized.first?.message, "inside")
        XCTAssertEqual(normalized.first?.utf8Range, 0..<4)
        XCTAssertEqual(normalized.first?.startLine, 0)
        XCTAssertEqual(
            normalized.first?.snapshotVersion,
            9,
            "Normalized diagnostics record the snapshot they were validated against"
        )
    }

    func testFoldingRangesAreValidatedAgainstTheSnapshotLineCount() {
        let snapshot = SourceSnapshot(text: "a\nb\nc\n", version: 1)
        XCTAssertNotNil(
            LSPRangeNormalizer.validatedFoldingRange(
                FoldingRange(startLine: 0, startCharacter: nil, endLine: 2, endCharacter: nil, kind: "region"),
                snapshot: snapshot
            )
        )
        XCTAssertNil(
            LSPRangeNormalizer.validatedFoldingRange(
                FoldingRange(startLine: 0, startCharacter: nil, endLine: 99, endCharacter: nil, kind: nil),
                snapshot: snapshot
            ),
            "A fold past the end of the document is discarded"
        )
        XCTAssertNil(
            LSPRangeNormalizer.validatedFoldingRange(
                FoldingRange(startLine: 2, startCharacter: nil, endLine: 1, endCharacter: nil, kind: nil),
                snapshot: snapshot
            )
        )
        XCTAssertNil(
            LSPRangeNormalizer.validatedFoldingRange(
                FoldingRange(startLine: -1, startCharacter: nil, endLine: 1, endCharacter: nil, kind: nil),
                snapshot: snapshot
            )
        )
    }

    func testSemanticTokenDecodingSkipsOutOfBoundsTokensAndUnknownTypes() throws {
        let snapshot = SourceSnapshot(text: "class Greeter {}\n", version: 1)
        let legend = ServerCapabilities.SemanticTokensOptions.Legend(
            tokenTypes: ["keyword"],
            tokenModifiers: ["declaration"]
        )
        // [line 0, char 0, len 5, type 0, no modifiers],
        // [line +0, char +6, len 7, type 9 (out of legend), modifier bit 0],
        // [line +40 (past the end), char 0, len 1, type 0, none]
        let tokens = SemanticTokens(
            resultId: nil,
            data: [0, 0, 5, 0, 0, 0, 6, 7, 9, 1, 40, 0, 1, 0, 0]
        )
        let decoded = LSPRangeNormalizer.semanticTokens(
            from: tokens,
            legend: legend,
            snapshot: snapshot,
            encoding: .utf16
        )

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].utf8Range, 0..<5)
        XCTAssertEqual(decoded[0].tokenType, "keyword")
        XCTAssertEqual(decoded[1].utf8Range, 6..<13)
        XCTAssertEqual(
            decoded[1].tokenType,
            "unknown",
            "An out-of-legend token type is reported rather than dropped"
        )
        XCTAssertEqual(decoded[1].tokenModifiers, ["declaration"])
    }
}
