import CoreFoundation
import Foundation

/// Production adapter for an explicitly supplied UserDefaults domain. It does
/// not consult `UserDefaults.standard` implicitly and does not use global
/// notifications. Observations are scoped to successful writes made through
/// this adapter instance.
public final class UserDefaultsSettingsKeyValueStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let observations = SettingsObservationRegistry()

    public init(userDefaults: UserDefaults) {
        self.defaults = userDefaults
    }
}

extension UserDefaultsSettingsKeyValueStore: SettingsKeyValueStore {
    public func value(
        forKey key: String
    ) throws(SettingsKeyValueStoreError) -> SettingsStoredValue? {
        guard let value = defaults.object(forKey: key) else {
            return nil
        }

        if let data = value as? Data {
            return .data(data)
        }
        if let string = value as? String {
            return .string(string)
        }
        if let strings = value as? [String] {
            return .stringArray(strings)
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .boolean(number.boolValue)
            }
            let objectiveCType = String(cString: number.objCType)
            if objectiveCType == "f" || objectiveCType == "d" {
                return .double(number.doubleValue)
            }
            return .integer(number.int64Value)
        }

        return .unsupported(
            typeName: String(reflecting: type(of: value))
        )
    }

    public func setValue(
        _ value: SettingsStoredValue,
        forKey key: String
    ) throws(SettingsKeyValueStoreError) {
        switch value {
        case .data(let data):
            defaults.set(data, forKey: key)
        case .string(let string):
            defaults.set(string, forKey: key)
        case .boolean(let boolean):
            defaults.set(boolean, forKey: key)
        case .integer(let integer):
            defaults.set(integer, forKey: key)
        case .double(let double):
            defaults.set(double, forKey: key)
        case .stringArray(let strings):
            defaults.set(strings, forKey: key)
        case .unsupported(let typeName):
            throw .unsupportedStoredValue(key: key, typeName: typeName)
        }
        observations.notify(SettingsChange(key: key, kind: .written))
    }

    public func removeValue(
        forKey key: String
    ) throws(SettingsKeyValueStoreError) {
        defaults.removeObject(forKey: key)
        observations.notify(SettingsChange(key: key, kind: .removed))
    }

    public func observe(
        key: String,
        _ observer: @escaping @Sendable (SettingsChange) -> Void
    ) -> SettingsObservation {
        observations.observe(key: key, observer)
    }
}
