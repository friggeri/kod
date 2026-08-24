import Foundation

/// Captures the `PATH` the user's interactive login shell would report
/// (SPEC 6.5's "captured login-shell environment" discovery tier).
/// GUI apps on macOS are launched by `launchd` with a minimal `PATH` that
/// does not include entries a shell rc file adds (e.g. Homebrew, nvm,
/// rustup, pyenv). This runs the user's own configured shell
/// (`$SHELL`, falling back to `/bin/zsh`) as a login shell with a single
/// fixed, Kod-authored command string — never a shell string derived
/// from the repository, a server, or any other untrusted input — purely
/// to read back one environment variable.
public enum LoginShellPathCapture {
    /// A unique-enough delimiter so any shell startup noise (MOTD,
    /// version-manager banners, etc.) printed before/after `$PATH` on
    /// stdout can be reliably stripped away.
    private static let beginMarker = "__KOD_LOGIN_SHELL_PATH_BEGIN__"
    private static let endMarker = "__KOD_LOGIN_SHELL_PATH_END__"

    public static func capture(
        shellURL: URL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"),
        timeout: TimeInterval = 5
    ) -> String? {
        guard FileManager.default.isExecutableFile(atPath: shellURL.path) else {
            return nil
        }

        guard let result = BoundedProcessProbe.run(
            executableURL: shellURL,
            arguments: [
                "-l",
                "-i",
                "-c",
                "printf '%s%s%s' '\(beginMarker)' \"$PATH\" '\(endMarker)'"
            ],
            timeout: timeout
        ), result.exitStatus == 0 else {
            return nil
        }
        let output = String(decoding: result.output, as: UTF8.self)
        guard let beginRange = output.range(of: beginMarker),
              let endRange = output.range(of: endMarker, range: beginRange.upperBound..<output.endIndex) else {
            return nil
        }
        let path = String(output[beginRange.upperBound..<endRange.lowerBound])
        return path.isEmpty ? nil : path
    }
}
