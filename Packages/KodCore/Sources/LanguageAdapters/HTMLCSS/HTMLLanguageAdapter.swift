import Foundation
import WorkspaceCore

/// HTML adapter using `vscode-html-language-server` (from the
/// `vscode-langservers-extracted` package — the same server VS Code's
/// built-in HTML support uses).
public enum HTMLLanguageAdapter: LanguageAdapter {
    public static let languageKey = "html"
    public static let displayName = "HTML (vscode-html-language-server)"
    public static let fileExtensions: Set<String> = ["html", "htm"]
    public static let semanticTokenTypes = StandardSemanticTokenLegend.tokenTypes
    public static let semanticTokenModifiers = StandardSemanticTokenLegend.tokenModifiers

    public static func lspLanguageId(forExtension fileExtension: String) -> String? {
        ["html", "htm"].contains(fileExtension.lowercased()) ? "html" : nil
    }

    public static func discover(
        overrideStore: LanguageServerOverrideStore,
        identity: WorkspaceIdentity?
    ) throws -> DiscoveredExecutable {
        try LanguageServerDiscoveryEngine.resolve(
            languageKey: languageKey,
            languageDisplayName: displayName,
            executableNames: ["vscode-html-language-server"],
            arguments: ["--stdio"],
            // This server errors out on any invocation without a
            // transport flag (`--stdio`/`--node-ipc`/`--socket`),
            // including `--version` — so unlike Kod's other adapters,
            // version detection here is left to the `initialize`
            // handshake / recorded compatibility metadata rather than a
            // standalone version probe.
            versionArguments: nil,
            managedInstallProbe: {
                ManagedInstallDiscoverySource.discover(serverID: "vscode-html-language-server", controller: ManagedInstallDiscoverySource.shared)
            },
            overrideStore: overrideStore,
            identity: identity
        )
    }
}
