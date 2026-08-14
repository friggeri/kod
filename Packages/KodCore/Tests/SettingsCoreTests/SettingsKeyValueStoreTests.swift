import Foundation
import XCTest
@testable import SettingsCore

private struct AdapterSample: Codable, Sendable {
    let value: String
}

final class SettingsKeyValueStoreTests: XCTestCase {
    func testInMemoryStoresAreIsolated() throws {
        let first = InMemorySettingsKeyValueStore()
        let second = InMemorySettingsKeyValueStore()

        try first.setValue(.string("first"), forKey: "name")

        XCTAssertEqual(try first.value(forKey: "name"), .string("first"))
        XCTAssertNil(try second.value(forKey: "name"))
    }

    func testInMemoryStoreSupportsEveryValueKindAndRemoval() throws {
        let store = InMemorySettingsKeyValueStore()
        let values: [String: SettingsStoredValue] = [
            "data": .data(Data([1, 2, 3])),
            "string": .string("value"),
            "boolean": .boolean(true),
            "integer": .integer(42),
            "double": .double(1.5),
            "array": .stringArray(["a", "b"])
        ]

        for (key, value) in values {
            try store.setValue(value, forKey: key)
            XCTAssertEqual(try store.value(forKey: key), value)
            try store.removeValue(forKey: key)
            XCTAssertNil(try store.value(forKey: key))
        }
    }

    func testUserDefaultsAdapterUsesOnlyExplicitSuiteAndPreservesLegacyKinds() throws {
        let suiteName = "SettingsCoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let adapter = UserDefaultsSettingsKeyValueStore(userDefaults: defaults)

        try adapter.setValue(.boolean(true), forKey: "enabled")
        try adapter.setValue(.string("theme"), forKey: "name")
        try adapter.setValue(.stringArray(["one", "two"]), forKey: "items")

        XCTAssertEqual(try adapter.value(forKey: "enabled"), .boolean(true))
        XCTAssertEqual(try adapter.value(forKey: "name"), .string("theme"))
        XCTAssertEqual(
            try adapter.value(forKey: "items"),
            .stringArray(["one", "two"])
        )
    }

    func testUnsupportedUserDefaultsTypeCanBeQuarantined() throws {
        let suiteName = "SettingsCoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(["nested": "value"], forKey: "unsupported")
        let adapter = UserDefaultsSettingsKeyValueStore(userDefaults: defaults)
        guard let storedValue = try adapter.value(forKey: "unsupported"),
              case .unsupported(let typeName) = storedValue else {
            return XCTFail("Expected unsupported value metadata")
        }
        XCTAssertFalse(typeName.isEmpty)
        let repository = CodableSettingsRepository(store: adapter)
        let setting = CodableSetting<AdapterSample>(
            key: "unsupported",
            currentVersion: 1,
            migrations: [
                .unversionedCodable(AdapterSample.self) { $0 }
            ]
        )

        guard case .quarantined(let record) = try repository.read(setting) else {
            return XCTFail("Expected unsupported value quarantine")
        }
        XCTAssertEqual(record.key, "unsupported")
        XCTAssertNil(defaults.object(forKey: "unsupported"))
    }

    func testObservationTokenCancelsExplicitly() throws {
        let store = InMemorySettingsKeyValueStore()
        let recorder = ChangeRecorder()
        let observation = store.observe(key: "watched") {
            recorder.append($0)
        }

        try store.setValue(.string("one"), forKey: "watched")
        observation.cancel()
        try store.setValue(.string("two"), forKey: "watched")

        XCTAssertEqual(
            recorder.snapshot(),
            [SettingsChange(key: "watched", kind: .written)]
        )
    }

    func testObservationIsCancelledWhenOwnerReleasesToken() throws {
        let store = InMemorySettingsKeyValueStore()
        let recorder = ChangeRecorder()
        var observation: SettingsObservation? = store.observe(key: "watched") {
            recorder.append($0)
        }
        try store.removeValue(forKey: "watched")
        observation = nil
        XCTAssertNil(observation)
        try store.removeValue(forKey: "watched")

        XCTAssertEqual(recorder.snapshot().count, 1)
    }

    func testObservationIsKeyScoped() throws {
        let store = InMemorySettingsKeyValueStore()
        let recorder = ChangeRecorder()
        let observation = store.observe(key: "watched") {
            recorder.append($0)
        }

        try store.setValue(.string("ignored"), forKey: "other")
        try store.setValue(.string("seen"), forKey: "watched")

        XCTAssertEqual(recorder.snapshot().map(\.key), ["watched"])
        withExtendedLifetime(observation) {}
    }
}

private final class ChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [SettingsChange] = []

    func append(_ change: SettingsChange) {
        lock.lock()
        changes.append(change)
        lock.unlock()
    }

    func snapshot() -> [SettingsChange] {
        lock.lock()
        let snapshot = changes
        lock.unlock()
        return snapshot
    }
}
