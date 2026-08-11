import Foundation
import SyntaxCore
import WorkspaceCore

/// Python adapter using `pyright-langserver` (Pyright's LSP front end).
public enum PythonLanguageAdapter: LanguageAdapter {
    public static let languageKey = "python"
    public static let displayName = "Python (Pyright)"
    public static let syntaxLanguages: Set<SyntaxLanguage> = [.python]
    public static let executableProfiles = [
        LanguageServerExecutableProfile(
            executableNames: ["pyright-langserver"],
            arguments: ["--stdio"],
            versionArguments: nil
        )
    ]
    public static let semanticTokenTypes = StandardSemanticTokenLegend.tokenTypes
    public static let semanticTokenModifiers = StandardSemanticTokenLegend.tokenModifiers

    public static func lspLanguageId(forExtension fileExtension: String) -> String? {
        ["py", "pyi"].contains(fileExtension.lowercased()) ? "python" : nil
    }

    public static func discover(
        overrideStore: LanguageServerOverrideStore,
        identity: WorkspaceIdentity?
    ) throws -> DiscoveredExecutable {
        try LanguageServerDiscoveryEngine.resolve(
            languageKey: languageKey,
            languageDisplayName: displayName,
            executableNames: ["pyright-langserver"],
            arguments: ["--stdio"],
            // `pyright-langserver` also errors out on any invocation
            // without a transport flag, including `--version` — see
            // `HTMLLanguageAdapter`'s equivalent note.
            versionArguments: nil,
            overrideStore: overrideStore,
            identity: identity
        )
    }
}
