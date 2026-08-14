import AppKit
import XCTest
@testable import KodUIComponents

final class AppKitAppearanceBridgeTests: XCTestCase {
    func testAquaIsLight() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))

        XCTAssertTrue(AppKitAppearanceBridge.isLight(appearance))
    }

    func testDarkAquaIsNotLight() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))

        XCTAssertFalse(AppKitAppearanceBridge.isLight(appearance))
    }

    func testHighContrastVariantsResolveToTheirBaseAppearance() throws {
        let lightHighContrast = try XCTUnwrap(NSAppearance(named: .accessibilityHighContrastAqua))
        let darkHighContrast = try XCTUnwrap(NSAppearance(named: .accessibilityHighContrastDarkAqua))

        XCTAssertTrue(AppKitAppearanceBridge.isLight(lightHighContrast))
        XCTAssertFalse(AppKitAppearanceBridge.isLight(darkHighContrast))
    }
}
