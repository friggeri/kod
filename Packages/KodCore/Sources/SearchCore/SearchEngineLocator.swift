import Foundation

/// The two Apple-silicon/Intel architectures Kod bundles a pinned `rg`
/// binary for. See `Scripts/vendor-ripgrep` for how these are produced.
public enum SearchEngineArchitecture: String, Equatable, Sendable {
    case aarch64 = "aarch64-apple-darwin"
    case x86_64 = "x86_64-apple-darwin"

    /// The architecture of the machine currently running Kod, or `nil` on
    /// an architecture Kod does not bundle an engine for (there is no
    /// silent fallback: callers must surface `SearchEngineError` instead).
    public static var current: SearchEngineArchitecture? {
        #if arch(arm64)
        return .aarch64
        #elseif arch(x86_64)
        return .x86_64
        #else
        return nil
        #endif
    }
}

public enum SearchEngineError: Error, Equatable, Sendable {
    /// The running machine's CPU architecture has no bundled engine.
    case unsupportedArchitecture(String)
    /// The architecture is supported, but the expected bundled executable
    /// resource is missing (a packaging defect, not a user-facing state).
    case bundledExecutableMissing(SearchEngineArchitecture)
}

/// Locates Kod's bundled, version-pinned ripgrep-compatible search engine.
///
/// The executable is never referenced by a relative path or discovered via
/// `PATH`/`env` lookup: it is a resource copied into `SearchCore`'s own
/// resource bundle (and, once linked into the app, into the app bundle) at
/// build time by `Scripts/vendor-ripgrep/vendor.sh`, and is always launched
/// through the absolute `URL` this locator returns.
public enum SearchEngineLocator {
    public static func bundledExecutableURL(bundle: Bundle? = nil) throws -> URL {
        let bundle = bundle ?? Bundle.module
        guard let architecture = SearchEngineArchitecture.current else {
            throw SearchEngineError.unsupportedArchitecture(currentArchitectureDescription())
        }
        guard let url = bundle.url(
            forResource: "rg",
            withExtension: nil,
            subdirectory: "ripgrep/\(architecture.rawValue)"
        ) else {
            throw SearchEngineError.bundledExecutableMissing(architecture)
        }
        return url
    }

    private static func currentArchitectureDescription() -> String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #elseif arch(i386)
        "i386"
        #else
        "unknown"
        #endif
    }
}
