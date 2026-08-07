import Foundation

public enum GitExecutableLocatorError: Error, Equatable, Sendable {
    case notFound(candidates: [String])
}

/// Locates Git's absolute executable path from a fixed, ordered list of
/// well-known install locations — never a `PATH` scan, a shell command
/// (`which git`, `command -v git`), or a Git alias. SPEC 9.2: "Kod invokes
/// an absolute Git executable with fixed argument arrays, never shell
/// strings or aliases."
///
/// Ordered like `LanguageServerDiscoveryEngine.defaultPackageManagerDirectories()`:
/// Homebrew's Apple-silicon prefix first, its Intel prefix second, then
/// Apple's own Xcode Command Line Tools shim at `/usr/bin/git` last (it is
/// always present once Xcode/CLT is installed, but a Homebrew-managed real
/// build is preferred when both exist since it never triggers a
/// first-launch CLT installation prompt).
public enum GitExecutableLocator {
    public static func defaultCandidateURLs() -> [URL] {
        [
            URL(fileURLWithPath: "/opt/homebrew/bin/git"),
            URL(fileURLWithPath: "/usr/local/bin/git"),
            URL(fileURLWithPath: "/usr/bin/git")
        ]
    }

    /// Returns the first candidate that resolves (through any symlink) to
    /// an executable regular file. Never falls back to searching `PATH` or
    /// invoking a shell.
    public static func resolve(
        candidates: [URL] = GitExecutableLocator.defaultCandidateURLs(),
        fileManager: FileManager = .default
    ) throws -> URL {
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw GitExecutableLocatorError.notFound(candidates: candidates.map(\.path))
    }
}
