import Foundation
import SyntaxCore
import WorkspaceCore

public enum TOMLLanguageAdapter: LanguageAdapter {
    public static let languageKey = "toml"
    public static let displayName = "TOML (Tombi or Taplo)"
    public static let executableProfiles = [
        LanguageServerExecutableProfile(executableNames: ["tombi"], arguments: ["lsp"]),
        LanguageServerExecutableProfile(executableNames: ["taplo"], arguments: ["lsp", "stdio"])
    ]
    public static let networkAccess: LanguageServerNetworkAccess = .remoteSchemasAfterWorkspaceTrust
    public static let semanticTokenTypes = StandardSemanticTokenLegend.tokenTypes
    public static let semanticTokenModifiers = StandardSemanticTokenLegend.tokenModifiers
    public static let syntaxLanguages: Set<SyntaxLanguage> = [.toml]

    public static func lspLanguageId(forExtension fileExtension: String) -> String? {
        fileExtension.lowercased() == "toml" ? "toml" : nil
    }

    public static func discover(
        overrideStore: LanguageServerOverrideStore,
        identity: WorkspaceIdentity?
    ) throws -> DiscoveredExecutable {
        try discover(
            overrideStore: overrideStore,
            identity: identity,
            loginShellPath: { LoginShellPathCapture.capture() },
            packageManagerDirectories: LanguageServerDiscoveryEngine.defaultPackageManagerDirectories()
        )
    }

    static func discover(
        overrideStore: LanguageServerOverrideStore,
        identity: WorkspaceIdentity?,
        loginShellPath: @escaping @Sendable () -> String?,
        packageManagerDirectories: [URL]
    ) throws -> DiscoveredExecutable {
        let tombiResult = Result {
            try LanguageServerDiscoveryEngine.resolve(
                languageKey: languageKey,
                languageDisplayName: displayName,
                profile: executableProfiles[0],
                overrideStore: overrideStore,
                identity: identity,
                loginShellPath: loginShellPath,
                packageManagerDirectories: packageManagerDirectories
            )
        }

        if case .success(let tombi) = tombiResult {
            return tombi
        }

        if let taplo = try? LanguageServerDiscoveryEngine.resolve(
            languageKey: languageKey,
            languageDisplayName: displayName,
            profile: executableProfiles[1],
            overrideStore: overrideStore,
            identity: nil,
            loginShellPath: loginShellPath,
            packageManagerDirectories: packageManagerDirectories,
            includeOverrides: false
        ) {
            return taplo
        }

        return try tombiResult.get()
    }
}
