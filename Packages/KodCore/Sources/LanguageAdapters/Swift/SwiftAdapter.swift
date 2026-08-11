import Foundation
import LanguageClient
import SyntaxCore
import WorkspaceCore

/// Swift's adapter for Kod's generic language-adapter layer. Preserves
/// Phase 6's exclusive `xcrun --find sourcekit-lsp` discovery as tier 3
/// ("language-specific system discovery") of SPEC 6.5's full precedence
/// order, so explicit workspace/global overrides now also work for
/// Swift, while the default (no override configured) behavior is
/// unchanged from Phase 6.
public enum SwiftAdapter: LanguageAdapter {
    public static let languageKey = "swift"
    public static let displayName = "Swift (SourceKit-LSP)"
    public static let syntaxLanguages: Set<SyntaxLanguage> = [.swift]
    public static let executableProfiles = [
        LanguageServerExecutableProfile(executableNames: ["sourcekit-lsp"], arguments: [], versionArguments: nil)
    ]
    public static let semanticTokenTypes = SwiftWorkspaceLanguageService.semanticTokenTypes
    public static let semanticTokenModifiers = SwiftWorkspaceLanguageService.semanticTokenModifiers

    public static func lspLanguageId(forExtension fileExtension: String) -> String? {
        fileExtension.lowercased() == "swift" ? "swift" : nil
    }

    public static func discover(
        overrideStore: LanguageServerOverrideStore,
        identity: WorkspaceIdentity?
    ) throws -> DiscoveredExecutable {
        try LanguageServerDiscoveryEngine.resolve(
            languageKey: languageKey,
            languageDisplayName: displayName,
            executableNames: ["sourcekit-lsp"],
            arguments: [],
            versionArguments: nil,
            languageSpecificProbe: {
                try? SourceKitLSPDiscovery.discoverExecutableURL()
            },
            overrideStore: overrideStore,
            identity: identity
        )
    }
}
