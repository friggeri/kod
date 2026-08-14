import Foundation
import XCTest
@testable import SourceModel

final class SourceSnapshotTests: XCTestCase {
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

}
