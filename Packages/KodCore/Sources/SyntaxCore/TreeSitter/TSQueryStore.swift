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
        var sources: [String] = []
        for resource in highlightResources(for: language) {
            guard let url = queryResourceURL(directory: resource.directory, name: resource.name) else {
                let relativePath = "\(resource.directory)/\(resource.name).scm"
                let error = TreeSitterQueryError.missingResource(relativePath)
                SyntaxCoreLog.queries.error(
                    "Bundled query missing at \(relativePath, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                return .failure(error)
            }
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                let error = TreeSitterQueryError.missingResource(url.path)
                SyntaxCoreLog.queries.error(
                    "Could not read query at \(url.path, privacy: .public)"
                )
                return .failure(error)
            }
            sources.append(source)
        }
        let source = sources.joined(separator: "\n")

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

    /// Tree-sitter's TypeScript queries extend JavaScript's base query.
    /// JavaScript also keeps parameter/JSX captures in companion files, and
    /// TSX shares the compatible JSX captures. The C query API does not
    /// resolve those conventions, so Kod composes each compatible set.
    private static func highlightResources(
        for language: SyntaxLanguage
    ) -> [(directory: String, name: String)] {
        let javascriptBase = [(directory: "javascript", name: "highlights")]
        switch language {
        case .javascript:
            return javascriptBase + [
                (directory: "javascript", name: "highlights-params"),
                (directory: "javascript", name: "highlights-jsx")
            ]
        case .typescript:
            return javascriptBase + [(directory: "typescript", name: "highlights")]
        case .tsx:
            return javascriptBase + [
                (directory: "javascript", name: "highlights-jsx"),
                (directory: "typescript", name: "highlights")
            ]
        default:
            return [(directory: language.rawValue, name: "highlights")]
        }
    }

    private static func queryResourceURL(directory: String, name: String) -> URL? {
        Bundle.module.url(
            forResource: name,
            withExtension: "scm",
            subdirectory: "Resources/Queries/\(directory)"
        ) ?? Bundle.module.url(
            forResource: name,
            withExtension: "scm",
            subdirectory: "Queries/\(directory)"
        )
    }
}
