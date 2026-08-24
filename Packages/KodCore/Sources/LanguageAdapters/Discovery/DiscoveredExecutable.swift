import Foundation

/// The deterministic precedence tier a resolved language-server
/// executable came from (SPEC 6.5). Kod always displays this alongside
/// the executable's absolute path, version, and arguments before first
/// launch, so users can tell exactly why a given binary was chosen.
public enum ExecutableDiscoverySource:
    String,
    Codable,
    Sendable,
    Equatable,
    CaseIterable
{
    case workspaceOverride
    case registeredProfile
    case globalOverride
    case languageSpecificTool
    case loginShellPath
    case packageManagerLocation
    public var displayName: String {
        switch self {
        case .workspaceOverride:
            return "Per-workspace override"
        case .registeredProfile:
            return "Registered language profile"
        case .globalOverride:
            return "Global override"
        case .languageSpecificTool:
            return "Language-specific discovery"
        case .loginShellPath:
            return "Login shell PATH"
        case .packageManagerLocation:
            return "Common package-manager location"
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
    public let environment: [String: String]?
    public let version: String?
    public let source: ExecutableDiscoverySource

    public init(
        url: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        version: String?,
        source: ExecutableDiscoverySource
    ) {
        self.url = url
        self.arguments = arguments
        self.environment = environment
        self.version = version
        self.source = source
    }
}

public enum LanguageServerDiscoveryError: Error, Equatable, Sendable {
    case profileHasNoLanguageServer(String)
    /// No executable was found for `languageName` at any precedence
    /// tier through `attemptedSources`.
    case notFound(languageName: String, attemptedSources: [ExecutableDiscoverySource])
    /// An explicit override (workspace or global) names a path that is
    /// not an executable file — reported distinctly from a plain "not
    /// found" since the user configured this path themselves.
    case overrideNotExecutable(URL, source: ExecutableDiscoverySource)
}

extension LanguageServerDiscoveryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .profileHasNoLanguageServer(let profile):
            return "Language profile \(profile) does not configure a language server."
        case .notFound(let languageName, let attemptedSources):
            let sources = attemptedSources.map(\.displayName).joined(separator: ", ")
            return "No \(languageName) executable was found. Checked: \(sources). Install a compatible server or configure a language-server override."
        case .overrideNotExecutable(let url, let source):
            return "The \(source.displayName.lowercased()) at \(url.path) is not executable."
        }
    }
}
