import Foundation

/// One match's byte range within `SearchMatch.lineText`'s UTF-8 bytes (or,
/// when `SearchMatch.lineIsValidUTF8` is `false`, within the original raw
/// line bytes obtained by base64-decoding the engine's `bytes` field —
/// `lineText` in that case is a lossy display-only decoding and must not be
/// re-sliced with this range).
public struct SearchMatchRange: Equatable, Sendable {
    public let utf8Range: Range<Int>

    public init(utf8Range: Range<Int>) {
        self.utf8Range = utf8Range
    }
}

/// A single matched line within a searched file.
public struct SearchMatch: Equatable, Sendable {
    /// 1-based line number, as reported by the engine.
    public let lineNumber: Int
    /// The matched line's text. Valid UTF-8 content decodes exactly; when
    /// `lineIsValidUTF8` is `false` this is a lossy `U+FFFD`-substituted
    /// decoding provided only for display.
    public let lineText: String
    public let lineIsValidUTF8: Bool
    public let ranges: [SearchMatchRange]

    public init(
        lineNumber: Int,
        lineText: String,
        lineIsValidUTF8: Bool,
        ranges: [SearchMatchRange]
    ) {
        self.lineNumber = lineNumber
        self.lineText = lineText
        self.lineIsValidUTF8 = lineIsValidUTF8
        self.ranges = ranges
    }
}

/// All matches streamed so far for one file. `WorkspaceTextSearcher` emits
/// one of these per file as soon as that file's matches are available,
/// rather than waiting for the whole workspace search to finish.
public struct SearchFileResult: Equatable, Sendable {
    public let relativePath: String
    public let matches: [SearchMatch]

    public init(relativePath: String, matches: [SearchMatch]) {
        self.relativePath = relativePath
        self.matches = matches
    }
}

/// Terminal, non-error summary of a search. `truncated` is `true` when
/// `SearchQuery.resultLimit` was reached: per SPEC 8.2, reaching a limit
/// must never be presented as a complete search.
public struct SearchCompletion: Equatable, Sendable {
    public let queryVersion: Int
    public let matchedFileCount: Int
    public let matchCount: Int
    public let truncated: Bool

    public init(
        queryVersion: Int,
        matchedFileCount: Int,
        matchCount: Int,
        truncated: Bool
    ) {
        self.queryVersion = queryVersion
        self.matchedFileCount = matchedFileCount
        self.matchCount = matchCount
        self.truncated = truncated
    }
}

public enum SearchStreamEvent: Equatable, Sendable {
    case fileResult(SearchFileResult)
    case completed(SearchCompletion)
}

/// Every explicit failure mode `WorkspaceTextSearcher` can surface. There is
/// no silent/best-effort fallback: any of these ends the search stream by
/// throwing, and callers are expected to show the message to the user.
public enum SearchError: Error, Equatable, Sendable {
    /// The bundled engine could not be located for this architecture.
    case engineUnavailable(SearchEngineError)
    /// `Process.run()` itself failed (e.g. the binary lost its executable
    /// bit, or the sandbox denied the launch).
    case processLaunchFailed(String)
    /// The engine exited with neither "matches found" (0) nor "no matches"
    /// (1) — e.g. an invalid regular expression or an unreadable path.
    /// `message` is the engine's own stderr diagnostic.
    case engineReported(exitCode: Int32, message: String)
    /// A line of the engine's `--json` stream failed to decode as the
    /// expected schema, or a single line exceeded the bounded buffer.
    /// Kod stops parsing immediately rather than guessing.
    case malformedOutput(String)
}
