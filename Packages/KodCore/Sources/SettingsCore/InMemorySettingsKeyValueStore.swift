import Foundation

/// Per-instance, lock-protected settings storage for tests and previews. No
/// process-global state or UserDefaults suite is involved.
public final class InMemorySettingsKeyValueStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: SettingsStoredValue]
    private let observations = SettingsObservationRegistry()

    public init(initialValues: [String: SettingsStoredValue] = [:]) {
        self.values = initialValues
    }

    public func snapshot() -> [String: SettingsStoredValue] {
        lock.lock()
        let snapshot = values
        lock.unlock()
        return snapshot
    }
}

extension InMemorySettingsKeyValueStore: SettingsKeyValueStore {
    public func value(
        forKey key: String
    ) throws(SettingsKeyValueStoreError) -> SettingsStoredValue? {
        lock.lock()
        let value = values[key]
        lock.unlock()
        return value
    }

    public func setValue(
        _ value: SettingsStoredValue,
        forKey key: String
    ) throws(SettingsKeyValueStoreError) {
        lock.lock()
        values[key] = value
        lock.unlock()
        observations.notify(SettingsChange(key: key, kind: .written))
    }

    public func removeValue(
        forKey key: String
    ) throws(SettingsKeyValueStoreError) {
        lock.lock()
        values.removeValue(forKey: key)
        lock.unlock()
        observations.notify(SettingsChange(key: key, kind: .removed))
    }

    public func observe(
        key: String,
        _ observer: @escaping @Sendable (SettingsChange) -> Void
    ) -> SettingsObservation {
        observations.observe(key: key, observer)
    }
}
