import Foundation

/// The deterministic precedence tier a resolved language-server
/// executable came from (SPEC 6.5). Kod always displays this alongside
/// the executable's absolute path, version, and arguments before first
/// launch, so users can tell exactly why a given binary was chosen.
public enum ExecutableDiscoverySource: String, Sendable, Equatable, CaseIterable {
    case workspaceOverride
    case globalOverride
    case languageSpecificTool
    case loginShellPath
    case packageManagerLocation
    /// Resolved by `ManagedInstallDiscoverySource` reading an active,
    /// already-verified-and-extracted `ManagedInstallController`
    /// install (SPEC 6.5's catalog/signature/rollback machinery,
    /// implemented in the `ManagedLanguageServers` target).
    case managedInstall

    public var displayName: String {
        switch self {
        case .workspaceOverride:
            return "Per-workspace override"
        case .globalOverride:
            return "Global override"
        case .languageSpecificTool:
            return "Language-specific discovery"
        case .loginShellPath:
            return "Login shell PATH"
        case .packageManagerLocation:
            return "Common package-manager location"
        case .managedInstall:
            return "Kod-managed install"
        }
    }
}

/// A fully-resolved language-server executable: an absolute path, its
/// fixed launch arguments, a best-effort version string (from running
/// the executable itself with a fixed `--version`-style argument, never
/// a shell string), and which precedence tier produced it. Kod displays
/// all four fields before first launch (SPEC 6.5).
public struct DiscoveredExecutable: Sendable, Equatable {
    public let url: URL
    public let arguments: [String]
    public let version: String?
    public let source: ExecutableDiscoverySource

    public init(url: URL, arguments: [String], version: String?, source: ExecutableDiscoverySource) {
        self.url = url
        self.arguments = arguments
        self.version = version
        self.source = source
    }
}

public enum LanguageServerDiscoveryError: Error, Equatable, Sendable {
    /// No executable was found for `languageName` at any precedence
    /// tier through `attemptedSources`.
    case notFound(languageName: String, attemptedSources: [ExecutableDiscoverySource])
    /// An explicit override (workspace or global) names a path that is
    /// not an executable file — reported distinctly from a plain "not
    /// found" since the user configured this path themselves.
    case overrideNotExecutable(URL, source: ExecutableDiscoverySource)
}
