import Foundation
import XCTest
@testable import PreviewCore

final class HTMLPreviewDocumentTests: XCTestCase {
    func testRecognitionAcceptsLeadingCommentsAndRejectsPlainText() {
        XCTAssertTrue(
            HTMLPreviewDocument.looksLikeHTML(
                Data("<!-- fixture --><!doctype html><html></html>".utf8)
            )
        )
        XCTAssertFalse(
            HTMLPreviewDocument.looksLikeHTML(
                Data("Use <html> in this sentence.".utf8)
            )
        )
    }

    func testSecuredHTMLInjectsRestrictiveContentSecurityPolicyIntoHead() throws {
        let source = Data(
            "<!doctype html><html><head><title>Fixture</title></head><body></body></html>".utf8
        )
        let secured = try XCTUnwrap(
            HTMLPreviewDocument.securedHTML(from: source)
        )

        XCTAssertTrue(
            secured.contains(#"http-equiv="Content-Security-Policy""#)
        )
        XCTAssertTrue(secured.contains("script-src 'none'"))
        XCTAssertTrue(secured.contains("connect-src 'none'"))
        XCTAssertTrue(
            secured.range(of: "Content-Security-Policy")!.lowerBound
                < secured.range(of: "<title>")!.lowerBound
        )
    }

    func testSecuredHTMLAddsAHeadWhenDocumentDoesNotHaveOne() throws {
        let secured = try XCTUnwrap(
            HTMLPreviewDocument.securedHTML(
                from: Data("<html><body>Fixture</body></html>".utf8)
            )
        )

        XCTAssertTrue(secured.contains("<meta http-equiv="))
        XCTAssertTrue(secured.contains("<html><body>"))
        XCTAssertTrue(secured.contains("Content-Security-Policy"))
    }

    func testHostileHeadTextCannotCaptureContentSecurityPolicy() throws {
        let source = Data(
            """
            <!doctype html>
            <!-- fake <head> -->
            <html><body><script>const text = "<head>";</script></body></html>
            """.utf8
        )
        let secured = try XCTUnwrap(
            HTMLPreviewDocument.securedHTML(from: source)
        )

        let policy = try XCTUnwrap(
            secured.range(of: "Content-Security-Policy")
        )
        let comment = try XCTUnwrap(secured.range(of: "<!-- fake"))
        let script = try XCTUnwrap(secured.range(of: "<script>"))
        XCTAssertLessThan(policy.lowerBound, comment.lowerBound)
        XCTAssertLessThan(policy.lowerBound, script.lowerBound)
    }
}
