import Foundation
import XCTest
@testable import SettingsCore

private struct SampleSetting: Codable, Sendable, Equatable {
    var name: String
    var count: Int
}

private struct LegacySampleSetting: Codable, Sendable {
    var title: String
}

private enum DeliberateCodingFailure: Error {
    case failed
}

private struct FailingEncodableSetting: Codable, Sendable {
    init() {}

    init(from decoder: Decoder) throws {
        throw DeliberateCodingFailure.failed
    }

    func encode(to encoder: Encoder) throws {
        throw DeliberateCodingFailure.failed
    }
}

final class CodableSettingsRepositoryTests: XCTestCase {
    func testWriteUsesVersionEnvelopeAndReadReportsCurrentProvenance() throws {
        let store = InMemorySettingsKeyValueStore()
        let repository = CodableSettingsRepository(store: store)
        let setting = CodableSetting<SampleSetting>(
            key: "sample",
            currentVersion: 3
        )
        let expected = SampleSetting(name: "current", count: 7)

        try repository.write(expected, to: setting)

        guard let storedValue = try store.value(forKey: "sample"),
              case .data(let data) = storedValue else {
            return XCTFail("Expected versioned data")
        }
        let envelope = try JSONDecoder().decode(
            CodableSettingsEnvelope<SampleSetting>.self,
            from: data
        )
        XCTAssertEqual(envelope.version, 3)
        XCTAssertEqual(envelope.payload, expected)
        XCTAssertEqual(
            try repository.read(setting),
            .value(expected, provenance: .current(version: 3))
        )
    }

    func testUnversionedCodableMigrationRewritesCurrentEnvelope() throws {
        let store = InMemorySettingsKeyValueStore()
        let legacy = LegacySampleSetting(title: "legacy")
        try store.setValue(
            .data(try JSONEncoder().encode(legacy)),
            forKey: "sample"
        )
        let repository = CodableSettingsRepository(store: store)
        let setting = CodableSetting<SampleSetting>(
            key: "sample",
            currentVersion: 2,
            migrations: [
                .unversionedCodable(LegacySampleSetting.self) {
                    SampleSetting(name: $0.title, count: 0)
                }
            ]
        )

        XCTAssertEqual(
            try repository.read(setting),
            .value(
                SampleSetting(name: "legacy", count: 0),
                provenance: .migrated(
                    from: .unversioned,
                    toVersion: 2
                )
            )
        )

        guard let storedValue = try store.value(forKey: "sample"),
              case .data(let rewritten) = storedValue else {
            return XCTFail("Expected rewritten envelope")
        }
        XCTAssertEqual(
            try JSONDecoder().decode(
                CodableSettingsEnvelope<SampleSetting>.self,
                from: rewritten
            ).version,
            2
        )
    }

    func testRawLegacyValueMigrationIsExplicit() throws {
        let store = InMemorySettingsKeyValueStore(
            initialValues: ["sample": .string("legacy")]
        )
        let repository = CodableSettingsRepository(store: store)
        let setting = CodableSetting<SampleSetting>(
            key: "sample",
            currentVersion: 1,
            migrations: [
                .unversionedStoredValue { storedValue in
                    guard case .string(let name) = storedValue else {
                        return .failure(
                            SettingsMigrationFailure(
                                reason: "Expected a string."
                            )
                        )
                    }
                    return .success(SampleSetting(name: name, count: 1))
                }
            ]
        )

        guard case .value(let value, let provenance) =
                try repository.read(setting) else {
            return XCTFail("Expected migrated value")
        }
        XCTAssertEqual(value, SampleSetting(name: "legacy", count: 1))
        XCTAssertEqual(
            provenance,
            .migrated(from: .unversioned, toVersion: 1)
        )
    }

    func testVersionedMigrationIsSelectedByExactSourceVersion() throws {
        let store = InMemorySettingsKeyValueStore()
        let oldEnvelope = CodableSettingsEnvelope(
            version: 1,
            payload: LegacySampleSetting(title: "v1")
        )
        try store.setValue(
            .data(try JSONEncoder().encode(oldEnvelope)),
            forKey: "sample"
        )
        let repository = CodableSettingsRepository(store: store)
        let setting = CodableSetting<SampleSetting>(
            key: "sample",
            currentVersion: 2,
            migrations: [
                .versioned(from: 1, LegacySampleSetting.self) {
                    SampleSetting(name: $0.title, count: 2)
                }
            ]
        )

        XCTAssertEqual(
            try repository.read(setting),
            .value(
                SampleSetting(name: "v1", count: 2),
                provenance: .migrated(from: .version(1), toVersion: 2)
            )
        )
    }

    func testMissingVersionedMigrationIsActionableAndPreservesBytes() throws {
        let store = InMemorySettingsKeyValueStore()
        let data = try JSONEncoder().encode(
            CodableSettingsEnvelope(
                version: 1,
                payload: LegacySampleSetting(title: "v1")
            )
        )
        try store.setValue(.data(data), forKey: "sample")
        let repository = CodableSettingsRepository(store: store)
        let setting = CodableSetting<SampleSetting>(
            key: "sample",
            currentVersion: 2
        )

        XCTAssertThrowsError(try repository.read(setting)) { error in
            XCTAssertEqual(
                error as? SettingsRepositoryError,
                .migrationRequired(
                    key: "sample",
                    source: .version(1),
                    current: 2
                )
            )
        }
        XCTAssertEqual(try store.value(forKey: "sample"), .data(data))
    }

    func testFutureVersionIsNotDestroyedByOlderBuild() throws {
        let store = InMemorySettingsKeyValueStore()
        let data = try JSONEncoder().encode(
            CodableSettingsEnvelope(
                version: 9,
                payload: SampleSetting(name: "future", count: 9)
            )
        )
        try store.setValue(.data(data), forKey: "sample")
        let repository = CodableSettingsRepository(store: store)
        let setting = CodableSetting<SampleSetting>(
            key: "sample",
            currentVersion: 2
        )

        XCTAssertThrowsError(try repository.read(setting)) { error in
            XCTAssertEqual(
                error as? SettingsRepositoryError,
                .unsupportedVersion(
                    key: "sample",
                    stored: 9,
                    current: 2
                )
            )
        }
        XCTAssertEqual(try store.value(forKey: "sample"), .data(data))
    }

    func testInvalidAndAmbiguousDefinitionsFailBeforeStorageAccess() {
        let repository = CodableSettingsRepository(
            store: InMemorySettingsKeyValueStore()
        )
        let invalidVersion = CodableSetting<SampleSetting>(
            key: "sample",
            currentVersion: 0
        )
        XCTAssertThrowsError(try repository.read(invalidVersion)) { error in
            guard let repositoryError = error as? SettingsRepositoryError,
                  case .invalidDefinition = repositoryError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let migration = SettingsMigration<SampleSetting>
            .unversionedCodable(LegacySampleSetting.self) {
                SampleSetting(name: $0.title, count: 0)
            }
        let ambiguous = CodableSetting<SampleSetting>(
            key: "sample",
            currentVersion: 1,
            migrations: [migration, migration]
        )
        XCTAssertThrowsError(try repository.read(ambiguous)) { error in
            guard let repositoryError = error as? SettingsRepositoryError,
                  case .invalidDefinition = repositoryError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testWriteValidationFailureDoesNotReplaceExistingValue() throws {
        let store = InMemorySettingsKeyValueStore()
        let repository = CodableSettingsRepository(store: store)
        let setting = validatedSetting()
        let valid = SampleSetting(name: "valid", count: 1)
        try repository.write(valid, to: setting)
        let before = try store.value(forKey: "sample")

        XCTAssertThrowsError(
            try repository.write(
                SampleSetting(name: "", count: 2),
                to: setting
            )
        ) { error in
            XCTAssertEqual(
                error as? SettingsRepositoryError,
                .validationFailed(key: "sample", reason: "Name is empty.")
            )
        }
        XCTAssertEqual(try store.value(forKey: "sample"), before)
    }

    func testReadValidationFailureIsQuarantined() throws {
        let store = InMemorySettingsKeyValueStore()
        let invalidEnvelope = CodableSettingsEnvelope(
            version: 1,
            payload: SampleSetting(name: "", count: 1)
        )
        try store.setValue(
            .data(try JSONEncoder().encode(invalidEnvelope)),
            forKey: "sample"
        )
        let repository = CodableSettingsRepository(store: store)

        guard case .quarantined(let record) =
                try repository.read(validatedSetting()) else {
            return XCTFail("Expected quarantine")
        }
        XCTAssertEqual(record.key, "sample")
        XCTAssertTrue(record.reason.contains("Name is empty"))
        XCTAssertNil(try store.value(forKey: "sample"))
    }

    func testEncodingFailureRemainsTypedAndDoesNotWrite() throws {
        let store = InMemorySettingsKeyValueStore()
        let repository = CodableSettingsRepository(store: store)
        let setting = CodableSetting<FailingEncodableSetting>(
            key: "failing",
            currentVersion: 1
        )

        XCTAssertThrowsError(
            try repository.write(FailingEncodableSetting(), to: setting)
        ) { error in
            guard let repositoryError = error as? SettingsRepositoryError,
                  case .encodingFailed(let key, let reason) =
                    repositoryError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(key, "failing")
            XCTAssertFalse(reason.isEmpty)
        }
        XCTAssertNil(try store.value(forKey: "failing"))
    }

    func testStorageFailureRemainsTypedAndActionable() {
        let failure = SettingsKeyValueStoreError.operationFailed(
            operation: .read,
            key: "sample",
            reason: "permission denied"
        )
        let repository = CodableSettingsRepository(
            store: FailingSettingsKeyValueStore(failure: failure)
        )
        let setting = CodableSetting<SampleSetting>(
            key: "sample",
            currentVersion: 1
        )

        XCTAssertThrowsError(try repository.read(setting)) { error in
            XCTAssertEqual(
                error as? SettingsRepositoryError,
                .keyValueStore(failure)
            )
        }
    }

    func testWriteAndRemovalFailuresRemainTyped() throws {
        for operation in [
            SettingsKeyValueOperation.write,
            SettingsKeyValueOperation.remove
        ] {
            let failure = SettingsKeyValueStoreError.operationFailed(
                operation: operation,
                key: "sample",
                reason: "read-only backend"
            )
            let store = FailingSettingsKeyValueStore(failure: failure)
            let repository = CodableSettingsRepository(store: store)
            let setting = CodableSetting<SampleSetting>(
                key: "sample",
                currentVersion: 1
            )
            let action: () throws -> Void = {
                if operation == .write {
                    try repository.write(
                        SampleSetting(name: "value", count: 1),
                        to: setting
                    )
                } else {
                    try repository.remove(setting)
                }
            }

            XCTAssertThrowsError(try action()) { error in
                XCTAssertEqual(
                    error as? SettingsRepositoryError,
                    .keyValueStore(failure)
                )
            }
        }
    }

    func testQuarantineRemovalFailureIsNotReportedAsSuccess() throws {
        let failure = SettingsKeyValueStoreError.operationFailed(
            operation: .remove,
            key: "sample",
            reason: "locked"
        )
        let store = FailingSettingsKeyValueStore(
            failure: failure,
            initialValues: ["sample": .data(Data("bad".utf8))]
        )
        let repository = CodableSettingsRepository(store: store)
        let setting = CodableSetting<SampleSetting>(
            key: "sample",
            currentVersion: 1,
            migrations: [
                .unversionedCodable(SampleSetting.self) { $0 }
            ]
        )

        XCTAssertThrowsError(try repository.read(setting)) { error in
            XCTAssertEqual(
                error as? SettingsRepositoryError,
                .quarantine(.keyValueStore(failure))
            )
        }
    }

    private func validatedSetting() -> CodableSetting<SampleSetting> {
        CodableSetting(
            key: "sample",
            currentVersion: 1,
            validate: {
                $0.name.isEmpty
                    ? SettingsValidationFailure(reason: "Name is empty.")
                    : nil
            }
        )
    }
}

private final class FailingSettingsKeyValueStore: SettingsKeyValueStore,
    @unchecked Sendable {
    private let failure: SettingsKeyValueStoreError
    private let lock = NSLock()
    private var values: [String: SettingsStoredValue]

    init(
        failure: SettingsKeyValueStoreError,
        initialValues: [String: SettingsStoredValue] = [:]
    ) {
        self.failure = failure
        self.values = initialValues
    }

    func value(
        forKey key: String
    ) throws(SettingsKeyValueStoreError) -> SettingsStoredValue? {
        if shouldFail(.read) {
            throw failure
        }
        lock.lock()
        let value = values[key]
        lock.unlock()
        return value
    }

    func setValue(
        _ value: SettingsStoredValue,
        forKey key: String
    ) throws(SettingsKeyValueStoreError) {
        if shouldFail(.write) {
            throw failure
        }
        lock.lock()
        values[key] = value
        lock.unlock()
    }

    func removeValue(
        forKey key: String
    ) throws(SettingsKeyValueStoreError) {
        if shouldFail(.remove) {
            throw failure
        }
        lock.lock()
        values.removeValue(forKey: key)
        lock.unlock()
    }

    func observe(
        key: String,
        _ observer: @escaping @Sendable (SettingsChange) -> Void
    ) -> SettingsObservation {
        SettingsObservation {}
    }

    private func shouldFail(_ operation: SettingsKeyValueOperation) -> Bool {
        guard case .operationFailed(let failedOperation, _, _) = failure else {
            return false
        }
        return operation == failedOperation
    }
}
