import Foundation
import SyntaxCore
import WorkspaceCore

/// CSS adapter using `vscode-css-language-server` (from the
/// `vscode-langservers-extracted` package). Covers CSS/SCSS/LESS with
/// their respective `languageId`s.
public enum CSSLanguageAdapter: LanguageAdapter {
    public static let languageKey = "css"
    public static let displayName = "CSS (vscode-css-language-server)"
    public static let syntaxLanguages: Set<SyntaxLanguage> = [.css]
    public static let additionalFileExtensions: Set<String> = ["scss", "less"]
    public static let executableProfiles = [
        LanguageServerExecutableProfile(
            executableNames: ["vscode-css-language-server"],
            arguments: ["--stdio"],
            versionArguments: nil
        )
    ]
    public static let semanticTokenTypes = StandardSemanticTokenLegend.tokenTypes
    public static let semanticTokenModifiers = StandardSemanticTokenLegend.tokenModifiers

    public static func lspLanguageId(forExtension fileExtension: String) -> String? {
        switch fileExtension.lowercased() {
        case "css":
            return "css"
        case "scss":
            return "scss"
        case "less":
            return "less"
        default:
            return nil
        }
    }

    public static func discover(
        overrideStore: LanguageServerOverrideStore,
        identity: WorkspaceIdentity?
    ) throws -> DiscoveredExecutable {
        try LanguageServerDiscoveryEngine.resolve(
            languageKey: languageKey,
            languageDisplayName: displayName,
            executableNames: ["vscode-css-language-server"],
            arguments: ["--stdio"],
            // See `HTMLLanguageAdapter`: this server also errors out on
            // any invocation without a transport flag, including
            // `--version`.
            versionArguments: nil,
            overrideStore: overrideStore,
            identity: identity
        )
    }
}
