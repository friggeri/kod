import Foundation
import SourceModel
import XCTest
@testable import SourceIO

private struct InMemoryReadOnlyFileSystem: ReadOnlyFileSystem {
    let result: Result<ReadOnlyFilePayload, SourceIOError>

    init(data: Data, modificationDate: Date? = nil) {
        result = .success(
            ReadOnlyFilePayload(data: data, modificationDate: modificationDate)
        )
    }

    init(error: SourceIOError) {
        result = .failure(error)
    }

    func readFile(at url: URL) throws -> ReadOnlyFilePayload {
        try result.get()
    }
}

final class SourceSnapshotLoaderTests: XCTestCase {
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

    func testRejectsUnsupportedEncodingWithTypedError() {
        let loader = SourceSnapshotLoader(
            fileSystem: InMemoryReadOnlyFileSystem(data: Data([0xFF, 0xFF, 0xFF]))
        )
        let url = URL(fileURLWithPath: "/invalid.swift")

        XCTAssertThrowsError(try loader.load(url: url)) { error in
            XCTAssertEqual(error as? SourceIOError, .unsupportedEncoding(url))
        }
    }

    func testPropagatesExplicitReadFailureWithoutWriting() {
        let url = URL(fileURLWithPath: "/missing.swift")
        let loader = SourceSnapshotLoader(
            fileSystem: InMemoryReadOnlyFileSystem(error: .permissionDenied(url))
        )

        XCTAssertThrowsError(try loader.load(url: url)) { error in
            XCTAssertEqual(error as? SourceIOError, .permissionDenied(url))
        }
    }

    func testDefaultSafetyPolicyPreservesPathologicalLineReasonAndMessage() throws {
        let data = Data(String(repeating: "x", count: 100_001).utf8)
        let snapshot = try SourceSnapshotLoader(
            renderingSafetyPolicy: .codeViewportDefault
        ).load(
            data: data,
            url: URL(fileURLWithPath: "/long-line.swift")
        )

        let reason = try XCTUnwrap(snapshot.safetyModeReason)
        XCTAssertEqual(reason, .lineLength(100_001))
        XCTAssertEqual(
            SourceRenderingSafetyPolicy.codeViewportDefault.message(for: reason),
            "Safety mode: this file contains a line longer than 100001 UTF-8 bytes."
        )
    }

    func testSafetyPolicyCanBeDisabledForNonRendererLoading() throws {
        let data = Data(String(repeating: "x", count: 100_001).utf8)
        let snapshot = try SourceSnapshotLoader(
            renderingSafetyPolicy: nil
        ).load(
            data: data,
            url: URL(fileURLWithPath: "/long-line.swift")
        )

        XCTAssertNil(snapshot.safetyModeReason)
    }

    func testDefaultSafetyPolicyPreservesTenMegabyteBoundary() {
        let policy = SourceRenderingSafetyPolicy.codeViewportDefault
        let limit = 10 * 1_024 * 1_024

        XCTAssertNil(policy.reason(fileByteCount: limit, longestLineUTF8Length: 1))
        XCTAssertEqual(
            policy.reason(fileByteCount: limit + 1, longestLineUTF8Length: 1),
            .fileSize(limit + 1)
        )
    }

    func testTenMegabyteSnapshotPerformance() {
        let line = Data("let value = 42\n".utf8)
        var data = Data()
        data.reserveCapacity(10 * 1_024 * 1_024)
        while data.count + line.count <= 10 * 1_024 * 1_024 {
            data.append(line)
        }
        let loader = SourceSnapshotLoader(
            fileSystem: InMemoryReadOnlyFileSystem(data: data),
            renderingSafetyPolicy: .codeViewportDefault
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
