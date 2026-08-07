import Foundation
import WorkspaceCore

/// Rust adapter using `rust-analyzer`. Tries `rustup which rust-analyzer`
/// as the language-specific tier (SPEC 6.5 names `rustup` explicitly)
/// when a `rustup` binary is present at rustup's own standard install
/// location; falls through cleanly (not an error) when `rustup` doesn't
/// manage a `rust-analyzer` binary (e.g. a standalone install), letting
/// the login-shell `PATH`/package-manager-location tiers find it
/// instead.
public enum RustLanguageAdapter: LanguageAdapter {
    public static let languageKey = "rust"
    public static let displayName = "Rust (rust-analyzer)"
    public static let fileExtensions: Set<String> = ["rs"]
    public static let semanticTokenTypes = StandardSemanticTokenLegend.tokenTypes
    public static let semanticTokenModifiers = StandardSemanticTokenLegend.tokenModifiers

    public static func lspLanguageId(forExtension fileExtension: String) -> String? {
        fileExtension.lowercased() == "rs" ? "rust" : nil
    }

    public static func discover(
        overrideStore: LanguageServerOverrideStore,
        identity: WorkspaceIdentity?
    ) throws -> DiscoveredExecutable {
        try LanguageServerDiscoveryEngine.resolve(
            languageKey: languageKey,
            languageDisplayName: displayName,
            executableNames: ["rust-analyzer"],
            arguments: [],
            versionArguments: ["--version"],
            languageSpecificProbe: { probeRustupManagedAnalyzer() },
            managedInstallProbe: {
                ManagedInstallDiscoverySource.discover(serverID: "rust-analyzer", controller: ManagedInstallDiscoverySource.shared)
            },
            overrideStore: overrideStore,
            identity: identity
        )
    }

    /// Runs `rustup which rust-analyzer` — a fixed absolute executable
    /// (rustup's own standard install location) with a fixed argument
    /// array, never a shell string — and returns the reported path only
    /// if it is genuinely executable. Any failure (rustup absent,
    /// `rust-analyzer` not a rustup-managed component) yields `nil`
    /// rather than throwing, so discovery simply falls through to the
    /// next tier.
    private static func probeRustupManagedAnalyzer() -> URL? {
        let rustupURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cargo/bin/rustup")
        guard FileManager.default.isExecutableFile(atPath: rustupURL.path) else {
            return nil
        }
        let process = Process()
        process.executableURL = rustupURL
        process.arguments = ["which", "rust-analyzer"]
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }
}
