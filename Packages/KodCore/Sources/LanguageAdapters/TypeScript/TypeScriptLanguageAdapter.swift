import Foundation
import SyntaxCore
import WorkspaceCore

/// TypeScript/JavaScript adapter using TypeScript 7's native LSP when
/// available, or `typescript-language-server` for earlier TypeScript
/// releases.
/// Covers `.ts`/`.tsx`/`.js`/`.jsx` with the four matching LSP
/// `languageId`s.
public enum TypeScriptLanguageAdapter: LanguageAdapter {
    public static let languageKey = "typescript"
    public static let displayName = "TypeScript/JavaScript"
    public static let syntaxLanguages: Set<SyntaxLanguage> = [.typescript, .tsx, .javascript]
    public static let executableProfiles = [
        LanguageServerExecutableProfile(executableNames: ["tsc"], arguments: ["--lsp", "--stdio"]),
        LanguageServerExecutableProfile(executableNames: ["typescript-language-server"], arguments: ["--stdio"])
    ]
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
        let legacyResult = Result {
            try LanguageServerDiscoveryEngine.resolve(
                languageKey: languageKey,
                languageDisplayName: displayName,
                executableNames: ["typescript-language-server"],
                arguments: ["--stdio"],
                versionArguments: ["--version"],
                overrideStore: overrideStore,
                identity: identity,
                loginShellPath: loginShellPath,
                packageManagerDirectories: packageManagerDirectories
            )
        }
        if case .success(let explicit) = legacyResult,
           explicit.source == .workspaceOverride || explicit.source == .globalOverride {
            return explicit
        }

        let native = try? LanguageServerDiscoveryEngine.resolve(
            languageKey: languageKey,
            languageDisplayName: displayName,
            executableNames: ["tsc"],
            arguments: ["--lsp", "--stdio"],
            versionArguments: ["--version"],
            overrideStore: overrideStore,
            identity: nil,
            loginShellPath: loginShellPath,
            packageManagerDirectories: packageManagerDirectories,
            includeOverrides: false
        )
        if let native, supportsNativeLanguageServer(version: native.version) {
            return native
        }

        return try legacyResult.get()
    }

    static func supportsNativeLanguageServer(version: String?) -> Bool {
        guard let majorComponent = version?
            .split(whereSeparator: { !$0.isNumber })
            .first(where: { !$0.isEmpty }),
              let majorVersion = Int(majorComponent) else {
            return false
        }
        return majorVersion >= 7
    }
}
