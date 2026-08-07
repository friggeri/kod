import Foundation
import WorkspaceCore

/// Resolves one language server's absolute executable, arguments, and
/// version, walking SPEC 6.5's deterministic precedence exactly:
///
/// 1. Explicit per-workspace override (outside the repository).
/// 2. Explicit global override.
/// 3. Language-specific system discovery (e.g. `xcrun`, `rustup`).
/// 4. Captured login-shell `PATH`.
/// 5. Common package-manager install locations.
/// 6. Kod-managed installation (Phase 8; not resolved here).
///
/// Every step here only ever launches a fixed, absolute executable with
/// a fixed argument array, or reads a fixed list of absolute directory
/// paths — never a shell string and never anything sourced from the
/// repository being viewed.
public enum LanguageServerDiscoveryEngine {
    /// Directories commonly used by package managers/toolchains on
    /// macOS, checked (in this fixed order) for a language server binary
    /// by name once the login-shell `PATH` capture has also been tried.
    /// This list exists precisely because some tools (Kod itself, run
    /// from Xcode/Finder) may not inherit even the login shell's `PATH`
    /// in every launch context, or a user's shell config may not
    /// `export` it the way Kod's capture expects.
    public static func defaultPackageManagerDirectories() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            home.appendingPathComponent(".cargo/bin"),
            home.appendingPathComponent(".local/bin"),
            home.appendingPathComponent(".volta/bin"),
            home.appendingPathComponent("Library/pnpm/bin"),
            home.appendingPathComponent("Library/pnpm"),
            home.appendingPathComponent(".bun/bin")
        ]
    }

    /// Resolves one language server. `languageSpecificProbe` should
    /// implement tier 3 (e.g. `xcrun --find sourcekit-lsp`, `rustup
    /// which rust-analyzer`) and return `nil` (not throw) when that
    /// specific tool genuinely reports nothing, so discovery falls
    /// through to the remaining tiers rather than failing outright.
    public static func resolve(
        languageKey: String,
        languageDisplayName: String,
        executableNames: [String],
        arguments: [String],
        versionArguments: [String]? = ["--version"],
        languageSpecificProbe: (@Sendable () -> URL?)? = nil,
        managedInstallProbe: (@Sendable () -> DiscoveredExecutable?)? = nil,
        overrideStore: LanguageServerOverrideStore,
        identity: WorkspaceIdentity?,
        loginShellPath: @Sendable () -> String? = { LoginShellPathCapture.capture() },
        packageManagerDirectories: [URL] = LanguageServerDiscoveryEngine.defaultPackageManagerDirectories(),
        includeOverrides: Bool = true
    ) throws -> DiscoveredExecutable {
        var attempted: [ExecutableDiscoverySource] = []

        if includeOverrides {
            if let identity {
                attempted.append(.workspaceOverride)
                if let override = overrideStore.workspaceOverride(languageKey: languageKey, identity: identity) {
                    return try makeResult(
                        url: override.url,
                        arguments: override.arguments,
                        source: .workspaceOverride,
                        versionArguments: versionArguments
                    )
                }
            }

            attempted.append(.globalOverride)
            if let override = overrideStore.globalOverride(languageKey: languageKey) {
                return try makeResult(
                    url: override.url,
                    arguments: override.arguments,
                    source: .globalOverride,
                    versionArguments: versionArguments
                )
            }
        }

        if let languageSpecificProbe {
            attempted.append(.languageSpecificTool)
            if let url = languageSpecificProbe(), FileManager.default.isExecutableFile(atPath: url.path) {
                return try makeResult(url: url, arguments: arguments, source: .languageSpecificTool, versionArguments: versionArguments)
            }
        }

        attempted.append(.loginShellPath)
        if let path = loginShellPath(), let url = firstExecutable(named: executableNames, inPathList: path) {
            return try makeResult(url: url, arguments: arguments, source: .loginShellPath, versionArguments: versionArguments)
        }

        attempted.append(.packageManagerLocation)
        for directory in packageManagerDirectories {
            for name in executableNames {
                let candidate = directory.appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return try makeResult(url: candidate, arguments: arguments, source: .packageManagerLocation, versionArguments: versionArguments)
                }
            }
        }

        if let managedInstallProbe {
            attempted.append(.managedInstall)
            // A managed-install result is already fully resolved (its
            // own version string, arguments, and `.managedInstall`
            // source tag come straight from `InstalledServerRecord`/
            // `ManagedInstallDiscoverySource`) — unlike every other
            // tier above, it is never re-run through `makeResult`,
            // since a managed install's on-disk executable was already
            // digest-verified and permission-set at install time, not
            // discovered by probing an arbitrary pre-existing path.
            if let discovered = managedInstallProbe() {
                return discovered
            }
        }

        throw LanguageServerDiscoveryError.notFound(languageName: languageDisplayName, attemptedSources: attempted)
    }

    private static func makeResult(
        url: URL,
        arguments: [String],
        source: ExecutableDiscoverySource,
        versionArguments: [String]?
    ) throws -> DiscoveredExecutable {
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw LanguageServerDiscoveryError.overrideNotExecutable(url, source: source)
        }
        let version = versionArguments.flatMap { detectVersion(executableURL: url, arguments: $0) }
        return DiscoveredExecutable(url: url, arguments: arguments, version: version, source: source)
    }

    private static func firstExecutable(named names: [String], inPathList pathList: String) -> URL? {
        let directories = pathList.split(separator: ":").map(String.init)
        for directory in directories {
            for name in names {
                let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// Best-effort version detection: launches the already-resolved,
    /// absolute executable itself with a fixed argument array (never a
    /// shell string). Failure is not fatal — discovery still succeeds
    /// with `version == nil`, since Kod never treats "couldn't parse a
    /// version string" as equivalent to "server not found."
    private static func detectVersion(executableURL: URL, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // A direct, synchronous `waitUntilExit()` rather than a
        // `DispatchQueue.global()` + semaphore timeout race: this
        // function already only ever runs on a background thread
        // dedicated to one discovery attempt (never Swift concurrency's
        // cooperative pool), and under heavy parallel test/process load
        // the global concurrent queue can itself be saturated, making a
        // fixed timeout here flaky rather than protective. A `--version`
        // invocation of a real, well-behaved CLI tool returns near
        // instantly; if a misbehaving one ever hung, that would only
        // block this one discovery attempt, not any per-request path.
        process.waitUntilExit()

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }
}
