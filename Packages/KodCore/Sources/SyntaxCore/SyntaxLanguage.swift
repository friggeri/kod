import Foundation

/// The fixed set of Tree-sitter grammars compiled into Kod. Per SPEC 7.1,
/// there is no runtime grammar-extension mechanism in 1.0: every language
/// here corresponds to a pinned grammar vendored under a `CTreeSitter*`
/// target and compiled into the app at build time.
public enum SyntaxLanguage: String, CaseIterable, Sendable, Codable {
    case swift
    case typescript
    case javascript
    case html
    case css
    case python
    case rust

    public var displayName: String {
        switch self {
        case .swift: "Swift"
        case .typescript: "TypeScript"
        case .javascript: "JavaScript"
        case .html: "HTML"
        case .css: "CSS"
        case .python: "Python"
        case .rust: "Rust"
        }
    }

    /// Detects a launch language from a file's path extension (without the
    /// leading dot), matching the combinations in SPEC 4.2. Returns `nil`
    /// for files Kod has no compiled grammar for, in which case the viewer
    /// falls back to plain-text rendering only.
    public static func detect(forPathExtension pathExtension: String) -> SyntaxLanguage? {
        switch pathExtension.lowercased() {
        case "swift":
            .swift
        case "ts", "mts", "cts":
            .typescript
        case "js", "mjs", "cjs", "jsx":
            .javascript
        case "html", "htm":
            .html
        case "css":
            .css
        case "py", "pyi", "pyw":
            .python
        case "rs":
            .rust
        default:
            nil
        }
    }

    public static func detect(forURL url: URL) -> SyntaxLanguage? {
        detect(forPathExtension: url.pathExtension)
    }
}
