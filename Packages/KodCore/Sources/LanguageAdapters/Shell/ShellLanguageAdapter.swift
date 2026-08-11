import Foundation
import LanguageClient
import SyntaxCore
import WorkspaceCore

public enum ShellLanguageAdapter: LanguageAdapter {
    public static let languageKey = "shellscript"
    public static let displayName = "Shell (bash-language-server)"
    public static let executableProfiles = [
        LanguageServerExecutableProfile(executableNames: ["bash-language-server"], arguments: ["start"])
    ]
    public static let semanticTokenTypes = StandardSemanticTokenLegend.tokenTypes
    public static let semanticTokenModifiers = StandardSemanticTokenLegend.tokenModifiers
    public static let syntaxLanguages: Set<SyntaxLanguage> = [.shell]
    public static let supportNotes: [LanguageServerSupportNote] = [
        .shellCheckOptional
    ]
    public static let workspaceConfiguration = configuration(
        shellCheckURL: nil
    )

    public static func lspLanguageId(forExtension fileExtension: String) -> String? {
        fileExtensions.contains(fileExtension.lowercased()) ? "shellscript" : nil
    }

    public static func lspLanguageId(forURL url: URL) -> String? {
        supports(url: url) ? "shellscript" : nil
    }

    public static func configuration(
        shellCheckURL: URL?
    ) -> [String: JSONValue] {
        [
            "bashIde": .object([
                "shellcheckPath": .string(shellCheckURL?.path ?? ""),
                "shfmt": .object(["path": .string("")])
            ])
        ]
    }

    public static func discoverShellCheck(
        loginShellPath: String? = LoginShellPathCapture.capture(),
        packageManagerDirectories: [URL] = LanguageServerDiscoveryEngine
            .defaultPackageManagerDirectories()
    ) -> URL? {
        var directories: [URL] = []
        if let loginShellPath {
            directories.append(contentsOf: loginShellPath
                .split(separator: ":")
                .compactMap { path -> URL? in
                    let value = String(path)
                    guard value.hasPrefix("/") else {
                        return nil
                    }
                    return URL(fileURLWithPath: value, isDirectory: true)
                })
        }
        directories.append(contentsOf: packageManagerDirectories)

        for directory in directories {
            let candidate = directory
                .standardizedFileURL
                .appendingPathComponent("shellcheck")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
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
