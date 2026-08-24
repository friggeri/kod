import AppKit
import CoreGraphics
import FontCore
import ImageIO
import PreviewCore
import ThemeCore
import XCTest
@testable import PreviewUI

/// Headless coverage for `PreviewViewController`'s content-kind dispatch
/// (SPEC 10) — never a window, never simulated mouse/keyboard input.
@MainActor
final class PreviewViewControllerTests: XCTestCase {
    func testMakeReturnsMarkdownControllerForMarkdownKind() async throws {
        let controller = await PreviewViewController.make(
            kind: .markdown,
            data: Data("# Title\n\nBody text.".utf8),
            theme: BundledThemes.dark,
            fontSettings: .default,
            isWorkspaceTrusted: { false }
        )
        let unwrapped = try XCTUnwrap(controller)
        XCTAssertNotNil(unwrapped.markdownController)
        XCTAssertNil(unwrapped.structuredDataController)
        XCTAssertNil(unwrapped.imageController)
    }

    func testMakeReturnsStructuredDataControllerForJSONKind() async throws {
        let controller = await PreviewViewController.make(
            kind: .structuredData,
            data: Data(#"{"a": 1}"#.utf8),
            theme: BundledThemes.dark,
            fontSettings: .default,
            isWorkspaceTrusted: { false }
        )
        let unwrapped = try XCTUnwrap(controller)
        XCTAssertNotNil(unwrapped.structuredDataController)
    }

    func testMakeReturnsSandboxedHTMLControllerForHTMLKind() async throws {
        let controller = await PreviewViewController.make(
            kind: .html,
            data: Data(
                "<!doctype html><html><body>Fixture</body></html>".utf8
            ),
            theme: BundledThemes.dark,
            fontSettings: .default,
            isWorkspaceTrusted: { false },
            documentRelativePath: "Fixtures/index.html"
        )
        let unwrapped = try XCTUnwrap(controller)
        let htmlController = try XCTUnwrap(unwrapped.htmlController)

        XCTAssertFalse(
            htmlController.webView.configuration
                .defaultWebpagePreferences.allowsContentJavaScript
        )
        XCTAssertFalse(
            htmlController.webView.configuration.websiteDataStore.isPersistent
        )
    }

    func testMakeReturnsImageControllerForPNGKind() async throws {
        let data = try PreviewTestImageFixture.makePNG(width: 4, height: 4)
        let controller = await PreviewViewController.make(
            kind: .image(.png),
            data: data,
            theme: BundledThemes.dark,
            fontSettings: .default,
            isWorkspaceTrusted: { false }
        )
        let unwrapped = try XCTUnwrap(controller)
        XCTAssertNotNil(unwrapped.imageController)
        XCTAssertEqual(unwrapped.imageController?.metadata?.pixelWidth, 4)
    }

    func testMakeReturnsImageControllerForSVGKind() async throws {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"></svg>"
        let controller = await PreviewViewController.make(
            kind: .image(.svg),
            data: Data(svg.utf8),
            theme: BundledThemes.dark,
            fontSettings: .default,
            isWorkspaceTrusted: { false }
        )
        let unwrapped = try XCTUnwrap(controller)
        XCTAssertNotNil(unwrapped.imageController)
    }

    func testMakeReturnsNilForNoneKind() async {
        let controller = await PreviewViewController.make(
            kind: .none,
            data: Data("plain text".utf8),
            theme: BundledThemes.dark,
            fontSettings: .default,
            isWorkspaceTrusted: { false }
        )
        XCTAssertNil(controller)
    }

    func testViewLoadsWithoutCrashingForEachKind() async throws {
        let pngData = try PreviewTestImageFixture.makePNG(width: 2, height: 2)
        let cases: [(PreviewKind, Data)] = [
            (.markdown, Data("# Hi".utf8)),
            (
                .html,
                Data("<!doctype html><html><body>Hi</body></html>".utf8)
            ),
            (.structuredData, Data(#"{"a":1}"#.utf8)),
            (.image(.png), pngData)
        ]
        for (kind, data) in cases {
            let controller = await PreviewViewController.make(
                kind: kind,
                data: data,
                theme: BundledThemes.dark,
                fontSettings: .default,
                isWorkspaceTrusted: { false }
            )
            let unwrapped = try XCTUnwrap(controller)
            unwrapped.loadView()
            XCTAssertFalse(unwrapped.view.subviews.isEmpty)
        }
    }
}

/// A tiny, self-contained PNG-fixture generator for headless
/// `PreviewUITests` feature-controller tests, independent of
/// `PreviewCoreTests`' own fixture helper (a different test target).
enum PreviewTestImageFixture {
    enum FixtureError: Error {
        case creationFailed
    }

    static func makePNG(width: Int, height: Int) throws -> Data {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw FixtureError.creationFailed
        }
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw FixtureError.creationFailed
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw FixtureError.creationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError.creationFailed
        }
        return data as Data
    }
}
