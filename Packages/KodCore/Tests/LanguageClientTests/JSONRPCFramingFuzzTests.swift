import FuzzSupport
import XCTest
@testable import LanguageClient

/// Bounded, seeded fuzzing of `JSONRPCFramingDecoder`, the LSP base
/// protocol framer that turns arbitrarily-fragmented byte chunks from a
/// (potentially hostile or simply broken) language-server process into
/// complete message bodies (SPEC 16.1: "Property and fuzz tests for ...
/// malformed LSP frames"; SPEC 13.2: "JSON-RPC messages ... are schema-
/// and bounds-validated"). Every input here is fully random bytes —
/// never assumed to look anything like a real `Content-Length` header —
/// and the only acceptable outcomes are "some complete messages were
/// extracted" or "a well-typed `ParseError` was thrown"; a crash, hang,
/// or unbounded buffer growth is a failure.
final class JSONRPCFramingFuzzTests: XCTestCase {
    /// Property: feeding entirely random bytes, split into random-sized
    /// fragments (so no chunk boundary is assumed to align with a
    /// message boundary), either yields some (possibly zero) complete
    /// message bodies or throws `JSONRPCFramingDecoder.ParseError` — it
    /// never crashes and never blocks.
    func testRandomByteStreamsNeverCrashAndAlwaysEitherParseOrThrowATypedError() throws {
        try FuzzRun.run("JSONRPCFramingFuzzTests.randomBytes") { source in
            var decoder = JSONRPCFramingDecoder(maxHeaderByteCount: 512, maxMessageByteCount: 4_096)
            let totalByteCount = Int.random(in: 0...2_000, using: &source)
            let allBytes = FuzzGenerators.randomBytes(count: totalByteCount, &source)

            var offset = 0
            while offset < allBytes.count {
                let chunkSize = Int.random(in: 1...max(1, allBytes.count - offset), using: &source)
                let chunk = Data(allBytes[offset..<min(allBytes.count, offset + chunkSize)])
                offset += chunkSize
                do {
                    _ = try decoder.consume(chunk)
                } catch is JSONRPCFramingDecoder.ParseError {
                    // A well-typed rejection is an acceptable, expected
                    // outcome for random bytes — the property under test
                    // is "never crashes," not "never rejects."
                    return
                }
            }
        }
    }

    /// Property: a well-formed header naming an oversized
    /// `Content-Length` is always rejected with `.messageTooLarge`
    /// rather than allocating that much memory — this is the specific
    /// hostile shape SPEC 13.2's "message size ... are bounded" exists
    /// to stop, so it is fuzzed with random (but always over-limit)
    /// declared sizes rather than one fixed example.
    func testOversizedDeclaredContentLengthIsAlwaysRejected() throws {
        try FuzzRun.run("JSONRPCFramingFuzzTests.oversizedContentLength", iterations: 100) { source in
            let limit = 1_024
            var decoder = JSONRPCFramingDecoder(maxHeaderByteCount: 512, maxMessageByteCount: limit)
            let declaredLength = Int.random(in: (limit + 1)...(limit * 1_000), using: &source)
            let header = "Content-Length: \(declaredLength)\r\n\r\n"

            XCTAssertThrowsError(try decoder.consume(Data(header.utf8))) { error in
                guard case JSONRPCFramingDecoder.ParseError.messageTooLarge(let declared, let declaredLimit) = error else {
                    return XCTFail("expected .messageTooLarge, got \(error)")
                }
                XCTAssertEqual(declared, declaredLength)
                XCTAssertEqual(declaredLimit, limit)
            }
        }
    }

    /// Property: a random, well-formed sequence of complete messages
    /// (valid header + exactly the declared number of body bytes,
    /// concatenated back to back with no separator) is always fully
    /// recovered as that many message bodies, regardless of how the
    /// byte stream is chopped into delivery chunks — the actual
    /// correctness property the framer exists to guarantee, exercised
    /// with random body byte content and random chunk boundaries rather
    /// than one fixed example.
    func testWellFormedMessagesAreAlwaysFullyRecoveredRegardlessOfChunking() throws {
        try FuzzRun.run("JSONRPCFramingFuzzTests.wellFormedRecovery", iterations: 200) { source in
            let messageCount = Int.random(in: 0...5, using: &source)
            var expectedBodies: [Data] = []
            var wireBytes = Data()
            for _ in 0..<messageCount {
                let bodyLength = Int.random(in: 0...200, using: &source)
                let body = Data(FuzzGenerators.randomBytes(count: bodyLength, &source))
                expectedBodies.append(body)
                wireBytes.append(Data("Content-Length: \(bodyLength)\r\n\r\n".utf8))
                wireBytes.append(body)
            }

            var decoder = JSONRPCFramingDecoder(maxHeaderByteCount: 4_096, maxMessageByteCount: 1 << 20)
            var recovered: [Data] = []
            var offset = 0
            let byteArray = Array(wireBytes)
            while offset < byteArray.count {
                let chunkSize = Int.random(in: 1...max(1, byteArray.count - offset), using: &source)
                let end = min(byteArray.count, offset + chunkSize)
                recovered.append(contentsOf: try decoder.consume(Data(byteArray[offset..<end])))
                offset = end
            }

            XCTAssertEqual(recovered, expectedBodies)
        }
    }
}
