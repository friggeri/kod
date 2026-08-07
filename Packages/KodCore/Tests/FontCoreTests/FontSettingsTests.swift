import XCTest
@testable import FontCore

final class FontSettingsTests: XCTestCase {
    func testDefaultsAreWithinValidRanges() {
        let settings = FontSettings.default
        XCTAssertTrue(FontSettings.sizeRange.contains(settings.pointSize))
        XCTAssertTrue(FontSettings.lineHeightRange.contains(settings.lineHeightMultiplier))
        XCTAssertFalse(settings.familyName.isEmpty)
    }

    func testConstructorClampsOutOfRangeValues() {
        let settings = FontSettings(
            pointSize: 999,
            lineHeightMultiplier: -5,
            letterSpacing: 999
        )
        XCTAssertEqual(settings.pointSize, FontSettings.sizeRange.upperBound)
        XCTAssertEqual(settings.lineHeightMultiplier, FontSettings.lineHeightRange.lowerBound)
        XCTAssertEqual(settings.letterSpacing, FontSettings.letterSpacingRange.upperBound)
    }

    func testConstructorDropsEmptyFallbackFamilyNames() {
        let settings = FontSettings(fallbackFamilies: ["Menlo", "", "Monaco"])
        XCTAssertEqual(settings.fallbackFamilies, ["Menlo", "Monaco"])
    }

    func testCodableRoundTrip() throws {
        let settings = FontSettings(
            familyName: "Menlo",
            pointSize: 15,
            weight: .semibold,
            ligaturesEnabled: true,
            lineHeightMultiplier: 1.4,
            letterSpacing: 0.5,
            fallbackFamilies: ["Monaco"]
        )
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(FontSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    /// SPEC 14: "300% text zoom" must actually be reachable without
    /// clamping — i.e. `sizeRange` must comfortably contain 3x the
    /// default starting size (13pt \u{2192} 39pt), not sit at its edge.
    func testSizeRangeReaches300PercentOfDefaultWithMargin() {
        let defaultPointSize = FontSettings.default.pointSize
        let tripleSize = defaultPointSize * 3
        XCTAssertTrue(
            FontSettings.sizeRange.contains(tripleSize),
            "sizeRange \(FontSettings.sizeRange) must contain 300% of the default size (\(tripleSize)pt)"
        )
        XCTAssertGreaterThan(
            FontSettings.sizeRange.upperBound,
            tripleSize,
            "there should be headroom above exactly 300%, not a hard clamp at it"
        )
        let clamped = FontSettings(pointSize: tripleSize)
        XCTAssertEqual(clamped.pointSize, tripleSize, "300% of default must round-trip unclamped through the constructor")
    }
}

final class FontSettingsStoreTests: XCTestCase {
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "kod.font-settings-tests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }

    @MainActor
    func testLoadReturnsDefaultWhenNothingSaved() {
        let store = FontSettingsStore(defaults: makeIsolatedDefaults())
        XCTAssertEqual(store.load(), FontSettings.default)
    }

    @MainActor
    func testSaveThenLoadRoundTrips() {
        let defaults = makeIsolatedDefaults()
        let store = FontSettingsStore(defaults: defaults)
        let settings = FontSettings(familyName: "Menlo", pointSize: 16)
        store.save(settings)

        let reloaded = FontSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.load(), settings)
    }

    @MainActor
    func testResetRestoresDefault() {
        let defaults = makeIsolatedDefaults()
        let store = FontSettingsStore(defaults: defaults)
        store.save(FontSettings(familyName: "Menlo", pointSize: 20))
        store.reset()
        XCTAssertEqual(store.load(), FontSettings.default)
    }

    @MainActor
    func testCorruptStoredSettingsAreQuarantinedAndRebuiltAsDefault() {
        let defaults = makeIsolatedDefaults()
        defaults.set(Data("not valid json {{{".utf8), forKey: "kod.font-settings")
        let store = FontSettingsStore(defaults: defaults)

        let loaded = store.load()

        XCTAssertEqual(loaded, FontSettings.default, "corrupt settings must fail safe to defaults")
        XCTAssertEqual(store.quarantine.ledger().count, 1)
        XCTAssertEqual(store.quarantine.ledger()[0].key, "kod.font-settings")

        // The corrupt bytes must be gone so a fresh save/load cycle works.
        store.save(FontSettings(familyName: "Menlo", pointSize: 18))
        XCTAssertEqual(store.load().familyName, "Menlo")
    }
}
