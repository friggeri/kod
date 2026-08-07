import Foundation

/// One architecture-specific downloadable artifact for a managed
/// server (or private runtime) version. Every field the installer needs
/// to fetch, verify, extract, and validate the artifact without
/// consulting anything else lives here (SPEC 6.5: signed catalog,
/// digest verification, expected layout, executable path).
public struct ManagedServerArtifact: Codable, Sendable, Equatable {
    /// Which Mac architecture this artifact is built for. Kept inline
    /// on the artifact itself (rather than as a dictionary key) so the
    /// catalog's JSON serializes as a plain, order-stable array — a
    /// `[Architecture: Artifact]` dictionary round-trips correctly but
    /// `JSONEncoder` has no native keyed-object representation for a
    /// non-`String`/`Int` dictionary key and falls back to an
    /// alternating flat array, which is neither human-reviewable nor
    /// reproducible across generator runs (`Dictionary` iteration order
    /// is unspecified).
    public let architecture: ManagedInstallArchitecture

    /// HTTPS-only download location. `ManagedInstallController` refuses
    /// any other scheme before ever opening a connection.
    public let url: URL

    /// Lowercase hex-encoded SHA-256 of the exact bytes at `url`,
    /// verified before extraction ever begins.
    public let sha256Hex: String

    /// A hard upper bound on the artifact's compressed download size in
    /// bytes. `BoundedDownloader` aborts the moment more bytes than this
    /// arrive, before they are ever written to the staging file.
    public let maxDownloadBytes: Int

    /// A hard upper bound on the archive's total *decompressed* bytes
    /// across every entry, enforced while streaming decompression
    /// (never after fully inflating), which is exactly what stops a
    /// decompression-bomb artifact regardless of how small it is
    /// compressed.
    public let maxDecompressedBytes: Int

    public let archiveFormat: ManagedArchiveFormat

    /// The exact, sorted, catalog-declared set of relative paths
    /// (POSIX-style, forward-slash separated, no leading `/`) the
    /// archive must contain — nothing more, nothing less.
    /// `SecureArchiveExtractor` rejects the archive if the extracted
    /// entry set differs from this in any way, which is what catches an
    /// "unexpected executable" smuggled alongside the real one.
    public let expectedRelativePaths: [String]

    /// Relative path (must be a member of `expectedRelativePaths`) to
    /// the executable `ManagedInstallController` launches. Given the
    /// executable bit exactly here after extraction; every other
    /// extracted file is written non-executable.
    public let executableRelativePath: String

    public init(
        architecture: ManagedInstallArchitecture,
        url: URL,
        sha256Hex: String,
        maxDownloadBytes: Int,
        maxDecompressedBytes: Int,
        archiveFormat: ManagedArchiveFormat,
        expectedRelativePaths: [String],
        executableRelativePath: String
    ) {
        self.architecture = architecture
        self.url = url
        self.sha256Hex = sha256Hex.lowercased()
        self.maxDownloadBytes = maxDownloadBytes
        self.maxDecompressedBytes = maxDecompressedBytes
        self.archiveFormat = archiveFormat
        self.expectedRelativePaths = expectedRelativePaths
        self.executableRelativePath = executableRelativePath
    }
}

/// A managed server that requires its own pinned, verified private
/// runtime rather than any interpreter already on the Mac (SPEC 6.5:
/// "Include a verified private runtime when a server requires one").
/// Node-based servers (`typescript-language-server`,
/// `vscode-html-language-server`, `vscode-css-language-server`) all need
/// this; `rust-analyzer` and SourceKit-LSP do not.
public struct ManagedPrivateRuntimeRequirement: Codable, Sendable, Equatable {
    /// The `serverID` of a *separate* catalog entry (typically
    /// `"node-runtime"`) whose active install provides the runtime
    /// executable, installed and versioned independently of the server
    /// that depends on it.
    public let runtimeServerID: String

    /// Relative path, within the runtime's own install directory, to
    /// the interpreter executable (e.g. `"bin/node"`).
    public let runtimeExecutableRelativePath: String

    public init(runtimeServerID: String, runtimeExecutableRelativePath: String) {
        self.runtimeServerID = runtimeServerID
        self.runtimeExecutableRelativePath = runtimeExecutableRelativePath
    }
}
