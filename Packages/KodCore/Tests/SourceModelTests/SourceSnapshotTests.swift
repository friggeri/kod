import Foundation
import XCTest
@testable import SourceModel

private struct InMemoryReadOnlyFileSystem: ReadOnlyFileSystem {
    let data: Data

    func readFile(at url: URL) throws -> ReadOnlyFilePayload {
        ReadOnlyFilePayload(data: data, modificationDate: nil)
    }
}

final class SourceSnapshotTests: XCTestCase {
    func testRawDataLoaderUsesFilesystemDecodingSemantics() throws {
        let loader = SourceSnapshotLoader()
        let url = URL(fileURLWithPath: "/virtual/index.swift")
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("one\r\ntwo\r\n".utf8)

        let snapshot = try loader.load(
            data: data,
            url: url,
            version: 42,
            modificationDate: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(snapshot.url, url)
        XCTAssertEqual(snapshot.version, 42)
        XCTAssertEqual(snapshot.originalData, data)
        XCTAssertEqual(snapshot.encoding, .utf8)
        XCTAssertEqual(snapshot.lineEnding, .carriageReturnLineFeed)
        XCTAssertEqual(snapshot.text, "one\r\ntwo\r\n")
        XCTAssertEqual(snapshot.utf8Data, Data("one\r\ntwo\r\n".utf8))
    }
    func testIndexesMixedLineEndingsWithoutNormalizingContent() throws {
        let snapshot = SourceSnapshot(text: "one\r\ntwo\nthree\rfour")

        XCTAssertEqual(snapshot.lineCount, 4)
        XCTAssertEqual(snapshot.lineEnding, .mixed)
        XCTAssertEqual(snapshot.line(at: 0), "one")
        XCTAssertEqual(snapshot.line(at: 1), "two")
        XCTAssertEqual(snapshot.line(at: 2), "three")
        XCTAssertEqual(snapshot.line(at: 3), "four")
        XCTAssertEqual(snapshot.text, "one\r\ntwo\nthree\rfour")
    }

    func testMapsUTF8AndUTF16PositionsAcrossEmoji() throws {
        let snapshot = SourceSnapshot(text: "a😀b\né")

        let afterEmoji = SourcePosition(line: 0, character: 3)
        XCTAssertEqual(
            try snapshot.utf8Offset(for: afterEmoji, encoding: .utf16),
            5
        )
        XCTAssertEqual(
            try snapshot.position(forUTF8Offset: 5, encoding: .utf16),
            afterEmoji
        )
        XCTAssertEqual(
            try snapshot.position(forUTF8Offset: 5, encoding: .utf8),
            SourcePosition(line: 0, character: 5)
        )
        XCTAssertThrowsError(
            try snapshot.position(forUTF8Offset: 2, encoding: .utf16)
        )
    }

    func testGlobalUTF16OffsetRoundTripsBackToUTF8AcrossEmoji() throws {
        let snapshot = SourceSnapshot(text: "a😀b\né")

        for utf8Offset in [0, 1, 5, 6, 7, snapshot.utf8Count] {
            let utf16Offset = try snapshot.globalUTF16Offset(forUTF8Offset: utf8Offset)
            XCTAssertEqual(
                try snapshot.globalUTF8Offset(forGlobalUTF16Offset: utf16Offset),
                utf8Offset,
                "UTF-16 offset \(utf16Offset) did not round-trip back to UTF-8 offset \(utf8Offset)"
            )
        }
    }

    func testGlobalUTF8OffsetRejectsOutOfRangeUTF16Offset() {
        let snapshot = SourceSnapshot(text: "abc")

        XCTAssertThrowsError(try snapshot.globalUTF8Offset(forGlobalUTF16Offset: -1))
        XCTAssertThrowsError(try snapshot.globalUTF8Offset(forGlobalUTF16Offset: 999))
    }

    func testDecodesUTF16LittleEndianAndMapsOriginalBytes() throws {
        let text = "A😀B"
        var data = Data([0xFF, 0xFE])
        data.append(text.data(using: .utf16LittleEndian)!)
        let loader = SourceSnapshotLoader(
            fileSystem: InMemoryReadOnlyFileSystem(data: data)
        )

        let snapshot = try loader.load(url: URL(fileURLWithPath: "/fixture.swift"))

        XCTAssertEqual(snapshot.encoding, .utf16LittleEndian)
        XCTAssertEqual(snapshot.text, text)
        XCTAssertEqual(try snapshot.originalByteOffset(forUTF8Offset: 5), 8)
    }

    func testRejectsUnsupportedEncodingWithoutFallback() {
        let loader = SourceSnapshotLoader(
            fileSystem: InMemoryReadOnlyFileSystem(data: Data([0xFF, 0xFF, 0xFF]))
        )
        let url = URL(fileURLWithPath: "/invalid.swift")

        XCTAssertThrowsError(try loader.load(url: url)) { error in
            XCTAssertEqual(error as? SourceSnapshotError, .unsupportedEncoding(url))
        }
    }

    func testMarksPathologicalLineForSafetyMode() {
        let snapshot = SourceSnapshot(text: String(repeating: "x", count: 100_001))

        XCTAssertEqual(snapshot.safetyModeReason, .lineLength(100_001))
    }

    func testTenMegabyteSnapshotPerformance() {
        let line = Data("let value = 42\n".utf8)
        var data = Data()
        data.reserveCapacity(10 * 1_024 * 1_024)
        while data.count + line.count <= 10 * 1_024 * 1_024 {
            data.append(line)
        }
        let loader = SourceSnapshotLoader(
            fileSystem: InMemoryReadOnlyFileSystem(data: data)
        )

        measure {
            do {
                let snapshot = try loader.load(
                    url: URL(fileURLWithPath: "/ten-megabytes.swift")
                )
                XCTAssertGreaterThan(snapshot.lineCount, 1)
            } catch {
                XCTFail("Loading failed: \(error)")
            }
        }
    }
}
