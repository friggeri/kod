import Foundation

/// A destination URL extracted from a Markdown link/image/autolink,
/// classified so the App layer can enforce SPEC 10.1's link/image policy
/// ("Links show their destination and require confirmation before opening
/// non-local URLs from an untrusted workspace", "Remote images ... are
/// blocked by default") without re-parsing the URL itself.
public struct MarkdownDestination: Equatable, Sendable {
    public enum Scheme: Equatable, Sendable {
        /// A same-document fragment (`#section`) or a relative path with
        /// no scheme — the only kind of destination Kod ever navigates to
        /// or fetches without explicit confirmation.
        case local
        case http
        case https
        case mailto
        /// `javascript:`, `data:`, `file:`, `vbscript:`, or any other
        /// scheme not explicitly recognized as safe-by-default. Kod never
        /// auto-navigates or auto-fetches these regardless of workspace
        /// trust.
        case unsafeOrUnrecognized(String)
    }

    public let rawValue: String
    public let scheme: Scheme

    public init(rawValue: String) {
        self.rawValue = rawValue
        self.scheme = MarkdownDestination.classify(rawValue)
    }

    private static func classify(_ rawValue: String) -> Scheme {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colonIndex = trimmed.firstIndex(of: ":") else {
            return .local
        }
        // A "scheme" must precede any `/`, `?`, or `#` to actually be a
        // URL scheme and not, say, a relative path containing a colon
        // (`notes:section` is not standard, but `./a:b.md` must not be
        // misread as scheme `./a`).
        let beforeColon = trimmed[trimmed.startIndex..<colonIndex]
        guard let firstCharacter = beforeColon.first,
              firstCharacter.isLetter,
              beforeColon.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) else {
            return .local
        }
        switch beforeColon.lowercased() {
        case "http": return .http
        case "https": return .https
        case "mailto": return .mailto
        default: return .unsafeOrUnrecognized(String(beforeColon))
        }
    }

    /// Whether this destination requires explicit user confirmation
    /// before Kod navigates to it from an untrusted workspace (SPEC 10.1).
    public var requiresConfirmationInUntrustedWorkspace: Bool {
        scheme != .local
    }
}
