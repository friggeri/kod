import Foundation

/// Locates the `GitProcessSpy` executable SwiftPM builds as a sibling
/// product of this test target — the same technique used by the language
/// client fixture executable locator.
enum GitProcessSpyLocator {
    enum LocatorError: Error {
        case notFound
    }

    private final class Sentinel {}

    static func executableURL() throws -> URL {
        if let fromBundle = Bundle(for: Sentinel.self)
            .bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("GitProcessSpy") as URL?,
            FileManager.default.isExecutableFile(atPath: fromBundle.path) {
            return fromBundle
        }

        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let buildRoot = directory.appendingPathComponent(".build")
            if let found = search(buildRoot) {
                return found
            }
            directory.deleteLastPathComponent()
        }
        throw LocatorError.notFound
    }

    private static func search(_ root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return nil
        }
        for case let url as URL in enumerator where url.lastPathComponent == "GitProcessSpy" {
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}
