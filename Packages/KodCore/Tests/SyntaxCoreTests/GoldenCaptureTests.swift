import Foundation
import SourceModel
import XCTest
@testable import SyntaxCore

/// Golden-file regression tests, one per launch language, asserting the
/// exact set of highlight captures Kod's pinned grammars + bundled
/// `highlights.scm` queries produce for a representative fixture does not
/// silently drift (a grammar upgrade, query edit, or predicate-evaluator
/// change would change this output).
///
/// To intentionally re-record after a deliberate change, run:
/// `KOD_RECORD_GOLDEN=1 swift test --filter GoldenCaptureTests --package-path Packages/KodCore`
/// and inspect the resulting diff under `Fixtures/Golden` before committing it.
final class GoldenCaptureTests: XCTestCase {
    private static let languages: [(SyntaxLanguage, String)] = [
        (.swift, "swift"),
        (.typescript, "ts"),
        (.javascript, "js"),
        (.html, "html"),
        (.css, "css"),
        (.python, "py"),
        (.rust, "rs")
    ]

    func testGoldenCapturesForEveryLaunchLanguage() async throws {
        let engine = SyntaxEngine()
        let recording = ProcessInfo.processInfo.environment["KOD_RECORD_GOLDEN"] == "1"

        for (language, ext) in Self.languages {
            let sourceURL = try XCTUnwrap(
                Bundle.module.url(
                    forResource: "sample",
                    withExtension: ext,
                    subdirectory: "Fixtures/Golden"
                ),
                "missing fixture sample.\(ext)"
            )
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            let snapshot = SourceSnapshot(text: source, url: sourceURL)
            let tree = try await engine.parse(snapshot: snapshot, language: language)
            let captures = tree.captures(inByteRange: 0..<snapshot.utf8Count)
            let formatted = Self.format(captures)

            if recording {
                let goldenURL = sourceRepositoryFixtureURL(language: language, ext: ext)
                try formatted.write(to: goldenURL, atomically: true, encoding: .utf8)
                continue
            }

            let goldenURL = try XCTUnwrap(
                Bundle.module.url(
                    forResource: "sample",
                    withExtension: "\(ext).golden.txt",
                    subdirectory: "Fixtures/Golden"
                ),
                "missing golden fixture for \(language); run with KOD_RECORD_GOLDEN=1 to create it"
            )
            let golden = try String(contentsOf: goldenURL, encoding: .utf8)
            XCTAssertEqual(
                formatted,
                golden,
                "\(language.displayName) capture output drifted from the golden fixture"
            )
        }
    }

    /// Deterministic, human-reviewable text form: one capture per line,
    /// `name start..<end` sorted by range then name so the file is stable
    /// across capture-emission order.
    private static func format(_ captures: [SyntaxCapture]) -> String {
        captures
            .sorted {
                if $0.utf8Range.lowerBound != $1.utf8Range.lowerBound {
                    return $0.utf8Range.lowerBound < $1.utf8Range.lowerBound
                }
                if $0.utf8Range.upperBound != $1.utf8Range.upperBound {
                    return $0.utf8Range.upperBound < $1.utf8Range.upperBound
                }
                return $0.name < $1.name
            }
            .map { "\($0.name) \($0.utf8Range.lowerBound)..<\($0.utf8Range.upperBound)" }
            .joined(separator: "\n")
            + "\n"
    }

    /// Only used when recording: resolves the *source* fixture path (not
    /// the copied test-bundle resource) so `KOD_RECORD_GOLDEN=1` updates
    /// the file that is actually version-controlled.
    private func sourceRepositoryFixtureURL(language: SyntaxLanguage, ext: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Golden/sample.\(ext).golden.txt")
    }
}
