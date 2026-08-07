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

        let process = Process()
        process.executableURL = shellURL
        // Fixed, constant command text Kod authors and ships — never
        // interpolated from any external source.
        process.arguments = ["-l", "-i", "-c", "printf '%s%s%s' '\(beginMarker)' \"$PATH\" '\(endMarker)'"]
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // A dedicated `Thread` (not `DispatchQueue.global()`) races the
        // wait against `timeout`: the login shell can legitimately be
        // slow (network-mounted home directories, heavy rc-file
        // plugins), so this keeps the timeout safety net, but avoids
        // relying on Swift's shared concurrent dispatch queue, which
        // can itself be saturated under heavy parallel process/test
        // load and make a fixed timeout here flaky rather than
        // protective.
        let didFinish = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            process.waitUntilExit()
            didFinish.signal()
        }
        guard didFinish.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        guard let beginRange = output.range(of: beginMarker),
              let endRange = output.range(of: endMarker, range: beginRange.upperBound..<output.endIndex) else {
            return nil
        }
        let path = String(output[beginRange.upperBound..<endRange.lowerBound])
        return path.isEmpty ? nil : path
    }
}
