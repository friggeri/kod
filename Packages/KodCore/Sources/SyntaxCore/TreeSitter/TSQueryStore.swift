import CTreeSitter
import Foundation

/// Loads and compiles each language's bundled `highlights.scm` query
/// exactly once, then reuses the compiled `TSQuery` for every parse. Query
/// compilation is a small, fixed cost paid once per language per process,
/// not per file.
final class TSQueryStore: @unchecked Sendable {
    static let shared = TSQueryStore()

    private let lock = NSLock()
    private var cache: [SyntaxLanguage: Result<TSQueryBox, TreeSitterQueryError>] = [:]

    private init() {}

    func highlightsQuery(for language: SyntaxLanguage) -> Result<TSQueryBox, TreeSitterQueryError> {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cache[language] {
            return cached
        }

        let result = Self.compileHighlightsQuery(for: language)
        cache[language] = result
        return result
    }

    private static func compileHighlightsQuery(
        for language: SyntaxLanguage
    ) -> Result<TSQueryBox, TreeSitterQueryError> {
        guard let url = Bundle.module.url(
            forResource: "highlights",
            withExtension: "scm",
            subdirectory: "Resources/Queries/\(language.rawValue)"
        ) ?? Bundle.module.url(
            forResource: "highlights",
            withExtension: "scm",
            subdirectory: "Queries/\(language.rawValue)"
        ) else {
            let error = TreeSitterQueryError.missingResource("\(language.rawValue)/highlights.scm")
            SyntaxCoreLog.queries.error(
                "Bundled highlights.scm missing for \(language.rawValue, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return .failure(error)
        }

        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            let error = TreeSitterQueryError.missingResource(url.path)
            SyntaxCoreLog.queries.error(
                "Could not read highlights.scm at \(url.path, privacy: .public)"
            )
            return .failure(error)
        }

        var errorOffset: UInt32 = 0
        var errorType = TSQueryErrorNone
        let query = source.utf8CString.withUnsafeBufferPointer { buffer -> OpaquePointer? in
            guard let base = buffer.baseAddress else {
                return nil
            }
            // Length excludes the trailing NUL `utf8CString` appends.
            return ts_query_new(
                language.tsLanguage,
                base,
                UInt32(buffer.count - 1),
                &errorOffset,
                &errorType
            )
        }

        guard let query else {
            let error = TreeSitterQueryError.invalidQuery(
                offset: Int(errorOffset),
                kind: String(describing: errorType)
            )
            SyntaxCoreLog.queries.error(
                "Failed to compile \(language.rawValue, privacy: .public) highlights.scm at byte offset \(errorOffset): \(String(describing: errorType), privacy: .public)"
            )
            return .failure(error)
        }
        return .success(TSQueryBox(pointer: query))
    }
}
