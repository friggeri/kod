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

    func testZoomModeDefaultsToActualSizeAndCanSwitchToFit() throws {
        let data = try PreviewTestImageFixture.makePNG(width: 4, height: 4)
        let controller = ImagePreviewViewController(decodeResult: ImageDecoder.decode(data))
        controller.loadView()
        XCTAssertEqual(controller.zoomMode, .actualSize)

        controller.fitForTesting()

        XCTAssertEqual(controller.zoomMode, .fit)
    }

    func testSVGRejectedResultShowsDiagnostic() {
        let result = SVGDocumentLoader.load(Data("not svg".utf8))
        let controller = ImagePreviewViewController(svgResult: result)
        controller.loadView()
        XCTAssertNotNil(controller.svgDiagnostic)
    }

    func testValidSVGProducesRenderableImage() {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="120" height="80">
          <rect width="120" height="80" fill="#2563eb"/>
        </svg>
        """
        let result = SVGDocumentLoader.load(Data(svg.utf8))
        let controller = ImagePreviewViewController(svgResult: result)
        controller.loadView()
        XCTAssertNil(controller.svgDiagnostic)
        XCTAssertTrue(controller.hasRenderedImage)
    }

    func testImageIsCenteredInPreviewAreaForActualSizeAndFit() throws {
        let data = try PreviewTestImageFixture.makePNG(width: 40, height: 20)
        let controller = ImagePreviewViewController(decodeResult: ImageDecoder.decode(data))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 800, height: 600))
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        controller.view.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let actualSizeOffset = try XCTUnwrap(controller.imageCenterOffsetFromViewport)
        XCTAssertEqual(actualSizeOffset.x, 0, accuracy: 1)
        XCTAssertEqual(actualSizeOffset.y, 0, accuracy: 1)

        controller.fitForTesting()
        controller.view.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let fitOffset = try XCTUnwrap(controller.imageCenterOffsetFromViewport)
        XCTAssertEqual(fitOffset.x, 0, accuracy: 1)
        XCTAssertEqual(fitOffset.y, 0, accuracy: 1)
    }

    func testImageControlsShareBottomRowWithMetadata() throws {
        let data = try PreviewTestImageFixture.makePNG(width: 4, height: 4)
        let controller = ImagePreviewViewController(decodeResult: ImageDecoder.decode(data))
        controller.loadView()

        XCTAssertTrue(controller.controlsShareMetadataFooter)
    }

    // MARK: - Accessibility (SPEC 14)

    func testZoomLevelHasTextualAccessibilityValueThatUpdatesOnZoom() throws {
        let data = try PreviewTestImageFixture.makePNG(width: 4, height: 4)
        let controller = ImagePreviewViewController(decodeResult: ImageDecoder.decode(data))
        controller.loadView()
        XCTAssertEqual(controller.zoomLevelAccessibilityValue, "Actual Size")

        controller.zoomInForTesting()
        XCTAssertEqual(controller.zoomLevelAccessibilityValue, "125%")

        controller.actualSizeForTesting()
        XCTAssertEqual(controller.zoomLevelAccessibilityValue, "Actual Size")
    }

    func testTransparencyToggleHasTextualLabelAndValueNotColorOnly() throws {
        let data = try PreviewTestImageFixture.makePNG(width: 4, height: 4)
        let controller = ImagePreviewViewController(decodeResult: ImageDecoder.decode(data))
        controller.loadView()
        XCTAssertEqual(controller.transparencyAccessibilityLabel, "Transparency Checkerboard Background")
        XCTAssertEqual(controller.transparencyAccessibilityValue, "On")
        XCTAssertTrue(controller.checkerboardPatternIsVisible)

        controller.toggleTransparencyForTesting()

        XCTAssertEqual(controller.transparencyAccessibilityValue, "Off")
        XCTAssertFalse(controller.checkerboardPatternIsVisible)
    }

    func testCheckerboardColorsAdaptToLightAndDarkAppearances() throws {
        let data = try PreviewTestImageFixture.makePNG(width: 4, height: 4)
        let controller = ImagePreviewViewController(decodeResult: ImageDecoder.decode(data))
        controller.loadView()

        controller.view.appearance = NSAppearance(named: .aqua)
        let lightColors = controller.checkerboardSampleColors

        controller.view.appearance = NSAppearance(named: .darkAqua)
        let darkColors = controller.checkerboardSampleColors

        XCTAssertNotEqual(lightColors.0, lightColors.1)
        XCTAssertNotEqual(darkColors.0, darkColors.1)
        XCTAssertGreaterThan(try luminance(lightColors.0), try luminance(darkColors.0))
        XCTAssertGreaterThan(try luminance(lightColors.1), try luminance(darkColors.1))
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

    private func luminance(_ color: NSColor) throws -> CGFloat {
        let color = try XCTUnwrap(color.usingColorSpace(.sRGB))
        return 0.2126 * color.redComponent
            + 0.7152 * color.greenComponent
            + 0.0722 * color.blueComponent
    }
}
