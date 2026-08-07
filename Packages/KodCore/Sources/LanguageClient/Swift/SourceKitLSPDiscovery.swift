import Foundation

public enum SourceKitLSPDiscoveryError: Error, Equatable, Sendable {
    case xcrunNotFound
    case xcrunFailed(exitCode: Int32, message: String)
    case executableNotReported
    case executableMissing(String)
}

/// Locates SourceKit-LSP's absolute executable path through `xcrun`'s
/// active-toolchain lookup — never by evaluating a shell string, reading
/// `PATH`, or trusting a repository-provided path (SPEC 6.5, 13.2).
/// `xcrun` itself is launched with a fixed argument array
/// (`["--find", "sourcekit-lsp"]`) at its own well-known absolute
/// location; nothing here is interpolated from untrusted input.
public enum SourceKitLSPDiscovery {
    /// The one place `/usr/bin/xcrun`'s absolute path is hard-coded. This
    /// is Apple's own stable, well-known location — not a `PATH` lookup.
    public static let xcrunURL = URL(fileURLWithPath: "/usr/bin/xcrun")

    public static func discoverExecutableURL(
        xcrunURL: URL = SourceKitLSPDiscovery.xcrunURL
    ) throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: xcrunURL.path) else {
            throw SourceKitLSPDiscoveryError.xcrunNotFound
        }

        let process = Process()
        process.executableURL = xcrunURL
        process.arguments = ["--find", "sourcekit-lsp"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: stderrData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SourceKitLSPDiscoveryError.xcrunFailed(exitCode: process.terminationStatus, message: message)
        }

        let path = String(decoding: stdoutData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw SourceKitLSPDiscoveryError.executableNotReported
        }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw SourceKitLSPDiscoveryError.executableMissing(path)
        }
        return URL(fileURLWithPath: path)
    }
}
