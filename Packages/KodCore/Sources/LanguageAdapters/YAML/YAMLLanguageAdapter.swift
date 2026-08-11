import Foundation
import LanguageClient
import SyntaxCore
import WorkspaceCore

public enum YAMLLanguageAdapter: LanguageAdapter {
    public static let languageKey = "yaml"
    public static let displayName = "YAML (yaml-language-server)"
    public static let executableProfiles = [
        LanguageServerExecutableProfile(
            executableNames: ["yaml-language-server"],
            arguments: ["--stdio"],
            versionArguments: nil
        )
    ]
    public static let networkAccess: LanguageServerNetworkAccess = .remoteSchemasAfterWorkspaceTrust
    public static let semanticTokenTypes = StandardSemanticTokenLegend.tokenTypes
    public static let semanticTokenModifiers = StandardSemanticTokenLegend.tokenModifiers
    public static let syntaxLanguages: Set<SyntaxLanguage> = [.yaml]
    public static let workspaceConfiguration: [String: JSONValue] = [
        "yaml": .object([
            "validate": .bool(true),
            "hover": .bool(true),
            "schemaStore": .object(["enable": .bool(true)])
        ])
    ]

    public static func lspLanguageId(forExtension fileExtension: String) -> String? {
        fileExtensions.contains(fileExtension.lowercased()) ? "yaml" : nil
    }

    public static func discover(
        overrideStore: LanguageServerOverrideStore,
        identity: WorkspaceIdentity?
    ) throws -> DiscoveredExecutable {
        try LanguageServerDiscoveryEngine.resolve(
            languageKey: languageKey,
            languageDisplayName: displayName,
            profile: executableProfiles[0],
            overrideStore: overrideStore,
            identity: identity
        )
    }
}
