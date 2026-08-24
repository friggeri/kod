import AppKit
import XCTest
@testable import FontCore

final class ResolvedFontTests: XCTestCase {
    func testResolvingKnownMonospacedFamilyProducesNoWarning() {
        let settings = FontSettings(familyName: "Menlo", pointSize: 13)
        let resolved = FontResolver.resolve(settings)
        XCTAssertNil(resolved.alignmentWarning)
        XCTAssertGreaterThan(resolved.characterWidth, 0)
        XCTAssertGreaterThan(resolved.lineHeight, 0)
    }

    func testResolvingNonMonospacedFamilyWarnsButStillProducesAFont() {
        // Helvetica is a real installed macOS family that is not fixed-pitch.
        let settings = FontSettings(familyName: "Helvetica", pointSize: 13)
        let resolved = FontResolver.resolve(settings)
        XCTAssertNotNil(resolved.alignmentWarning)
        XCTAssertGreaterThan(resolved.characterWidth, 0)
    }

    func testLineHeightScalesWithMultiplier() {
        let base = FontResolver.resolve(FontSettings(familyName: "Menlo", pointSize: 13, lineHeightMultiplier: 1.0))
        let taller = FontResolver.resolve(
            FontSettings(familyName: "Menlo", pointSize: 13, lineHeightMultiplier: 2.0)
        )
        XCTAssertGreaterThan(taller.lineHeight, base.lineHeight)
    }

    func testLigatureAttributeValueMatchesSetting() {
        let onSettings = FontSettings(familyName: "Menlo", ligaturesEnabled: true)
        let offSettings = FontSettings(familyName: "Menlo", ligaturesEnabled: false)
        XCTAssertEqual(FontResolver.resolve(onSettings).ligatureAttributeValue, 1)
        XCTAssertEqual(FontResolver.resolve(offSettings).ligatureAttributeValue, 0)
    }

    func testResolverLeavesGlyphFallbackToTheSystem() {
        let resolved = FontResolver.resolve(FontSettings(familyName: "Menlo"))
        XCTAssertNil(resolved.nsFont.fontDescriptor.object(forKey: .cascadeList))
    }

    func testDiscoveryReturnsKnownMonospacedFamilies() {
        let families = MonospacedFontDiscovery.availableMonospacedFamilies()
        XCTAssertTrue(families.contains("Menlo") || families.contains("Monaco"))
        XCTAssertFalse(MonospacedFontDiscovery.isFamilyMonospaced("Helvetica"))
        XCTAssertTrue(MonospacedFontDiscovery.isFamilyMonospaced("Menlo"))
    }
}
