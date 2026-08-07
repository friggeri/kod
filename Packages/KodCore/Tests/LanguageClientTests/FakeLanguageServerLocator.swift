import Foundation
import XCTest
@testable import LanguageClient

/// Locates the `FakeLanguageServer` executable SwiftPM builds as a
/// sibling product of this test target. Tries the SwiftPM-documented
/// "auxiliary executable next to the test bundle" location first, then
/// falls back to a directory search rooted at this source file's known
/// location within the package — robust to whichever build directory
/// `swift test`/Xcode used, without hardcoding one.
enum FakeLanguageServerLocator {
    enum LocatorError: Error {
        case notFound
    }

    static func executableURL() throws -> URL {
        if let fromBundle = Bundle(for: LocatorSentinel.self)
            .bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("FakeLanguageServer") as URL?,
            FileManager.default.isExecutableFile(atPath: fromBundle.path) {
            return fromBundle
        }

        // Fallback: search upward from this source file for a
        // `.build/*/*/FakeLanguageServer` product (covers debug/release
        // and both bundled architectures without hardcoding one).
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let buildRoot = directory.appendingPathComponent(".build")
            if let found = Self.search(buildRoot) {
                return found
            }
            directory.deleteLastPathComponent()
        }
        throw LocatorError.notFound
    }

    private static func search(_ root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for case let url as URL in enumerator where url.lastPathComponent == "FakeLanguageServer" {
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}

private final class LocatorSentinel {}

/// A tiny thread-safe box for capturing a single value written from a
/// `@Sendable` closure (e.g. `LanguageServerConnection`'s notification/
/// state-change handlers) and read back from the test's `await` context.
final class LockedBox<T>: @unchecked Sendable {
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

