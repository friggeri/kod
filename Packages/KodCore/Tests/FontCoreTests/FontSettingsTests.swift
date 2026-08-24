import XCTest
import SettingsCore
@testable import FontCore

private struct LegacyFontSettingsV1: Codable {
    var familyName = "Menlo"
    var pointSize = 13.0
    var weight = FontWeight.regular
    var ligaturesEnabled = false
    var lineHeightMultiplier = 1.2
    var letterSpacing = 0.0
    var fallbackFamilies = ["Monaco"]
}

final class FontSettingsTests: XCTestCase {
    func testDefaultsAreWithinValidRanges() {
        let settings = FontSettings.default
        XCTAssertTrue(FontSettings.sizeRange.contains(settings.pointSize))
        XCTAssertTrue(FontSettings.lineHeightRange.contains(settings.lineHeightMultiplier))
        XCTAssertFalse(settings.familyName.isEmpty)
        XCTAssertTrue(settings.ligaturesEnabled)
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

    func testCodableRoundTrip() throws {
        let settings = FontSettings(
            familyName: "Menlo",
            pointSize: 15,
            weight: .semibold,
            ligaturesEnabled: true,
            lineHeightMultiplier: 1.4,
            letterSpacing: 0.5
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
        let legacy = LegacyFontSettingsV1(
            pointSize: 15,
            ligaturesEnabled: true,
            fallbackFamilies: ["Monaco", "Apple Color Emoji"]
        )
        try keyValueStore.setValue(
            .data(try JSONEncoder().encode(legacy)),
            forKey: "kod.font-settings"
        )

        let expected = FontSettings(
            familyName: legacy.familyName,
            pointSize: legacy.pointSize,
            weight: legacy.weight,
            ligaturesEnabled: legacy.ligaturesEnabled,
            lineHeightMultiplier: legacy.lineHeightMultiplier,
            letterSpacing: legacy.letterSpacing
        )
        XCTAssertEqual(
            try store.load(),
            .value(
                expected,
                provenance: .migrated(
                    from: .unversioned,
                    toVersion: 2
                )
            )
        )
    }

    @MainActor
    func testVersionOneSettingsDropFallbacksAndPreserveLigatureChoice() throws {
        let (store, _, keyValueStore) = makeStore()
        let legacy = LegacyFontSettingsV1(
            familyName: "Menlo",
            pointSize: 15,
            weight: .semibold,
            ligaturesEnabled: false,
            lineHeightMultiplier: 1.4,
            letterSpacing: 0.5,
            fallbackFamilies: ["", "Monaco"]
        )
        let envelope = CodableSettingsEnvelope(version: 1, payload: legacy)
        try keyValueStore.setValue(
            .data(try JSONEncoder().encode(envelope)),
            forKey: "kod.font-settings"
        )

        let expected = FontSettings(
            familyName: legacy.familyName,
            pointSize: legacy.pointSize,
            weight: legacy.weight,
            ligaturesEnabled: legacy.ligaturesEnabled,
            lineHeightMultiplier: legacy.lineHeightMultiplier,
            letterSpacing: legacy.letterSpacing
        )
        XCTAssertEqual(
            try store.load(),
            .value(
                expected,
                provenance: .migrated(from: .version(1), toVersion: 2)
            )
        )

        guard let storedValue = try keyValueStore.value(forKey: "kod.font-settings"),
              case .data(let data) = storedValue else {
            return XCTFail("Expected rewritten v2 settings")
        }
        let rewritten = try JSONDecoder().decode(
            CodableSettingsEnvelope<FontSettings>.self,
            from: data
        )
        XCTAssertEqual(rewritten.version, 2)
        XCTAssertEqual(rewritten.payload, expected)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("fallbackFamilies"))
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
        let (store, _, keyValueStore) = makeStore()
        let invalid = LegacyFontSettingsV1(
            familyName: "",
            pointSize: 16,
            fallbackFamilies: []
        )
        try keyValueStore.setValue(
            .data(try JSONEncoder().encode(invalid)),
            forKey: "kod.font-settings"
        )

        guard case .quarantined(let record) = try store.load() else {
            return XCTFail("Expected semantic quarantine")
        }
        XCTAssertTrue(record.reason.contains("primary font family"))
    }
}
