import Foundation

/// Locates the pinned, real test language server
/// executables provisioned by `Scripts/vendor-test-language-servers/setup.sh`
/// under `Packages/KodCore/.build/test-language-servers/` — used only by
/// `LanguageAdaptersTests`'s real integration tests, never by the Kod
/// app itself. Each accessor throws `XCTSkip` with a message that names
/// the exact missing external executable and the setup script to run,
/// rather than silently skipping or (worse) faking success.
enum PinnedTestLanguageServerLocator {
    private static var repositoryRoot: URL {
        // Tests/LanguageAdaptersTests/PinnedTestLanguageServerLocator.swift
        // -> Tests/LanguageAdaptersTests -> Tests -> KodCore -> Packages -> repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var installDirectory: URL {
        repositoryRoot.appendingPathComponent("Packages/KodCore/.build/test-language-servers")
    }

    private static func requireExecutable(at url: URL, setupHint: String) throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw PinnedExecutableMissing(path: url.path, setupHint: setupHint)
        }
        return url
    }

    static func typescriptLanguageServer() throws -> URL {
        try requireExecutable(
            at: installDirectory.appendingPathComponent("node_modules/.bin/typescript-language-server"),
            setupHint: "Run Scripts/vendor-test-language-servers/setup.sh to install the pinned typescript-language-server."
        )
    }

    static func htmlLanguageServer() throws -> URL {
        try requireExecutable(
            at: installDirectory.appendingPathComponent("node_modules/.bin/vscode-html-language-server"),
            setupHint: "Run Scripts/vendor-test-language-servers/setup.sh to install the pinned vscode-html-language-server."
        )
    }

    static func cssLanguageServer() throws -> URL {
        try requireExecutable(
            at: installDirectory.appendingPathComponent("node_modules/.bin/vscode-css-language-server"),
            setupHint: "Run Scripts/vendor-test-language-servers/setup.sh to install the pinned vscode-css-language-server."
        )
    }

    static func jsonLanguageServer() throws -> URL {
        try requireExecutable(
            at: installDirectory.appendingPathComponent(
                "node_modules/.bin/vscode-json-language-server"
            ),
            setupHint: "Run Scripts/vendor-test-language-servers/setup.sh to install the pinned vscode-json-language-server."
        )
    }

    static func bashLanguageServer() throws -> URL {
        try requireExecutable(
            at: installDirectory.appendingPathComponent(
                "node_modules/.bin/bash-language-server"
            ),
            setupHint: "Run Scripts/vendor-test-language-servers/setup.sh to install the pinned bash-language-server."
        )
    }

    static func yamlLanguageServer() throws -> URL {
        try requireExecutable(
            at: installDirectory.appendingPathComponent(
                "node_modules/.bin/yaml-language-server"
            ),
            setupHint: "Run Scripts/vendor-test-language-servers/setup.sh to install the pinned yaml-language-server."
        )
    }

    static func marksman() throws -> URL {
        try requireExecutable(
            at: installDirectory.appendingPathComponent("native/marksman"),
            setupHint: "Run Scripts/vendor-test-language-servers/setup.sh to install pinned Marksman."
        )
    }

    static func tombi() throws -> URL {
        try requireExecutable(
            at: installDirectory.appendingPathComponent("native/tombi"),
            setupHint: "Run Scripts/vendor-test-language-servers/setup.sh to install pinned Tombi."
        )
    }

    static func pyrightLangserver() throws -> URL {
        try requireExecutable(
            at: installDirectory.appendingPathComponent("pyright-venv/bin/pyright-langserver"),
            setupHint: "Run Scripts/vendor-test-language-servers/setup.sh to install the pinned pyright."
        )
    }

    /// Rust is discovered live through `rustup which rust-analyzer`
    /// (SPEC 6.5's "language-specific system discovery" tier) rather
    /// than a fixed install path, since `Scripts/vendor-test-language-servers/setup.sh`
    /// installs it as a real rustup component, not a copied binary.
    static func rustAnalyzerViaRustup() throws -> URL {
        let rustupURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cargo/bin/rustup")
        guard FileManager.default.isExecutableFile(atPath: rustupURL.path) else {
            throw PinnedExecutableMissing(
                path: rustupURL.path,
                setupHint: "rustup not found; install rustup, then run Scripts/vendor-test-language-servers/setup.sh."
            )
        }
        let process = Process()
        process.executableURL = rustupURL
        process.arguments = ["which", "rust-analyzer"]
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PinnedExecutableMissing(
                path: "rust-analyzer (via rustup)",
                setupHint: "Run Scripts/vendor-test-language-servers/setup.sh to install the pinned rust-analyzer rustup component."
            )
        }
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return try requireExecutable(
            at: URL(fileURLWithPath: path),
            setupHint: "Run Scripts/vendor-test-language-servers/setup.sh to install the pinned rust-analyzer rustup component."
        )
    }

    static func fixture(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(relativePath)
    }
}

struct PinnedExecutableMissing: Error, CustomStringConvertible {
    let path: String
    let setupHint: String

    var description: String {
        "Missing external executable at \(path). \(setupHint)"
    }
}
