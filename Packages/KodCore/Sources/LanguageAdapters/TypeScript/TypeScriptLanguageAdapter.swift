import Foundation
import WorkspaceCore

/// TypeScript/JavaScript adapter using `typescript-language-server`
/// (which wraps the `typescript` compiler's own language service).
/// Covers `.ts`/`.tsx`/`.js`/`.jsx` with the four matching LSP
/// `languageId`s.
public enum TypeScriptLanguageAdapter: LanguageAdapter {
    public static let languageKey = "typescript"
    public static let displayName = "TypeScript/JavaScript (typescript-language-server)"
    public static let fileExtensions: Set<String> = ["ts", "tsx", "js", "jsx", "mjs", "cjs"]
    public static let semanticTokenTypes = StandardSemanticTokenLegend.tokenTypes
    public static let semanticTokenModifiers = StandardSemanticTokenLegend.tokenModifiers

    public static func lspLanguageId(forExtension fileExtension: String) -> String? {
        switch fileExtension.lowercased() {
        case "ts":
            return "typescript"
        case "tsx":
            return "typescriptreact"
        case "js", "mjs", "cjs":
            return "javascript"
        case "jsx":
            return "javascriptreact"
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
            executableNames: ["typescript-language-server"],
            arguments: ["--stdio"],
            versionArguments: ["--version"],
            managedInstallProbe: {
                ManagedInstallDiscoverySource.discover(serverID: "typescript-language-server", controller: ManagedInstallDiscoverySource.shared)
            },
            overrideStore: overrideStore,
            identity: identity
        )
    }
}
