import Foundation
import LanguageClient
import SourceModel
import SyntaxCore
import WorkspaceCore

public struct LanguageServerExecutableProfile: Sendable, Equatable {
    public let executableNames: Set<String>
    public let arguments: [String]
    public let versionArguments: [String]?

    public init(
        executableNames: Set<String>,
        arguments: [String],
        versionArguments: [String]? = ["--version"]
    ) {
        self.executableNames = executableNames
        self.arguments = arguments
        self.versionArguments = versionArguments
    }
}

public enum LanguageServerNetworkAccess: String, Codable, Sendable, Equatable {
    case none
    case remoteSchemasAfterWorkspaceTrust
}

public enum LanguageServerSupportNote: String, Codable, Sendable, Hashable {
    case shellCheckOptional
}

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
    static var additionalFileExtensions: Set<String> { get }
    static var exactFileNames: Set<String> { get }
    static var executableProfiles: [LanguageServerExecutableProfile] { get }
    static var networkAccess: LanguageServerNetworkAccess { get }
    static var supportNotes: [LanguageServerSupportNote] { get }
    static var semanticTokenTypes: [String] { get }
    static var semanticTokenModifiers: [String] { get }
    static var initializationOptions: JSONValue? { get }
    static var workspaceConfiguration: [String: JSONValue] { get }
    static var syntaxLanguages: Set<SyntaxLanguage> { get }

    /// The LSP `languageId` to send in `textDocument/didOpen` for a
    /// given lowercased file extension (e.g. `"ts"` -> `"typescript"`,
    /// `"tsx"` -> `"typescriptreact"`). Returns `nil` for an extension
    /// this adapter doesn't claim.
    static func lspLanguageId(forExtension fileExtension: String) -> String?
    static func lspLanguageId(forURL url: URL) -> String?
    static func supports(url: URL) -> Bool
    static func supports(snapshot: SourceSnapshot) -> Bool

    static func discover(
        overrideStore: LanguageServerOverrideStore,
        identity: WorkspaceIdentity?
    ) throws -> DiscoveredExecutable
}

public extension LanguageAdapter {
    static var initializationOptions: JSONValue? { nil }
    static var workspaceConfiguration: [String: JSONValue] { [:] }
    static var syntaxLanguages: Set<SyntaxLanguage> { [] }
    static var additionalFileExtensions: Set<String> { [] }
    static var fileExtensions: Set<String> {
        syntaxLanguages.reduce(into: additionalFileExtensions) { extensions, language in
            extensions.formUnion(language.fileExtensions)
        }
    }
    static var exactFileNames: Set<String> {
        syntaxLanguages.reduce(into: Set<String>()) { fileNames, language in
            fileNames.formUnion(language.fileNames)
        }
    }
    static var executableProfiles: [LanguageServerExecutableProfile] { [] }
    static var networkAccess: LanguageServerNetworkAccess { .none }
    static var supportNotes: [LanguageServerSupportNote] { [] }

    static func supports(url: URL) -> Bool {
        exactFileNames.contains(url.lastPathComponent.lowercased())
            || fileExtensions.contains(url.pathExtension.lowercased())
    }

    static func supports(snapshot: SourceSnapshot) -> Bool {
        if let language = SyntaxLanguage.detect(for: snapshot),
           syntaxLanguages.contains(language) {
            return true
        }
        return supports(url: snapshot.url)
    }

    static func lspLanguageId(forURL url: URL) -> String? {
        lspLanguageId(forExtension: url.pathExtension.lowercased())
    }

    static func arguments(forExecutableURL url: URL) -> [String] {
        executableProfiles.first {
            $0.executableNames.contains(url.lastPathComponent)
        }?.arguments ?? executableProfiles.first?.arguments ?? []
    }
}
