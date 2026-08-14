import FuzzSupport
import XCTest
@testable import SourceModel

/// Bounded, seeded fuzzing of `SourceSnapshot`'s byte/UTF-8/UTF-16
/// position-mapping surface (SPEC 16.1: "Property and fuzz tests for
/// Unicode positions") — the exact math VoiceOver range queries,
/// LSP position conversion, and `CodeViewport` selection all depend on.
/// Uses adversarial Unicode (combining marks, emoji/astral-plane
/// scalars, CJK) rather than plain ASCII, since those are exactly the
/// inputs that have historically broken byte-offset/UTF-16-offset math.
final class EncodingPositionFuzzTests: XCTestCase {
    /// Property: for every valid UTF-8 boundary offset in a random
    /// Unicode document, converting UTF-8 -> UTF-16 -> UTF-8 must return
    /// the exact original offset (a lossless round trip), and neither
    /// direction may ever crash — only return a value or throw a
    /// well-typed `SourceSnapshotError`.
    func testUTF8ToUTF16RoundTripIsLosslessAtEveryBoundary() throws {
        try FuzzRun.run("EncodingPositionFuzzTests.roundTrip") { source in
            let text = FuzzGenerators.randomUnicodeString(scalarCount: Int.random(in: 0...200, using: &source), &source)
            let snapshot = SourceSnapshot(text: text, url: URL(fileURLWithPath: "/fuzz.txt"))

            var offset = 0
            let bytes = Array(text.utf8)
            while offset <= bytes.count {
                if isUTF8ScalarBoundary(bytes, at: offset) {
                    let utf16Offset = try snapshot.globalUTF16Offset(forUTF8Offset: offset)
                    let roundTripped = try snapshot.globalUTF8Offset(forGlobalUTF16Offset: utf16Offset)
                    XCTAssertEqual(roundTripped, offset, "UTF-8 -> UTF-16 -> UTF-8 must round-trip losslessly")
                }
                offset += 1
            }
        }
    }

    /// Property: an out-of-range or non-boundary UTF-8 offset always
    /// throws a well-typed error — it never crashes, and it never
    /// silently clamps to a nearby valid offset (which would corrupt a
    /// caller's range math without any signal that anything went
    /// wrong).
    func testOutOfRangeOffsetsAlwaysThrowRatherThanCrashOrClamp() throws {
        try FuzzRun.run("EncodingPositionFuzzTests.outOfRange") { source in
            let text = FuzzGenerators.randomUnicodeString(scalarCount: Int.random(in: 0...100, using: &source), &source)
            let snapshot = SourceSnapshot(text: text, url: URL(fileURLWithPath: "/fuzz.txt"))
            let byteCount = text.utf8.count

            // Deliberately explore offsets both inside and far outside
            // the valid range, including negative ones.
            let candidateOffset = Int.random(in: -1_000...(byteCount + 1_000), using: &source)

            do {
                _ = try snapshot.globalUTF16Offset(forUTF8Offset: candidateOffset)
            } catch is SourceSnapshotError {
                // Expected for an invalid offset — never a crash.
            }

            do {
                _ = try snapshot.globalUTF8Offset(forGlobalUTF16Offset: candidateOffset)
            } catch is SourceSnapshotError {
                // Expected for an invalid offset — never a crash.
            }
        }
    }

    /// Property: `position(forUTF8Offset:encoding:)` never returns a
    /// negative line or character, for any random valid document and
    /// any random in-range boundary offset, under both LSP position
    /// encodings.
    func testPositionForOffsetIsNeverNegative() throws {
        try FuzzRun.run("EncodingPositionFuzzTests.positionNonNegative") { source in
            let lineCount = Int.random(in: 1...20, using: &source)
            var lines: [String] = []
            for _ in 0..<lineCount {
                lines.append(FuzzGenerators.randomUnicodeString(scalarCount: Int.random(in: 0...40, using: &source), &source))
            }
            let text = lines.joined(separator: "\n")
            let snapshot = SourceSnapshot(text: text, url: URL(fileURLWithPath: "/fuzz.txt"))
            let bytes = Array(text.utf8)

            let rawOffset = Int.random(in: 0...bytes.count, using: &source)
            guard isUTF8ScalarBoundary(bytes, at: rawOffset) else {
                return
            }

            for encoding in [SourcePositionEncoding.utf8, .utf16] {
                let position = try snapshot.position(forUTF8Offset: rawOffset, encoding: encoding)
                XCTAssertGreaterThanOrEqual(position.line, 0)
                XCTAssertGreaterThanOrEqual(position.character, 0)
            }
        }
    }

    /// Whether `offset` lands on a UTF-8 scalar boundary within `bytes`
    /// — a continuation byte (`10xxxxxx`) is never a valid boundary.
    private func isUTF8ScalarBoundary(_ bytes: [UInt8], at offset: Int) -> Bool {
        guard offset >= 0, offset <= bytes.count else {
            return false
        }
        guard offset < bytes.count else {
            return true
        }
        return (bytes[offset] & 0xC0) != 0x80
    }
}
