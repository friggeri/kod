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
            home.appendingPathComponent("go/bin"),
            home.appendingPathComponent(".local/bin"),
            home.appendingPathComponent(".volta/bin"),
            home.appendingPathComponent("Library/pnpm/bin"),
            home.appendingPathComponent("Library/pnpm"),
            home.appendingPathComponent(".bun/bin")
        ]
    }

    public static func resolve(
        languageKey: String,
        languageDisplayName: String,
        profile: LanguageServerExecutableProfile,
        languageSpecificProbe: (@Sendable () -> URL?)? = nil,
        overrideStore: LanguageServerOverrideStore,
        identity: WorkspaceIdentity?,
        loginShellPath: @Sendable () -> String? = {
            LoginShellPathCapture.capture()
        },
        packageManagerDirectories: [URL] = LanguageServerDiscoveryEngine
            .defaultPackageManagerDirectories(),
        includeOverrides: Bool = true
    ) throws -> DiscoveredExecutable {
        try resolve(
            languageKey: languageKey,
            languageDisplayName: languageDisplayName,
            executableNames: profile.executableNames.sorted(),
            arguments: profile.arguments,
            versionArguments: profile.versionArguments,
            languageSpecificProbe: languageSpecificProbe,
            overrideStore: overrideStore,
            identity: identity,
            loginShellPath: loginShellPath,
            packageManagerDirectories: packageManagerDirectories,
            includeOverrides: includeOverrides
        )
    }

    /// Resolves a value-based language profile using its ordered candidates
    /// and constrained discovery strategies. A legacy workspace override
    /// remains the highest-precedence scope; the profile's explicitly
    /// registered executable then precedes the one-time-migrated legacy global
    /// override and all auto-detection.
    public static func resolve(
        profile: LanguageProfile,
        overrideStore: LanguageServerOverrideStore,
        identity: WorkspaceIdentity?,
        loginShellPath: @Sendable () -> String? = {
            LoginShellPathCapture.capture()
        },
        packageManagerDirectories: [URL] = LanguageServerDiscoveryEngine
            .defaultPackageManagerDirectories(),
        xcrunProbe: (@Sendable (String) -> URL?)? = nil,
        rustupProbe: (@Sendable (String) -> URL?)? = nil
    ) throws -> DiscoveredExecutable {
        let profile = try profile.validated()
        guard profile.isEnabled else {
            throw LanguageServerDiscoveryError.profileDisabled(
                profile.displayName
            )
        }
        guard let configuration = profile.languageServer else {
            throw LanguageServerDiscoveryError.profileHasNoLanguageServer(
                profile.displayName
            )
        }
        let xcrunProbe = xcrunProbe ?? { probeXcrun(tool: $0) }
        let rustupProbe = rustupProbe ?? { probeRustup(component: $0) }

        func versionArguments(for url: URL) -> [String]? {
            configuration.executableCandidates.first {
                $0.executableNames.contains(url.lastPathComponent)
            }?.versionArguments
        }

        if let identity,
           let override = overrideStore.workspaceOverride(
               languageKey: profile.identifier,
               identity: identity
           ) {
            return try makeResult(
                url: override.url,
                arguments: override.arguments,
                source: .workspaceOverride,
                versionArguments: versionArguments(for: override.url)
            )
        }

        if let selected = configuration.selectedExecutable {
            return try makeResult(
                url: selected.url,
                arguments: selected.arguments,
                source: .registeredProfile,
                versionArguments: versionArguments(for: selected.url)
            )
        }

        if let override = overrideStore.globalOverride(
            languageKey: profile.identifier
        ) {
            return try makeResult(
                url: override.url,
                arguments: override.arguments,
                source: .globalOverride,
                versionArguments: versionArguments(for: override.url)
            )
        }

        var attempted: [ExecutableDiscoverySource] = [
            .workspaceOverride,
            .registeredProfile,
            .globalOverride
        ]
        let capturedPath = loginShellPath()
        for candidate in configuration.executableCandidates {
            for strategy in candidate.discoveryStrategies {
                let resolved: (URL, ExecutableDiscoverySource)?
                switch strategy {
                case .xcrun(let tool):
                    appendUnique(.languageSpecificTool, to: &attempted)
                    resolved = xcrunProbe(tool).map {
                        ($0, .languageSpecificTool)
                    }
                case .rustup(let component):
                    appendUnique(.languageSpecificTool, to: &attempted)
                    resolved = rustupProbe(component).map {
                        ($0, .languageSpecificTool)
                    }
                case .path:
                    appendUnique(.loginShellPath, to: &attempted)
                    resolved = capturedPath.flatMap {
                        firstExecutable(
                            named: candidate.executableNames,
                            inPathList: $0
                        )
                    }.map { ($0, .loginShellPath) }
                case .packageManagerLocations:
                    appendUnique(.packageManagerLocation, to: &attempted)
                    resolved = firstExecutable(
                        named: candidate.executableNames,
                        inDirectories: packageManagerDirectories
                    ).map { ($0, .packageManagerLocation) }
                }
                guard let (url, source) = resolved else {
                    continue
                }
                let result = try makeResult(
                    url: url,
                    arguments: candidate.arguments,
                    source: source,
                    versionArguments: candidate.versionArguments
                )
                if let minimumMajorVersion = candidate.minimumMajorVersion,
                   !supports(
                       minimumMajorVersion: minimumMajorVersion,
                       version: result.version
                   ) {
                    continue
                }
                return result
            }
        }
        throw LanguageServerDiscoveryError.notFound(
            languageName: profile.displayName,
            attemptedSources: attempted
        )
    }

    /// Resolves one legacy static adapter. `languageSpecificProbe` should
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

    private static func firstExecutable(
        named names: [String],
        inDirectories directories: [URL]
    ) -> URL? {
        for directory in directories {
            for name in names {
                let candidate = directory.appendingPathComponent(name)
                if FileManager.default.isExecutableFile(
                    atPath: candidate.path
                ) {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func appendUnique(
        _ source: ExecutableDiscoverySource,
        to sources: inout [ExecutableDiscoverySource]
    ) {
        if !sources.contains(source) {
            sources.append(source)
        }
    }

    private static func supports(
        minimumMajorVersion: Int,
        version: String?
    ) -> Bool {
        guard let majorComponent = version?
            .split(whereSeparator: { !$0.isNumber })
            .first(where: { !$0.isEmpty }),
              let majorVersion = Int(majorComponent) else {
            return false
        }
        return majorVersion >= minimumMajorVersion
    }

    private static func probeXcrun(tool: String) -> URL? {
        probeTool(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["--find", tool]
        )
    }

    private static func probeRustup(component: String) -> URL? {
        probeTool(
            executableURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cargo/bin/rustup"),
            arguments: ["which", component]
        )
    }

    private static func probeTool(
        executableURL: URL,
        arguments: [String]
    ) -> URL? {
        guard FileManager.default.isExecutableFile(
            atPath: executableURL.path
        ) else {
            return nil
        }
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
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }
        let path = String(
            decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return URL(fileURLWithPath: path)
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
