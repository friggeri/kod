import Foundation
import LanguageClient

/// The one specialization the shipped shell profile's
/// `.shellCheckOptional` support note needs: `bash-language-server` only
/// reports ShellCheck diagnostics when it is handed an absolute path to
/// a ShellCheck binary, and the path can only be known after discovery.
///
/// This helper deliberately owns no defaults of its own. It patches the
/// resolved path into the workspace configuration the profile already
/// declares (`DefaultLanguageProfiles.shell`), and never invents a
/// configuration section that the profile did not ship — so a profile
/// remains the single source of what is sent to the server.
public enum ShellCheckSupport {
    /// The optional companion binary this note is about. Discovery only
    /// ever reads directories and checks executability; it never runs
    /// the binary.
    public static let executableName = "shellcheck"

    private static let sectionKey = "bashIde"
    private static let pathKey = "shellcheckPath"

    /// Returns `configuration` with the ShellCheck path filled in, or
    /// unchanged when the profile does not declare the section this note
    /// applies to (e.g. a profile that lost its shipped configuration).
    public static func resolvedWorkspaceConfiguration(
        _ configuration: [String: JSONValue],
        shellCheckURL: URL?
    ) -> [String: JSONValue] {
        guard case .object(var section)? = configuration[sectionKey] else {
            return configuration
        }
        var configuration = configuration
        section[pathKey] = .string(shellCheckURL?.path ?? "")
        configuration[sectionKey] = .object(section)
        return configuration
    }

    /// Looks for ShellCheck on the captured login-shell `PATH` and then
    /// in the same fixed package-manager directories language-server
    /// discovery uses, returning an absolute executable path or `nil`.
    public static func discoverShellCheck(
        loginShellPath: String? = LoginShellPathCapture.capture(),
        packageManagerDirectories: [URL] = LanguageServerDiscoveryEngine
            .defaultPackageManagerDirectories()
    ) -> URL? {
        LanguageServerDiscoveryEngine.locateExecutable(
            named: executableName,
            loginShellPath: loginShellPath,
            packageManagerDirectories: packageManagerDirectories
        )
    }
}
