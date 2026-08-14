import SettingsCore

final class RemoveFailingSettingsStore:
    @unchecked Sendable,
    SettingsKeyValueStore {
    private let base = InMemorySettingsKeyValueStore()

    func value(
        forKey key: String
    ) throws(SettingsKeyValueStoreError) -> SettingsStoredValue? {
        try base.value(forKey: key)
    }

    func setValue(
        _ value: SettingsStoredValue,
        forKey key: String
    ) throws(SettingsKeyValueStoreError) {
        try base.setValue(value, forKey: key)
    }

    func removeValue(
        forKey key: String
    ) throws(SettingsKeyValueStoreError) {
        throw .operationFailed(
            operation: .remove,
            key: key,
            reason: "injected failure"
        )
    }

    func observe(
        key: String,
        _ observer: @escaping @Sendable (SettingsChange) -> Void
    ) -> SettingsObservation {
        base.observe(key: key, observer)
    }
}
