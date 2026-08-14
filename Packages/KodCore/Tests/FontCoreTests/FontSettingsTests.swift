import XCTest
import SettingsCore
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
    @MainActor
    private func makeStore() -> (
        FontSettingsStore,
        CodableSettingsRepository,
        InMemorySettingsKeyValueStore
    ) {
        let keyValueStore = InMemorySettingsKeyValueStore()
        let repository = CodableSettingsRepository(store: keyValueStore)
        return (
            FontSettingsStore(repository: repository),
            repository,
            keyValueStore
        )
    }

    @MainActor
    func testLoadReportsAbsentWhenNothingSaved() throws {
        let (store, _, _) = makeStore()
        XCTAssertEqual(try store.load(), .absent)
    }

    @MainActor
    func testSaveThenLoadRoundTrips() throws {
        let (store, _, _) = makeStore()
        let settings = FontSettings(familyName: "Menlo", pointSize: 16)
        try store.save(settings)

        guard case .value(let reloaded, _) = try store.load() else {
            return XCTFail("Expected persisted settings")
        }
        XCTAssertEqual(reloaded, settings)
    }

    @MainActor
    func testLegacyUnenvelopedSettingsMigrate() throws {
        let (store, _, keyValueStore) = makeStore()
        let settings = FontSettings(
            familyName: "Menlo",
            pointSize: 15
        )
        try keyValueStore.setValue(
            .data(try JSONEncoder().encode(settings)),
            forKey: "kod.font-settings"
        )

        XCTAssertEqual(
            try store.load(),
            .value(
                settings,
                provenance: .migrated(
                    from: .unversioned,
                    toVersion: 1
                )
            )
        )
    }

    @MainActor
    func testResetRestoresAbsence() throws {
        let (store, _, _) = makeStore()
        try store.save(FontSettings(familyName: "Menlo", pointSize: 20))
        try store.reset()
        XCTAssertEqual(try store.load(), .absent)
    }

    @MainActor
    func testCorruptStoredSettingsAreQuarantinedAndCanRebuild() throws {
        let (store, repository, keyValueStore) = makeStore()
        try keyValueStore.setValue(
            .data(Data("not valid json {{{".utf8)),
            forKey: "kod.font-settings"
        )

        guard case .quarantined(let record) = try store.load() else {
            return XCTFail("Expected quarantine")
        }
        XCTAssertEqual(record.key, "kod.font-settings")
        XCTAssertEqual(try repository.quarantine.records(), [record])

        try store.save(FontSettings(familyName: "Menlo", pointSize: 18))
        guard case .value(let rebuilt, _) = try store.load() else {
            return XCTFail("Expected rebuilt settings")
        }
        XCTAssertEqual(rebuilt.familyName, "Menlo")
    }

    @MainActor
    func testSemanticallyInvalidLegacySettingsAreQuarantined() throws {
        struct InvalidLegacyFontSettings: Encodable {
            let familyName = ""
            let pointSize = 16.0
            let weight = FontWeight.regular
            let ligaturesEnabled = false
            let lineHeightMultiplier = 1.2
            let letterSpacing = 0.0
            let fallbackFamilies: [String] = []
        }

        let (store, _, keyValueStore) = makeStore()
        try keyValueStore.setValue(
            .data(try JSONEncoder().encode(InvalidLegacyFontSettings())),
            forKey: "kod.font-settings"
        )

        guard case .quarantined(let record) = try store.load() else {
            return XCTFail("Expected semantic quarantine")
        }
        XCTAssertTrue(record.reason.contains("primary font family"))
    }
}
