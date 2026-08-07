import CTreeSitter
import CTreeSitterCSS
import CTreeSitterHTML
import CTreeSitterJavaScript
import CTreeSitterPython
import CTreeSitterRust
import CTreeSitterSwift
import CTreeSitterTypeScript
import CTreeSitterTSX

extension SyntaxLanguage {
    /// The pinned, compiled-in `TSLanguage` for this language. Each grammar
    /// is a vendored `parser.c` (plus external scanner where the grammar
    /// needs one) compiled into its own `CTreeSitter<Language>` target; see
    /// `Scripts/vendor-tree-sitter` for provenance and pinned commits.
    var tsLanguage: OpaquePointer {
        switch self {
        case .swift: tree_sitter_swift()
        case .typescript: tree_sitter_typescript()
        case .tsx: tree_sitter_tsx()
        case .javascript: tree_sitter_javascript()
        case .html: tree_sitter_html()
        case .css: tree_sitter_css()
        case .python: tree_sitter_python()
        case .rust: tree_sitter_rust()
        }
    }
}
