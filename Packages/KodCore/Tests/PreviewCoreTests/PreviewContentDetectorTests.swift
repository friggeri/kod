import Foundation
import XCTest
@testable import PreviewCore

final class PreviewContentDetectorTests: XCTestCase {
    func testDetectsPNGByMagicBytesRegardlessOfExtension() throws {
        let data = try ImageFixture.makePNG(width: 4, height: 4)
        XCTAssertEqual(PreviewContentDetector.detect(pathExtension: "txt", contentPrefix: data), .image(.png))
    }

    func testDoesNotTrustPNGExtensionWithoutValidMagicBytes() {
        let notActuallyAnImage = Data("just some plain text content".utf8)
        XCTAssertNotEqual(PreviewContentDetector.detect(pathExtension: "png", contentPrefix: notActuallyAnImage), .image(.png))
    }

    func testDetectsMarkdownByExtension() {
        let content = Data("# Title".utf8)
        XCTAssertEqual(PreviewContentDetector.detect(pathExtension: "md", contentPrefix: content), .markdown)
        XCTAssertEqual(PreviewContentDetector.detect(pathExtension: "markdown", contentPrefix: content), .markdown)
    }

    func testDetectsJSONByExtension() {
        let content = Data(#"{"a": 1}"#.utf8)
        XCTAssertEqual(PreviewContentDetector.detect(pathExtension: "json", contentPrefix: content), .structuredData)
    }

    func testDetectsPlistByExtension() {
        let content = Data("<plist version=\"1.0\"><dict/></plist>".utf8)
        XCTAssertEqual(PreviewContentDetector.detect(pathExtension: "plist", contentPrefix: content), .structuredData)
    }

    func testDetectsBinaryPlistByContentEvenWithWrongExtension() {
        var bytes = Array("bplist00".utf8)
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 40))
        XCTAssertEqual(PreviewContentDetector.detect(pathExtension: "dat", contentPrefix: Data(bytes)), .structuredData)
    }

    func testUnrecognizedExtensionAndContentFallsBackToNone() {
        let content = Data("just a regular source file\nwith normal code\n".utf8)
        XCTAssertEqual(PreviewContentDetector.detect(pathExtension: "swift", contentPrefix: content), .none)
    }

    func testImageDetectionAlwaysWinsOverExtensionMismatch() throws {
        // A file with a `.json` extension that is actually a PNG (e.g.
        // renamed by accident) must still be routed to the image
        // preview, since content — not extension — drives dispatch.
        let data = try ImageFixture.makePNG(width: 2, height: 2)
        XCTAssertEqual(PreviewContentDetector.detect(pathExtension: "json", contentPrefix: data), .image(.png))
    }

    func testSVGDetectedByRootElementNotExtension() {
        let content = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8)
        XCTAssertEqual(PreviewContentDetector.detect(pathExtension: "txt", contentPrefix: content), .image(.svg))
    }
}
