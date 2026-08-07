import FuzzSupport
import XCTest
@testable import GitCore

/// Bounded, seeded fuzzing of `GitStatusParser`, `GitDiffParser`, and
/// `GitBlameParser` — the three parsers that turn real `git` process
/// stdout into typed models (SPEC 16.1: "Property and fuzz tests for
/// ... diff parsing"; this suite also directly covers "hostile process
/// output," since a compromised or simply broken `git` binary on a
/// user's `PATH`-adjacent location is exactly the threat model these
/// parsers must survive). Every input is random bytes or random text
/// that merely *resembles* real porcelain output — never a crash, never
/// a hang, and always either a parsed result or a well-typed parser
/// error.
final class GitParserFuzzTests: XCTestCase {
    func testGitStatusParserNeverCrashesOnRandomBytes() throws {
        try FuzzRun.run("GitParserFuzzTests.statusRandomBytes") { source in
            let data = Data(FuzzGenerators.randomBytes(lengthIn: 0...2_048, &source))
            do {
                _ = try GitStatusParser.parse(data)
            } catch is GitStatusParserError {
                // Expected for hostile/malformed input.
            }
        }
    }

    /// Property: bytes that resemble real porcelain v2 `-z` records
    /// (single-letter record markers, NUL-separated fields) but with
    /// random field content and random record counts never crash the
    /// parser — this explores the input space right around the real
    /// format's edges, not just fully unstructured noise.
    func testGitStatusParserNeverCrashesOnPorcelainShapedRandomRecords() throws {
        try FuzzRun.run("GitParserFuzzTests.statusPorcelainShaped", iterations: 300) { source in
            let recordCount = Int.random(in: 0...10, using: &source)
            var bytes: [UInt8] = []
            let markers: [UInt8] = Array("12?!u ".utf8)
            for _ in 0..<recordCount {
                bytes.append(markers[Int.random(in: 0..<markers.count, using: &source)])
                let fieldCount = Int.random(in: 0...5, using: &source)
                for _ in 0..<fieldCount {
                    bytes.append(contentsOf: FuzzGenerators.randomBytes(lengthIn: 0...20, &source))
                    bytes.append(0) // NUL field separator
                }
            }
            do {
                _ = try GitStatusParser.parse(Data(bytes))
            } catch is GitStatusParserError {
                // Expected for most random shapes.
            }
        }
    }

    func testGitDiffParserNeverCrashesOnRandomText() throws {
        try FuzzRun.run("GitParserFuzzTests.diffRandomText") { source in
            let text = FuzzGenerators.randomUnicodeString(scalarCount: Int.random(in: 0...300, using: &source), &source)
            do {
                _ = try GitDiffParser.parseContent(text)
            } catch is GitDiffParserError {
                // Expected for hostile/malformed input.
            }
        }
    }

    /// Property: text shaped like unified-diff hunk headers
    /// (`@@ -a,b +c,d @@`) with random, potentially nonsensical numbers
    /// never crashes the parser, including negative-looking and huge
    /// numbers that a hand-crafted hostile diff might use to try to
    /// trigger an out-of-bounds line computation.
    func testGitDiffParserNeverCrashesOnHunkHeaderShapedRandomNumbers() throws {
        try FuzzRun.run("GitParserFuzzTests.diffHunkShaped", iterations: 300) { source in
            let oldStart = Int.random(in: -1_000_000...1_000_000, using: &source)
            let oldCount = Int.random(in: -1_000...1_000, using: &source)
            let newStart = Int.random(in: -1_000_000...1_000_000, using: &source)
            let newCount = Int.random(in: -1_000...1_000, using: &source)
            let text = "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\n" +
                FuzzGenerators.randomUnicodeString(scalarCount: Int.random(in: 0...50, using: &source), &source)
            do {
                _ = try GitDiffParser.parseContent(text)
            } catch is GitDiffParserError {
                // Expected for most random/nonsensical hunk headers.
            }
        }
    }

    func testGitBlameParserNeverCrashesOnRandomText() throws {
        try FuzzRun.run("GitParserFuzzTests.blameRandomText") { source in
            let text = FuzzGenerators.randomUnicodeString(scalarCount: Int.random(in: 0...300, using: &source), &source)
            do {
                _ = try GitBlameParser.parse(text)
            } catch is GitBlameParserError {
                // Expected for hostile/malformed input.
            }
        }
    }
}
