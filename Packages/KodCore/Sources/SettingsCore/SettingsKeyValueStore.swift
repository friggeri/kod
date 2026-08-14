import Foundation

public enum SettingsStoredValue: Sendable, Equatable {
    case data(Data)
    case string(String)
    case boolean(Bool)
    case integer(Int64)
    case double(Double)
    case stringArray([String])
    case unsupported(typeName: String)
}

public enum SettingsKeyValueOperation: String, Sendable, Equatable {
    case read
    case write
    case remove
}

public enum SettingsKeyValueStoreError: Error, Sendable, Equatable {
    case operationFailed(
        operation: SettingsKeyValueOperation,
        key: String,
        reason: String
    )
    case unsupportedStoredValue(key: String, typeName: String)
}

extension SettingsKeyValueStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .operationFailed(let operation, let key, let reason):
            "Settings \(operation.rawValue) failed for \(key): \(reason)"
        case .unsupportedStoredValue(let key, let typeName):
            "Settings value for \(key) has unsupported type \(typeName)."
        }
    }
}

public enum SettingsChangeKind: Sendable, Equatable {
    case written
    case removed
}

public struct SettingsChange: Sendable, Equatable {
    public let key: String
    public let kind: SettingsChangeKind

    public init(key: String, kind: SettingsChangeKind) {
        self.key = key
        self.kind = kind
    }
}

/// Owns one observation registration. Cancellation is idempotent and also
/// occurs when the token is released, so observers cannot outlive their owner
/// merely because a store retained a callback.
public final class SettingsObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (@Sendable () -> Void)?

    public init(cancellation: @escaping @Sendable () -> Void) {
        self.cancellation = cancellation
    }

    public func cancel() {
        lock.lock()
        let cancellation = self.cancellation
        self.cancellation = nil
        lock.unlock()
        cancellation?()
    }

    deinit {
        cancel()
    }

    public static func combine(
        _ observations: [SettingsObservation]
    ) -> SettingsObservation {
        SettingsObservation {
            for observation in observations {
                observation.cancel()
            }
        }
    }
}

/// A synchronous key-value boundary for settings persistence. Every storage
/// operation is throwing even when a concrete backend (such as UserDefaults)
/// does not normally fail, allowing production and injected failure paths to
/// share the same actionable contract.
public protocol SettingsKeyValueStore: AnyObject, Sendable {
    func value(
        forKey key: String
    ) throws(SettingsKeyValueStoreError) -> SettingsStoredValue?

    func setValue(
        _ value: SettingsStoredValue,
        forKey key: String
    ) throws(SettingsKeyValueStoreError)

    func removeValue(
        forKey key: String
    ) throws(SettingsKeyValueStoreError)

    func observe(
        key: String,
        _ observer: @escaping @Sendable (SettingsChange) -> Void
    ) -> SettingsObservation
}

final class SettingsObservationRegistry: @unchecked Sendable {
    private struct Entry {
        let key: String
        let observer: @Sendable (SettingsChange) -> Void
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    func observe(
        key: String,
        _ observer: @escaping @Sendable (SettingsChange) -> Void
    ) -> SettingsObservation {
        let identifier = UUID()
        lock.lock()
        entries[identifier] = Entry(key: key, observer: observer)
        lock.unlock()

        return SettingsObservation { [weak self] in
            self?.remove(identifier)
        }
    }

    func notify(_ change: SettingsChange) {
        lock.lock()
        let observers = entries.values
            .filter { $0.key == change.key }
            .map(\.observer)
        lock.unlock()

        for observer in observers {
            observer(change)
        }
    }

    private func remove(_ identifier: UUID) {
        lock.lock()
        entries.removeValue(forKey: identifier)
        lock.unlock()
    }
}
