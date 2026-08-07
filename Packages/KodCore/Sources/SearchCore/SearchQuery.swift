import Foundation

/// SPEC 8.2 workspace text search options: regular expressions, case,
/// whole word, include/exclude globs, hidden files, and ignored files.
public struct SearchOptions: Equatable, Sendable {
    public var matchCase: Bool
    public var wholeWord: Bool
    public var useRegex: Bool
    public var includeHidden: Bool
    public var includeIgnored: Bool
    public var includeGlobs: [String]
    public var excludeGlobs: [String]

    public init(
        matchCase: Bool = false,
        wholeWord: Bool = false,
        useRegex: Bool = false,
        includeHidden: Bool = false,
        includeIgnored: Bool = false,
        includeGlobs: [String] = [],
        excludeGlobs: [String] = []
    ) {
        self.matchCase = matchCase
        self.wholeWord = wholeWord
        self.useRegex = useRegex
        self.includeHidden = includeHidden
        self.includeIgnored = includeIgnored
        self.includeGlobs = includeGlobs
        self.excludeGlobs = excludeGlobs
    }
}

/// A single workspace text search request. `version` is a caller-assigned
/// monotonically increasing token (e.g. incremented once per keystroke or
/// option change); consumers of `WorkspaceTextSearcher` compare it against
/// their own latest-known version so a slow, superseded query's results are
/// discarded rather than shown after a newer query has already started.
public struct SearchQuery: Equatable, Sendable {
    public var pattern: String
    public var root: URL
    public var options: SearchOptions
    public var resultLimit: Int
    public var version: Int

    public init(
        pattern: String,
        root: URL,
        options: SearchOptions = SearchOptions(),
        resultLimit: Int = 5_000,
        version: Int = 0
    ) {
        self.pattern = pattern
        self.root = root
        self.options = options
        self.resultLimit = max(1, resultLimit)
        self.version = version
    }
}
