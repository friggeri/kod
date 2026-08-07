import Foundation

/// A tiny thread-safe box for capturing a value written from a
/// `@Sendable` progress/completion closure and read back from an
/// `async` test body — mirrors `LanguageClientTests.LockedBox`, given
/// its own name here since it's a different (internal) test target.
final class LockedBoxValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ initial: T) {
        self.value = initial
    }

    func set(_ newValue: T) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
