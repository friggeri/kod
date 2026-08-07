import Foundation
import LanguageClient
import WorkspaceCore

/// Picks a `LanguageAdapter` for an open file purely by its (lowercased)
/// path extension — never by reading any repository-provided project
/// configuration. One `LanguageWorkspaceService` is shared per
/// (workspace, adapter) pair by callers (SPEC 6.2: "one server process
/// shared per workspace, language adapter, and compatible
/// configuration").
public enum LanguageAdapterRegistry {
    /// Every adapter Kod ships, in the fixed order checked to resolve a
    /// file extension. Order does not matter today (no adapter's
    /// extensions overlap with another's), but is fixed for
    /// determinism.
    public static let all: [any LanguageAdapter.Type] = [
        SwiftAdapter.self,
        TypeScriptLanguageAdapter.self,
        HTMLLanguageAdapter.self,
        CSSLanguageAdapter.self,
        PythonLanguageAdapter.self,
        RustLanguageAdapter.self
    ]

    public static func adapter(forURL url: URL) -> (any LanguageAdapter.Type)? {
        let fileExtension = url.pathExtension.lowercased()
        guard !fileExtension.isEmpty else {
            return nil
        }
        return all.first { $0.fileExtensions.contains(fileExtension) }
    }

    /// Builds the generic engine for `adapter`, wiring its discovery
    /// through the shared `LanguageServerDiscoveryEngine` precedence
    /// (SPEC 6.5) and its declared semantic-token legend and
    /// per-extension `languageId` mapping into
    /// `LanguageWorkspaceService.Configuration`.
    ///
    /// `Dependencies.discoverExecutable` only returns a `URL` (matching
    /// `SwiftWorkspaceLanguageService`'s Phase 6 shape), but discovery
    /// also resolves fixed launch *arguments* (e.g. `--stdio`). A
    /// `DiscoveredArgumentsBox` local to this one service instance
    /// bridges the two: `discoverExecutable` records the arguments it
    /// just resolved, and `connectionFactory` (always called
    /// immediately afterwards, same start/restart cycle) reads them
    /// back before constructing the connection.
    public static func makeService(
        for adapter: any LanguageAdapter.Type,
        identity: WorkspaceIdentity,
        trustStore: WorkspaceTrustStore,
        overrideStore: LanguageServerOverrideStore,
        onStateChange: @escaping @Sendable (LanguageServerState) -> Void = { _ in },
        onDiagnostics: @escaping @Sendable (URL, [Diagnostic]) -> Void = { _, _ in }
    ) -> LanguageWorkspaceService {
        let discoveredArguments = DiscoveredArgumentsBox()
        return LanguageWorkspaceService(
            identity: identity,
            trustStore: trustStore,
            configuration: LanguageWorkspaceService.Configuration(
                languageId: adapter.languageKey,
                semanticTokenTypes: adapter.semanticTokenTypes,
                semanticTokenModifiers: adapter.semanticTokenModifiers
            ),
            dependencies: LanguageWorkspaceService.Dependencies(
                discoverExecutable: {
                    let discovered = try adapter.discover(overrideStore: overrideStore, identity: identity)
                    discoveredArguments.set(discovered.arguments)
                    return discovered.url
                },
                connectionFactory: { configuration, onStateChange, onNotification in
                    var configuration = configuration
                    configuration.arguments = discoveredArguments.get()
                    return LanguageServerConnection(
                        configuration: configuration,
                        onStateChange: onStateChange,
                        onNotification: onNotification
                    )
                }
            ),
            onStateChange: onStateChange,
            onDiagnostics: onDiagnostics
        )
    }
}

/// A single mutable slot, private to one `LanguageWorkspaceService`
/// instance's `Dependencies` closures — never shared across adapters or
/// workspaces (unlike a global/static cache, which would race across
/// concurrently-starting services for the same adapter).
private final class DiscoveredArgumentsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var arguments: [String] = []

    func set(_ newArguments: [String]) {
        lock.lock()
        arguments = newArguments
        lock.unlock()
    }

    func get() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return arguments
    }
}
