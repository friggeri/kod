import Foundation

public struct CodableSettingsEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    public let version: Int
    public let payload: Payload

    public init(version: Int, payload: Payload) {
        self.version = version
        self.payload = payload
    }
}

public enum SettingsMigrationSource: Sendable, Hashable {
    case unversioned
    case version(Int)
}

public struct SettingsMigrationFailure: Error, Sendable, Equatable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

public struct SettingsMigration<Value: Codable & Sendable>: Sendable {
    public let source: SettingsMigrationSource
    fileprivate let apply: @Sendable (
        SettingsStoredValue
    ) -> Result<Value, SettingsMigrationFailure>

    public static func unversionedCodable<Legacy: Decodable & Sendable>(
        _ legacyType: Legacy.Type,
        migrate: @escaping @Sendable (Legacy) -> Value
    ) -> SettingsMigration<Value> {
        SettingsMigration<Value>(
            source: .unversioned,
            apply: { storedValue in
                guard case .data(let data) = storedValue else {
                    return .failure(
                        SettingsMigrationFailure(
                            reason: "Expected unversioned JSON data, found \(storedValue.kindDescription)."
                        )
                    )
                }
                return Self.decode(legacyType, from: data).map(migrate)
            }
        )
    }

    public static func unversionedStoredValue(
        _ migrate: @escaping @Sendable (
            SettingsStoredValue
        ) -> Result<Value, SettingsMigrationFailure>
    ) -> SettingsMigration<Value> {
        SettingsMigration<Value>(source: .unversioned, apply: migrate)
    }

    public static func versioned<Legacy: Codable & Sendable>(
        from sourceVersion: Int,
        _ legacyType: Legacy.Type,
        migrate: @escaping @Sendable (Legacy) -> Value
    ) -> SettingsMigration<Value> {
        SettingsMigration<Value>(
            source: .version(sourceVersion),
            apply: { storedValue in
                guard case .data(let data) = storedValue else {
                    return .failure(
                        SettingsMigrationFailure(
                            reason: "Expected a versioned JSON envelope, found \(storedValue.kindDescription)."
                        )
                    )
                }
                return Self.decode(
                    CodableSettingsEnvelope<Legacy>.self,
                    from: data
                ).flatMap { envelope in
                    guard envelope.version == sourceVersion else {
                        return .failure(
                            SettingsMigrationFailure(
                                reason: "Migration expected version \(sourceVersion), found \(envelope.version)."
                            )
                        )
                    }
                    return .success(migrate(envelope.payload))
                }
            }
        )
    }

    private static func decode<Decoded: Decodable>(
        _ type: Decoded.Type,
        from data: Data
    ) -> Result<Decoded, SettingsMigrationFailure> {
        Result {
            try JSONDecoder().decode(type, from: data)
        }.mapError {
            SettingsMigrationFailure(
                reason: "Legacy value could not be decoded: \(String(describing: $0))"
            )
        }
    }
}

public struct SettingsValidationFailure: Error, Sendable, Equatable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

/// A domain-owned setting definition. The owning module supplies the key,
/// payload type, migrations, and semantic validator; SettingsCore owns only
/// the persistence mechanics.
public struct CodableSetting<Value: Codable & Sendable>: Sendable {
    public let key: String
    public let currentVersion: Int
    public let migrations: [SettingsMigration<Value>]
    fileprivate let validate: @Sendable (Value) -> SettingsValidationFailure?

    public init(
        key: String,
        currentVersion: Int,
        migrations: [SettingsMigration<Value>] = [],
        validate: @escaping @Sendable (
            Value
        ) -> SettingsValidationFailure? = { _ in nil }
    ) {
        self.key = key
        self.currentVersion = currentVersion
        self.migrations = migrations
        self.validate = validate
    }
}

public enum SettingsLoadProvenance: Sendable, Equatable {
    case current(version: Int)
    case migrated(from: SettingsMigrationSource, toVersion: Int)
}

public enum SettingsLoadOutcome<Value: Sendable>: Sendable {
    case absent
    case value(Value, provenance: SettingsLoadProvenance)
    case quarantined(SettingsQuarantineRecord)
}

extension SettingsLoadOutcome: Equatable where Value: Equatable {}

public enum SettingsRepositoryError: Error, Sendable, Equatable {
    case invalidDefinition(key: String, reason: String)
    case keyValueStore(SettingsKeyValueStoreError)
    case encodingFailed(key: String, reason: String)
    case validationFailed(key: String, reason: String)
    case unsupportedVersion(key: String, stored: Int, current: Int)
    case migrationRequired(
        key: String,
        source: SettingsMigrationSource,
        current: Int
    )
    case quarantine(SettingsQuarantineError)
}

extension SettingsRepositoryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidDefinition(let key, let reason):
            "Invalid setting definition for \(key): \(reason)"
        case .keyValueStore(let error):
            error.localizedDescription
        case .encodingFailed(let key, let reason):
            "Could not encode setting \(key): \(reason)"
        case .validationFailed(let key, let reason):
            "Setting \(key) failed semantic validation: \(reason)"
        case .unsupportedVersion(let key, let stored, let current):
            "Setting \(key) has future version \(stored); this build supports \(current)."
        case .migrationRequired(let key, let source, let current):
            "Setting \(key) requires an explicit migration from \(source) to version \(current)."
        case .quarantine(let error):
            error.localizedDescription
        }
    }
}

public final class CodableSettingsRepository: @unchecked Sendable {
    public let keyValueStore: any SettingsKeyValueStore
    public let quarantine: SettingsQuarantine

    public init(
        store: any SettingsKeyValueStore,
        quarantine: SettingsQuarantine? = nil
    ) {
        self.keyValueStore = store
        self.quarantine = quarantine ?? SettingsQuarantine(store: store)
    }

    public func read<Value: Codable & Sendable>(
        _ setting: CodableSetting<Value>
    ) throws(SettingsRepositoryError) -> SettingsLoadOutcome<Value> {
        try validateDefinition(setting)

        let storedValue: SettingsStoredValue?
        do {
            storedValue = try keyValueStore.value(forKey: setting.key)
        } catch {
            throw .keyValueStore(error)
        }
        guard let storedValue else {
            return .absent
        }

        let source = envelopeVersion(in: storedValue)
        switch source {
        case .version(let storedVersion):
            if storedVersion <= 0 {
                return try quarantineOutcome(
                    storedValue,
                    key: setting.key,
                    reason: "Envelope version must be positive."
                )
            }
            if storedVersion > setting.currentVersion {
                throw .unsupportedVersion(
                    key: setting.key,
                    stored: storedVersion,
                    current: setting.currentVersion
                )
            }
            if storedVersion == setting.currentVersion {
                return try decodeCurrent(
                    setting,
                    storedValue: storedValue
                )
            }
            return try migrate(
                setting,
                storedValue: storedValue,
                source: .version(storedVersion)
            )
        case .unversioned:
            return try migrate(
                setting,
                storedValue: storedValue,
                source: .unversioned
            )
        }
    }

    public func write<Value: Codable & Sendable>(
        _ value: Value,
        to setting: CodableSetting<Value>
    ) throws(SettingsRepositoryError) {
        try validateDefinition(setting)
        if let validationFailure = setting.validate(value) {
            throw .validationFailed(
                key: setting.key,
                reason: validationFailure.reason
            )
        }
        try persist(value, to: setting)
    }

    public func remove<Value: Codable & Sendable>(
        _ setting: CodableSetting<Value>
    ) throws(SettingsRepositoryError) {
        try validateDefinition(setting)
        do {
            try keyValueStore.removeValue(forKey: setting.key)
        } catch {
            throw .keyValueStore(error)
        }
    }

    public func observe<Value: Codable & Sendable>(
        _ setting: CodableSetting<Value>,
        _ observer: @escaping @Sendable (SettingsChange) -> Void
    ) -> SettingsObservation {
        keyValueStore.observe(key: setting.key, observer)
    }

    private func decodeCurrent<Value: Codable & Sendable>(
        _ setting: CodableSetting<Value>,
        storedValue: SettingsStoredValue
    ) throws(SettingsRepositoryError) -> SettingsLoadOutcome<Value> {
        guard case .data(let data) = storedValue else {
            return try quarantineOutcome(
                storedValue,
                key: setting.key,
                reason: "Versioned setting is not stored as data."
            )
        }

        let decoded = Result {
            try JSONDecoder().decode(
                CodableSettingsEnvelope<Value>.self,
                from: data
            )
        }
        switch decoded {
        case .success(let envelope):
            guard envelope.version == setting.currentVersion else {
                return try quarantineOutcome(
                    storedValue,
                    key: setting.key,
                    reason: "Envelope version changed while decoding."
                )
            }
            if let validationFailure = setting.validate(envelope.payload) {
                return try quarantineOutcome(
                    storedValue,
                    key: setting.key,
                    reason: "Semantic validation failed: \(validationFailure.reason)"
                )
            }
            return .value(
                envelope.payload,
                provenance: .current(version: setting.currentVersion)
            )
        case .failure(let error):
            return try quarantineOutcome(
                storedValue,
                key: setting.key,
                reason: "Decoding failed: \(String(describing: error))"
            )
        }
    }

    private func migrate<Value: Codable & Sendable>(
        _ setting: CodableSetting<Value>,
        storedValue: SettingsStoredValue,
        source: SettingsMigrationSource
    ) throws(SettingsRepositoryError) -> SettingsLoadOutcome<Value> {
        guard let migration = setting.migrations.first(where: {
            $0.source == source
        }) else {
            if source == .unversioned {
                return try quarantineOutcome(
                    storedValue,
                    key: setting.key,
                    reason: "Unversioned value has no migration."
                )
            }
            throw .migrationRequired(
                key: setting.key,
                source: source,
                current: setting.currentVersion
            )
        }

        switch migration.apply(storedValue) {
        case .success(let value):
            if let validationFailure = setting.validate(value) {
                return try quarantineOutcome(
                    storedValue,
                    key: setting.key,
                    reason: "Migrated value failed semantic validation: \(validationFailure.reason)"
                )
            }
            try persist(value, to: setting)
            return .value(
                value,
                provenance: .migrated(
                    from: source,
                    toVersion: setting.currentVersion
                )
            )
        case .failure(let failure):
            return try quarantineOutcome(
                storedValue,
                key: setting.key,
                reason: "Migration failed: \(failure.reason)"
            )
        }
    }

    private func persist<Value: Codable & Sendable>(
        _ value: Value,
        to setting: CodableSetting<Value>
    ) throws(SettingsRepositoryError) {
        let envelope = CodableSettingsEnvelope(
            version: setting.currentVersion,
            payload: value
        )
        let encoded = Result { () -> Data in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(envelope)
        }
        let data: Data
        switch encoded {
        case .success(let encodedData):
            data = encodedData
        case .failure(let error):
            throw .encodingFailed(
                key: setting.key,
                reason: String(describing: error)
            )
        }

        do {
            try keyValueStore.setValue(.data(data), forKey: setting.key)
        } catch {
            throw .keyValueStore(error)
        }
    }

    private func quarantineOutcome<Value: Sendable>(
        _ storedValue: SettingsStoredValue,
        key: String,
        reason: String
    ) throws(SettingsRepositoryError) -> SettingsLoadOutcome<Value> {
        do {
            return .quarantined(
                try quarantine.quarantine(
                    storedValue,
                    forKey: key,
                    reason: reason
                )
            )
        } catch {
            throw .quarantine(error)
        }
    }

    private func validateDefinition<Value: Codable & Sendable>(
        _ setting: CodableSetting<Value>
    ) throws(SettingsRepositoryError) {
        guard !setting.key.isEmpty else {
            throw .invalidDefinition(
                key: setting.key,
                reason: "The persistence key is empty."
            )
        }
        guard setting.currentVersion > 0 else {
            throw .invalidDefinition(
                key: setting.key,
                reason: "The current version must be positive."
            )
        }
        let sources = setting.migrations.map(\.source)
        guard Set(sources).count == sources.count else {
            throw .invalidDefinition(
                key: setting.key,
                reason: "More than one migration has the same source."
            )
        }
    }

    private func envelopeVersion(
        in storedValue: SettingsStoredValue
    ) -> SettingsMigrationSource {
        guard case .data(let data) = storedValue else {
            return .unversioned
        }
        struct Header: Decodable {
            let version: Int
        }
        let decoded = Result {
            try JSONDecoder().decode(Header.self, from: data)
        }
        guard case .success(let header) = decoded else {
            return .unversioned
        }
        return .version(header.version)
    }
}

private extension SettingsStoredValue {
    var kindDescription: String {
        switch self {
        case .data:
            "data"
        case .string:
            "string"
        case .boolean:
            "boolean"
        case .integer:
            "integer"
        case .double:
            "double"
        case .stringArray:
            "string array"
        case .unsupported(let typeName):
            "unsupported value of type \(typeName)"
        }
    }
}
