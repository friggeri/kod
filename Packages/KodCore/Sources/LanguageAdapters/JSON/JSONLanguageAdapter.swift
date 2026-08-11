import Foundation
import LanguageClient
import SyntaxCore
import WorkspaceCore

public enum JSONLanguageAdapter: LanguageAdapter {
    public static let languageKey = "json"
    public static let displayName = "JSON (vscode-json-language-server)"
    public static let executableProfiles = [
        LanguageServerExecutableProfile(
            executableNames: [
                "vscode-json-language-server",
                "vscode-json-languageserver"
            ],
            arguments: ["--stdio"],
            versionArguments: nil
        )
    ]
    public static let networkAccess: LanguageServerNetworkAccess = .remoteSchemasAfterWorkspaceTrust
    public static let semanticTokenTypes = StandardSemanticTokenLegend.tokenTypes
    public static let semanticTokenModifiers = StandardSemanticTokenLegend.tokenModifiers
    public static let syntaxLanguages: Set<SyntaxLanguage> = [.json]
    public static let workspaceConfiguration: [String: JSONValue] = [
        "json": .object([
            "validate": .object(["enable": .bool(true)])
        ])
    ]

    public static func lspLanguageId(forExtension fileExtension: String) -> String? {
        fileExtension.lowercased() == "json" ? "json" : nil
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
