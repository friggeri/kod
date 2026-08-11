import CTreeSitter
import CTreeSitterBash
import CTreeSitterC
import CTreeSitterCSS
import CTreeSitterGo
import CTreeSitterGraphQL
import CTreeSitterHTML
import CTreeSitterJava
import CTreeSitterJavaScript
import CTreeSitterJSON
import CTreeSitterMarkdown
import CTreeSitterMarkdownInline
import CTreeSitterPython
import CTreeSitterRuby
import CTreeSitterRust
import CTreeSitterSwift
import CTreeSitterTOML
import CTreeSitterTypeScript
import CTreeSitterTSX
import CTreeSitterYAML
import CTreeSitterLua
import CTreeSitterXML

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
        case .shell: tree_sitter_bash()
        case .markdown: tree_sitter_markdown()
        case .markdownInline: tree_sitter_markdown_inline()
        case .json: tree_sitter_json()
        case .yaml: tree_sitter_yaml()
        case .toml: tree_sitter_toml()
        case .c: tree_sitter_c()
        case .go: tree_sitter_go()
        case .java: tree_sitter_java()
        case .ruby: tree_sitter_ruby()
        case .lua: tree_sitter_lua()
        case .graphql: tree_sitter_graphql()
        case .xml: tree_sitter_xml()
        }
    }
}
