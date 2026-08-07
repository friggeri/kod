import os

/// Centralized, non-fatal logging for parse/query failures so they are
/// never silently swallowed. These failures never crash or block the
/// already-painted plain-text view — they only mean syntax coloring does
/// not appear for the affected file/language — but they must still be
/// visible somewhere for diagnosis, per SPEC 15 ("Reliability and error
/// behavior").
enum SyntaxCoreLog {
    static let subsystem = "com.kodapp.SyntaxCore"

    static let queries = Logger(subsystem: subsystem, category: "queries")
    static let parsing = Logger(subsystem: subsystem, category: "parsing")
}
