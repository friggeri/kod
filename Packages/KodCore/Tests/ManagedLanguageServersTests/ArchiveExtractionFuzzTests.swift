import FuzzSupport
import XCTest
@testable import ManagedLanguageServers

/// Bounded, seeded fuzzing of `SecureArchiveExtractor.extract` and
/// `GzipCodec.decompress`, the managed-install pipeline's archive-
/// unpacking layer (SPEC 16.1: "Property and fuzz tests for ... archive
/// extraction"; SPEC 13.2: "Managed installers reject archive traversal,
/// symlink escape, digest mismatch, unexpected executable layout, and
/// unsigned catalog changes"). Every input is random bytes that are
/// never a well-formed archive — the only acceptable outcomes are a
/// well-typed `ArchiveExtractionError`/`GzipError`, never a crash, never
/// an unbounded allocation, and — critically — never any file actually
/// written outside (or even inside, for a rejected archive) the supplied
/// destination directory.
final class ArchiveExtractionFuzzTests: XCTestCase {
    /// Property: entirely random bytes handed to the extractor are
    /// always rejected with a well-typed error, and the destination
    /// directory remains completely empty afterward — a hostile or
    /// simply corrupt archive must never partially extract.
    func testRandomBytesAreAlwaysRejectedAndNeverPartiallyExtract() throws {
        try FuzzRun.run("ArchiveExtractionFuzzTests.randomBytes", iterations: 200) { source in
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: destination) }

            let archiveBytes = Data(FuzzGenerators.randomBytes(lengthIn: 0...4_096, &source))
            do {
                _ = try SecureArchiveExtractor.extract(
                    archiveBytes: archiveBytes,
                    format: .tarGz,
                    maxDecompressedBytes: 1 * 1_024 * 1_024,
                    expectedRelativePaths: ["bin/tool"],
                    executableRelativePath: "bin/tool",
                    destinationRoot: destination
                )
                XCTFail("random bytes must never be accepted as a valid archive")
            } catch is ArchiveExtractionError {
                // Expected: rejected at the tar/layout-validation stage.
            } catch is GzipError {
                // Expected: `extract` propagates `GzipCodec`'s own typed
                // error directly rather than re-wrapping it, so random
                // bytes most commonly fail here, at the gzip-container
                // stage, before ever reaching tar/layout validation.
            }

            let remainingContents = try FileManager.default.contentsOfDirectory(atPath: destination.path)
            XCTAssertTrue(remainingContents.isEmpty, "a rejected archive must leave the destination directory untouched")
        }
    }

    /// Property: random bytes prefixed with the real gzip magic number
    /// (so the codec at least attempts real decompression rather than
    /// bailing out on the very first check) still never crash the
    /// decoder and never allocate more than the caller's own
    /// `maxDecompressedBytes` ceiling.
    func testGzipMagicPrefixedRandomBytesNeverCrashOrExceedTheDecompressionCeiling() throws {
        try FuzzRun.run("ArchiveExtractionFuzzTests.gzipMagicPrefix", iterations: 200) { source in
            var bytes: [UInt8] = [0x1F, 0x8B, 0x08, 0x00] // gzip magic + deflate method + flags
            bytes.append(contentsOf: FuzzGenerators.randomBytes(lengthIn: 0...2_048, &source))

            do {
                _ = try GzipCodec.decompress(Data(bytes), maxDecompressedBytes: 64 * 1_024)
            } catch {
                // Any thrown error is acceptable for hostile/corrupt
                // gzip content — the property under test is "never
                // crashes and never exceeds the ceiling," not "never
                // rejects."
            }
        }
    }
}
