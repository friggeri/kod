import XCTest
@testable import ManagedLanguageServers

final class GzipCodecTests: XCTestCase {
    func testRoundTripSmall() throws {
        let original = Data("hello world hello world hello world".utf8)
        let compressed = try GzipCodec.compress(original)
        XCTAssertEqual(compressed[0], 0x1F)
        XCTAssertEqual(compressed[1], 0x8B)
        let decompressed = try GzipCodec.decompress(compressed, maxDecompressedBytes: 1024)
        XCTAssertEqual(decompressed, original)
    }

    func testRoundTripEmpty() throws {
        let original = Data()
        let compressed = try GzipCodec.compress(original)
        let decompressed = try GzipCodec.decompress(compressed, maxDecompressedBytes: 1024)
        XCTAssertEqual(decompressed, original)
    }

    func testRoundTripLarge() throws {
        var original = Data()
        for i in 0..<200_000 {
            original.append(UInt8(i % 251))
        }
        let compressed = try GzipCodec.compress(original)
        let decompressed = try GzipCodec.decompress(compressed, maxDecompressedBytes: original.count + 10)
        XCTAssertEqual(decompressed, original)
    }

    func testBombProtection() throws {
        var original = Data()
        for _ in 0..<500_000 {
            original.append(0)
        }
        let compressed = try GzipCodec.compress(original)
        XCTAssertLessThan(compressed.count, 5000)
        XCTAssertThrowsError(try GzipCodec.decompress(compressed, maxDecompressedBytes: 1000)) { error in
            guard case GzipError.decompressedSizeExceeded = error else {
                XCTFail("expected decompressedSizeExceeded, got \(error)")
                return
            }
        }
    }

    func testTamperedCRCRejected() throws {
        let original = Data("tamper test".utf8)
        var compressed = try GzipCodec.compress(original)
        compressed[compressed.count - 5] ^= 0xFF
        XCTAssertThrowsError(try GzipCodec.decompress(compressed, maxDecompressedBytes: 1024))
    }
}
