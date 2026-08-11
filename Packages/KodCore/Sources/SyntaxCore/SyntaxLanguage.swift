import Foundation
import SourceModel

/// The fixed set of Tree-sitter grammars compiled into Kod. Per SPEC 7.1,
/// there is no runtime grammar-extension mechanism in 1.0: every language
/// here corresponds to a pinned grammar vendored under a `CTreeSitter*`
/// target and compiled into the app at build time.
public enum SyntaxLanguage: String, CaseIterable, Sendable, Codable {
    case swift
    case typescript
    case tsx
    case javascript
    case html
    case css
    case python
    case rust
    case shell = "bash"
    case markdown
    case markdownInline = "markdown-inline"
    case json
    case yaml
    case toml
    case c
    case go
    case java
    case ruby
    case lua
    case graphql
    case xml

    public var displayName: String {
        switch self {
        case .swift: "Swift"
        case .typescript: "TypeScript"
        case .tsx: "TypeScript React"
        case .javascript: "JavaScript"
        case .html: "HTML"
        case .css: "CSS"
        case .python: "Python"
        case .rust: "Rust"
        case .shell: "Shell"
        case .markdown: "Markdown"
        case .markdownInline: "Markdown Inline"
        case .json: "JSON"
        case .yaml: "YAML"
        case .toml: "TOML"
        case .c: "C"
        case .go: "Go"
        case .java: "Java"
        case .ruby: "Ruby"
        case .lua: "Lua"
        case .graphql: "GraphQL"
        case .xml: "XML"
        }
    }

    public var fileExtensions: Set<String> {
        switch self {
        case .swift: ["swift"]
        case .typescript: ["ts", "mts", "cts"]
        case .tsx: ["tsx"]
        case .javascript: ["js", "mjs", "cjs", "jsx"]
        case .html: ["html", "htm"]
        case .css: ["css"]
        case .python: ["py", "pyi", "pyw"]
        case .rust: ["rs"]
        case .shell: ["sh", "bash", "command"]
        case .markdown: ["md", "markdown", "mdown", "mkd", "mkdn"]
        case .json: ["json"]
        case .yaml: ["yaml", "yml"]
        case .toml: ["toml"]
        case .c: ["c", "h"]
        case .go: ["go"]
        case .java: ["java"]
        case .ruby: ["rb", "rake", "gemspec"]
        case .lua: ["lua"]
        case .graphql: ["graphql", "gql"]
        case .xml: ["xml", "svg", "xsd", "xsl", "xslt", "plist"]
        case .markdownInline: []
        }
    }

    public var fileNames: Set<String> {
        switch self {
        case .shell:
            [".bashrc", ".bash_profile", ".bash_login", ".profile"]
        case .ruby:
            ["gemfile", "rakefile", "guardfile", "config.ru"]
        case .xml:
            ["info.plist", "contents.xml", "androidmanifest.xml", "web.config"]
        default:
            []
        }
    }

    /// Detects a launch language from a file's path extension (without the
    /// leading dot), matching the combinations in SPEC 4.2. Returns `nil`
    /// for files Kod has no compiled grammar for, in which case the viewer
    /// falls back to plain-text rendering only.
    public static func detect(forPathExtension pathExtension: String) -> SyntaxLanguage? {
        let normalized = pathExtension.lowercased()
        return allCases.first { $0.fileExtensions.contains(normalized) }
    }

    public static func detect(forURL url: URL) -> SyntaxLanguage? {
        let fileName = url.lastPathComponent.lowercased()
        if let exactMatch = allCases.first(where: { $0.fileNames.contains(fileName) }) {
            return exactMatch
        }
        return detect(forPathExtension: url.pathExtension)
    }

    public static func detect(for snapshot: SourceSnapshot) -> SyntaxLanguage? {
        if let detected = detect(forURL: snapshot.url) {
            return detected
        }
        let firstLine = snapshot.text.prefix(256)
            .split(whereSeparator: { $0.isNewline })
            .first?
            .lowercased() ?? ""
        guard firstLine.hasPrefix("#!") else {
            return nil
        }
        let words = firstLine.split(whereSeparator: { $0.isWhitespace })
        if words.contains(where: { word in
            let executable = word.split(separator: "/").last.map(String.init) ?? String(word)
            return executable == "sh" || executable == "bash"
        }) {
            return .shell
        }
        return nil
    }
}
