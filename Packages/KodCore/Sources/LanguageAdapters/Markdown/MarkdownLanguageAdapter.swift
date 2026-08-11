import Foundation
import SyntaxCore
import WorkspaceCore

public enum MarkdownLanguageAdapter: LanguageAdapter {
    public static let languageKey = "markdown"
    public static let displayName = "Markdown (Marksman)"
    public static let executableProfiles = [
        LanguageServerExecutableProfile(executableNames: ["marksman"], arguments: ["server"])
    ]
    public static let semanticTokenTypes = StandardSemanticTokenLegend.tokenTypes
    public static let semanticTokenModifiers = StandardSemanticTokenLegend.tokenModifiers
    public static let syntaxLanguages: Set<SyntaxLanguage> = [.markdown]

    public static func lspLanguageId(forExtension fileExtension: String) -> String? {
        fileExtensions.contains(fileExtension.lowercased()) ? "markdown" : nil
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
