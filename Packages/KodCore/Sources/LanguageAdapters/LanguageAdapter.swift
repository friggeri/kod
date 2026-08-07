import Foundation
import WorkspaceCore

/// A typed description of one launch language's LSP integration: what
/// file extensions it covers, what `languageId` to send per extension,
/// and how to discover its server executable (SPEC 6.5). Concrete
/// adapters (`SwiftAdapter`, `TypeScriptLanguageAdapter`,
/// `HTMLLanguageAdapter`, `CSSLanguageAdapter`, `PythonLanguageAdapter`,
/// `RustLanguageAdapter`) each provide one of these; the app layer picks
/// an adapter for an open file purely by extension, never by reading any
/// repository-provided project configuration to decide which server to
/// launch.
public protocol LanguageAdapter: Sendable {
    /// Stable identifier used as the `LanguageServerOverrideStore` key
    /// and in discovery-failure messages — never derived from anything
    /// in the opened workspace.
    static var languageKey: String { get }
    static var displayName: String { get }
    static var fileExtensions: Set<String> { get }
    static var semanticTokenTypes: [String] { get }
    static var semanticTokenModifiers: [String] { get }

    /// The LSP `languageId` to send in `textDocument/didOpen` for a
    /// given lowercased file extension (e.g. `"ts"` -> `"typescript"`,
    /// `"tsx"` -> `"typescriptreact"`). Returns `nil` for an extension
    /// this adapter doesn't claim.
    static func lspLanguageId(forExtension fileExtension: String) -> String?

    static func discover(
        overrideStore: LanguageServerOverrideStore,
        identity: WorkspaceIdentity?
    ) throws -> DiscoveredExecutable
}
