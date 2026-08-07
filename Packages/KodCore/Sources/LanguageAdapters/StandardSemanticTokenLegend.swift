import Foundation

/// The complete LSP-standard semantic token type/modifier legend Kod
/// requests and understands (LSP 3.17 §3.17.6), shared by every
/// non-Swift adapter. Anything a server's own legend maps to outside
/// this list is still decoded (index-based) but reported under its raw
/// name so the decoration layer can no-op unknown types gracefully —
/// identical in spirit to `SwiftWorkspaceLanguageService`'s own list.
public enum StandardSemanticTokenLegend {
    public static let tokenTypes = [
        "namespace", "type", "class", "enum", "interface", "struct", "typeParameter",
        "parameter", "variable", "property", "enumMember", "function", "method",
        "macro", "keyword", "modifier", "comment", "string", "number", "regexp", "operator",
        "decorator", "event", "label"
    ]
    public static let tokenModifiers = [
        "declaration", "definition", "readonly", "static", "deprecated", "abstract",
        "async", "modification", "documentation", "defaultLibrary"
    ]
}
