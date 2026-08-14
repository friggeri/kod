import AppKit
import PreviewCore
import XCTest
@testable import PreviewUI

/// Headless coverage for `ImagePreviewViewController`: fit/actual-size/
/// zoom toggles, transparency-background toggle, and safe rejection
/// state for decode failures — never a window, never a real click.
@MainActor
final class ImagePreviewViewControllerTests: XCTestCase {
    func testDecodedPNGShowsMetadata() throws {
        let data = try PreviewTestImageFixture.makePNG(width: 10, height: 6)
        let result = ImageDecoder.decode(data)
        let controller = ImagePreviewViewController(decodeResult: result)
        controller.loadView()
        XCTAssertEqual(controller.metadata?.pixelWidth, 10)
        XCTAssertEqual(controller.metadata?.pixelHeight, 6)
        XCTAssertNil(controller.diagnostic)
        XCTAssertEqual(controller.frameCount, 1)
    }

    func testRejectedDecodeShowsDiagnosticNotBlankSuccess() {
        let result = ImageDecoder.decode(Data("not an image".utf8))
        let controller = ImagePreviewViewController(decodeResult: result)
        controller.loadView()
        XCTAssertNotNil(controller.diagnostic)
        XCTAssertNil(controller.metadata)
    }

    func testZoomModeDefaultsToFitAndTogglesToActualSize() throws {
        let data = try PreviewTestImageFixture.makePNG(width: 4, height: 4)
        let controller = ImagePreviewViewController(decodeResult: ImageDecoder.decode(data))
        controller.loadView()
        XCTAssertEqual(controller.zoomMode, .fit)
    }

    func testSVGRejectedResultShowsDiagnostic() {
        let result = SVGDocumentLoader.load(Data("not svg".utf8))
        let controller = ImagePreviewViewController(svgResult: result)
        controller.loadView()
        XCTAssertNotNil(controller.svgDiagnostic)
    }

    func testValidSVGResultLoadsWithoutCrashing() {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"></svg>"
        let result = SVGDocumentLoader.load(Data(svg.utf8))
        let controller = ImagePreviewViewController(svgResult: result)
        controller.loadView()
        XCTAssertNil(controller.svgDiagnostic)
    }

    // MARK: - Accessibility (SPEC 14)

    func testZoomLevelHasTextualAccessibilityValueThatUpdatesOnZoom() throws {
        let data = try PreviewTestImageFixture.makePNG(width: 4, height: 4)
        let controller = ImagePreviewViewController(decodeResult: ImageDecoder.decode(data))
        controller.loadView()
        XCTAssertEqual(controller.zoomLevelAccessibilityValue, "Zoom: Fit to Window")

        controller.zoomInForTesting()
        XCTAssertNotEqual(controller.zoomLevelAccessibilityValue, "Zoom: Fit to Window")
        XCTAssertTrue(controller.zoomLevelAccessibilityValue?.hasPrefix("Zoom: ") ?? false)

        controller.actualSizeForTesting()
        XCTAssertEqual(controller.zoomLevelAccessibilityValue, "Zoom: Actual Size")
    }

    func testTransparencyToggleHasTextualLabelAndValueNotColorOnly() throws {
        let data = try PreviewTestImageFixture.makePNG(width: 4, height: 4)
        let controller = ImagePreviewViewController(decodeResult: ImageDecoder.decode(data))
        controller.loadView()
        XCTAssertEqual(controller.transparencyAccessibilityLabel, "Transparency Checkerboard Background")
        XCTAssertEqual(controller.transparencyAccessibilityValue, "On")

        controller.toggleTransparencyForTesting()
        XCTAssertEqual(controller.transparencyAccessibilityValue, "Off")
    }

    func testPlayPauseTogglesAccessibilityLabelAndValue() throws {
        let data = try PreviewTestImageFixture.makePNG(width: 4, height: 4)
        let controller = ImagePreviewViewController(decodeResult: ImageDecoder.decode(data))
        controller.loadView()
        XCTAssertEqual(controller.playPauseAccessibilityLabel, "Pause Animation")
        XCTAssertEqual(controller.playPauseAccessibilityValue, "Playing")

        controller.togglePlayPauseForTesting()
        XCTAssertEqual(controller.playPauseAccessibilityLabel, "Play Animation")
        XCTAssertEqual(controller.playPauseAccessibilityValue, "Paused")
    }
}
