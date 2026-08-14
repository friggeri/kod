import AppKit
import TextDecorationModel
import XCTest
@testable import KodUIComponents

final class ThemeColorAppKitBridgeTests: XCTestCase {
    func testThemeColorRoundTripsThroughNSColor() throws {
        let color = ThemeColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.8)

        let bridged = try XCTUnwrap(ThemeColorAppKitBridge.themeColor(ThemeColorAppKitBridge.nsColor(color)))

        XCTAssertEqual(bridged.red, color.red, accuracy: 1e-6)
        XCTAssertEqual(bridged.green, color.green, accuracy: 1e-6)
        XCTAssertEqual(bridged.blue, color.blue, accuracy: 1e-6)
        XCTAssertEqual(bridged.alpha, color.alpha, accuracy: 1e-6)
    }

    /// `ThemeColor` components are sRGB, so the produced `NSColor` must
    /// already be sRGB: converting it again must not shift any
    /// component.
    func testNSColorIsProducedInSRGB() throws {
        let nsColor = ThemeColorAppKitBridge.nsColor(
            ThemeColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1)
        )

        let converted = try XCTUnwrap(nsColor.usingColorSpace(.sRGB))

        XCTAssertEqual(Double(converted.redComponent), 0.25, accuracy: 1e-6)
        XCTAssertEqual(Double(converted.greenComponent), 0.5, accuracy: 1e-6)
        XCTAssertEqual(Double(converted.blueComponent), 0.75, accuracy: 1e-6)
    }

    func testColorFromAnotherColorSpaceIsConvertedRatherThanRead() throws {
        let calibrated = NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1)

        let bridged = try XCTUnwrap(ThemeColorAppKitBridge.themeColor(calibrated))

        XCTAssertEqual(bridged.alpha, 1, accuracy: 1e-6)
        XCTAssertGreaterThan(bridged.red, bridged.green)
        XCTAssertGreaterThan(bridged.red, bridged.blue)
    }

    func testAlphaIsPreserved() throws {
        let bridged = try XCTUnwrap(
            ThemeColorAppKitBridge.themeColor(NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 0.25))
        )

        XCTAssertEqual(bridged.alpha, 0.25, accuracy: 1e-6)
    }

    /// The bridge's documented contract: it yields `nil` exactly when
    /// AppKit itself cannot represent the color in sRGB, rather than
    /// reading component values that do not exist (pattern colors).
    func testUnconvertibleColorHasNoPortableRepresentation() {
        let pattern = NSColor(patternImage: NSImage(size: NSSize(width: 2, height: 2)))

        XCTAssertEqual(
            ThemeColorAppKitBridge.themeColor(pattern) == nil,
            pattern.usingColorSpace(.sRGB) == nil
        )
    }
}
