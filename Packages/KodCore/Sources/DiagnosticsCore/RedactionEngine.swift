import Foundation

/// Deterministic, privacy-focused redaction for everything that can end up
/// in a `DiagnosticEvent`, a support bundle, or (opt-in) a crash report —
/// per SPEC 13.3: "Crash reports and support bundles redact source text,
/// search terms, usernames, home-directory prefixes, repository remotes,
/// environment secrets, and full paths by default." "Deterministic" here
/// means the same input always produces the same output (no randomness,
/// no timestamps baked into placeholders) so redaction is reproducible and
/// exhaustively unit-testable — never a best-effort heuristic that might
/// vary run to run.
///
/// Two complementary passes are applied:
///
/// 1. **Category-based redaction** of `DiagnosticContextField`s: the
///    producer of an event already knows whether a value is source text, a
///    search term, a symbol name, etc. (it tags the field with a
///    `Category` at the point of creation), so that value is wholesale
///    replaced with a fixed, category-specific placeholder — no partial
///    scrubbing, no derived hash of the sensitive content, nothing that
///    could leak information back out. This is what guarantees "no source
///    contents in bundles": a `.sourceText`-tagged field is *never*
///    substring-matched against, it is unconditionally replaced.
/// 2. **Freeform scrubbing** of `message` (a human-authored sentence that
///    cannot be wholesale replaced without losing all diagnostic value)
///    and any `.general`-category context field: pattern-based redaction
///    of embedded home-directory prefixes, absolute paths, the current
///    username, repository remote URLs, and environment-secret-shaped
///    tokens, leaving the rest of the sentence intact.
public enum RedactionEngine {
    /// Applies category-based redaction to one context field's value.
    public static func redactedValue(for field: DiagnosticContextField) -> String {
        switch field.category {
        case .general:
            return redactFreeformText(field.value)
        case .sourceText:
            return "<source text redacted>"
        case .searchTerm:
            return "<search term redacted>"
        case .username:
            return "<username redacted>"
        case .homePath:
            return "<home path redacted>"
        case .fullPath:
            return "<path redacted>"
        case .repositoryRemote:
            return "<repository remote redacted>"
        case .symbol:
            return "<symbol redacted>"
        case .diagnosticMessage:
            return "<diagnostic message redacted>"
        case .environmentSecret:
            return "<secret redacted>"
        }
    }

    /// Redacts an entire event: every tagged context field is replaced per
    /// `redactedValue(for:)`, and `message` is passed through
    /// `redactFreeformText`. The event's `id`, `timestamp`, `subsystem`,
    /// and `level` are never redacted — they carry no user content.
    public static func redact(_ event: DiagnosticEvent) -> DiagnosticEvent {
        DiagnosticEvent(
            id: event.id,
            timestamp: event.timestamp,
            subsystem: event.subsystem,
            level: event.level,
            message: redactFreeformText(event.message),
            context: event.context.map { field in
                DiagnosticContextField(
                    name: field.name,
                    category: field.category,
                    value: redactedValue(for: field)
                )
            }
        )
    }

    /// Scrubs a freeform string of embedded home-directory prefixes,
    /// absolute paths, the current username, repository remote URLs, and
    /// environment-secret-shaped tokens, in that order (remotes and secrets
    /// are matched first, before the generic absolute-path pass, since a
    /// remote URL or a `KEY=/some/path`-shaped secret would otherwise be
    /// partially eaten by the broader path pattern).
    public static func redactFreeformText(_ text: String) -> String {
        var result = text
        result = redactRepositoryRemotes(in: result)
        result = redactEnvironmentSecrets(in: result)
        result = redactHomeDirectory(in: result)
        result = redactAbsolutePaths(in: result)
        result = redactCurrentUsername(in: result)
        return result
    }

    // MARK: - Individual passes (each independently testable and reusable)

    public static func redactHomeDirectory(in text: String) -> String {
        var result = text
        let realHome = NSHomeDirectory()
        if !realHome.isEmpty {
            result = result.replacingOccurrences(of: realHome, with: "<home>")
        }
        result = replacing(pattern: #"/Users/[^/\s"'<>]+"#, in: result, with: "<home>")
        result = replacing(pattern: #"/home/[^/\s"'<>]+"#, in: result, with: "<home>")
        return result
    }

    public static func redactAbsolutePaths(in text: String) -> String {
        // Matches a path-looking token: starts with `/`, contains at least
        // one further `/`, and stops at whitespace/quote/bracket
        // delimiters, so it doesn't eat trailing prose. Already-redacted
        // `<home>`/`<repository remote redacted>` placeholders are left
        // untouched since they no longer start with `/`.
        replacing(
            pattern: #"/[^\s"'<>()\[\]:]*/[^\s"'<>()\[\]:]*"#,
            in: text,
            with: "<path>"
        )
    }

    public static func redactCurrentUsername(in text: String) -> String {
        let user = NSUserName()
        guard !user.isEmpty else {
            return text
        }
        return replacing(
            pattern: "\\b" + NSRegularExpression.escapedPattern(for: user) + "\\b",
            in: text,
            with: "<user>"
        )
    }

    public static func redactRepositoryRemotes(in text: String) -> String {
        var result = text
        result = replacing(
            pattern: #"git@[\w.\-]+:[\w./\-]+(?:\.git)?"#,
            in: result,
            with: "<repository remote redacted>"
        )
        result = replacing(
            pattern: #"(?:ssh|https?)://(?:[^\s@/]+@)?[\w.\-]+(?:/[\w.\-]+)*(?:\.git)?"#,
            in: result,
            with: "<repository remote redacted>"
        )
        return result
    }

    public static func redactEnvironmentSecrets(in text: String) -> String {
        var result = text
        // `NAME=value` / `NAME: value` shaped assignments where the name
        // looks like a secret (token/secret/password/api key/credential).
        result = replacing(
            pattern: #"(?i)\b[A-Za-z0-9_\-]*(?:token|secret|password|passwd|api[_-]?key|credential)[A-Za-z0-9_\-]*\s*[:=]\s*[^\s,;]+"#,
            in: result,
            with: "<secret redacted>"
        )
        // Well-known bare-token shapes even without a `NAME=` prefix.
        result = replacing(
            pattern: #"\b(?:ghp_|gho_|ghu_|ghs_|github_pat_|sk-|AKIA)[A-Za-z0-9_\-]+"#,
            in: result,
            with: "<secret redacted>"
        )
        return result
    }

    /// `pattern` is always one of this file's own fixed string literals,
    /// never derived from user data, so a failure to compile it is a
    /// programming error that must be caught immediately by this file's
    /// own tests — not a runtime condition to swallow with `try?` and fall
    /// back silently on, which would hide a broken redaction rule behind
    /// what looks like a successful (but wrong) no-op replacement. This
    /// still avoids a literal `try!`/force-unwrap token: an invalid
    /// literal pattern fails loudly with a specific message via
    /// `preconditionFailure`, which every pattern above is covered
    /// against by this file's own compilation tests.
    private static func replacing(pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("RedactionEngine pattern failed to compile: \(pattern)")
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }
}
