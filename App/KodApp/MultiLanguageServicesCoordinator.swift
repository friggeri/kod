import CodeViewport
import DiagnosticsCore
import Foundation
import LanguageAdapters
import LanguageClient
import SourceModel
import WorkspaceCore

/// Owns one `LanguageWorkspaceService` per non-Swift `LanguageAdapter`
/// (TypeScript/JavaScript, HTML, CSS, Python, Rust) for one workspace,
/// mirroring `LanguageServicesCoordinator`'s Swift-specific role but
/// generically (SPEC 6.2: "one server process shared per workspace,
/// language adapter"). Swift itself continues to go through
/// `LanguageServicesCoordinator`/`SwiftWorkspaceLanguageService`
/// unchanged — routing Swift through this coordinator too would launch
/// a second, redundant SourceKit-LSP process for the same workspace.
@MainActor
final class MultiLanguageServicesCoordinator {
    private let identity: WorkspaceIdentity
    private let trustStore: WorkspaceTrustStore
    private let overrideStore: LanguageServerOverrideStore
    /// Shared, app-lifetime bounded diagnostics log (SPEC 15) — see
    /// `LanguageServicesCoordinator`'s identical field for why a
    /// crashed/disabled adapter server is recorded here in addition to
    /// the in-UI server-state label.
    private let diagnosticsLog: BoundedEventLog
    private var services: [ObjectIdentifier: LanguageWorkspaceService] = [:]
    private var statesByAdapter: [ObjectIdentifier: LanguageServerState] = [:]

    var onStateChange: (() -> Void)?
    var onDiagnostics: ((URL, [Diagnostic]) -> Void)?

    init(
        identity: WorkspaceIdentity,
        trustStore: WorkspaceTrustStore,
        overrideStore: LanguageServerOverrideStore = LanguageServerOverrideStore(),
        diagnosticsLog: BoundedEventLog = BoundedEventLog()
    ) {
        self.identity = identity
        self.trustStore = trustStore
        self.overrideStore = overrideStore
        self.diagnosticsLog = diagnosticsLog
    }

    private var isTrusted: Bool {
        trustStore.isTrusted(identity)
    }

    /// The adapters Kod ships that this coordinator manages — every one
    /// except Swift.
    static let managedAdapters: [any LanguageAdapter.Type] = LanguageAdapterRegistry.all.filter {
        ObjectIdentifier($0) != ObjectIdentifier(SwiftAdapter.self)
    }

    /// The current server-state summary across every non-Swift adapter
    /// currently in use for this workspace — used to feed a combined
    /// server-state indicator alongside Swift's (SPEC 6.2's Missing/
    /// Starting/Indexing/Ready/Busy/Stopped/Crashed/Disabled UI).
    var states: [(adapter: any LanguageAdapter.Type, state: LanguageServerState)] {
        Self.managedAdapters.compactMap { adapter in
            guard let state = statesByAdapter[ObjectIdentifier(adapter)] else {
                return nil
            }
            return (adapter, state)
        }
    }

    /// Called whenever any document becomes visible. A no-op for a file
    /// extension no managed adapter claims (e.g. plain text), so syntax
    /// viewing and search remain fully independent of this coordinator.
    func handleDocumentReady(url: URL, snapshot: SourceSnapshot) {
        guard let adapter = Self.managedAdapters.first(where: { $0.fileExtensions.contains(url.pathExtension.lowercased()) }),
              isTrusted else {
            return
        }
        Task {
            await self.syncDocument(adapter: adapter, snapshot: snapshot)
        }
    }

    /// Manual Restart action for one specific adapter's server (SPEC 6.2).
    func restart(adapter: any LanguageAdapter.Type) {
        guard let service = services[ObjectIdentifier(adapter)] else {
            return
        }
        Task {
            try? await service.restart()
        }
    }

    /// Returns the already-started service for `url`'s adapter, if any
    /// — used by Peek/Hierarchy/Inlay commands, which should simply be
    /// unavailable (hidden) rather than erroring when no server for that
    /// language is running yet.
    func service(forURL url: URL) -> LanguageWorkspaceService? {
        guard let adapter = Self.managedAdapters.first(where: { $0.fileExtensions.contains(url.pathExtension.lowercased()) }) else {
            return nil
        }
        return services[ObjectIdentifier(adapter)]
    }

    private func startServiceIfNeeded(adapter: any LanguageAdapter.Type) async -> LanguageWorkspaceService? {
        let key = ObjectIdentifier(adapter)
        if let existing = services[key] {
            return existing
        }
        guard isTrusted else {
            return nil
        }
        let newService = LanguageAdapterRegistry.makeService(
            for: adapter,
            identity: identity,
            trustStore: trustStore,
            overrideStore: overrideStore,
            onStateChange: { [weak self] newState in
                Task { @MainActor in
                    self?.statesByAdapter[key] = newState
                    self?.recordStateChangeIfDegraded(adapter: adapter, newState)
                    self?.onStateChange?()
                }
            },
            onDiagnostics: { [weak self] url, diagnostics in
                Task { @MainActor in
                    self?.onDiagnostics?(url, diagnostics)
                }
            }
        )
        services[key] = newService
        do {
            try await newService.start()
        } catch {
            // The service's own state-change callback already reported
            // `.missing`/`.crashed` as appropriate.
        }
        return newService
    }

    /// Mirrors `LanguageServicesCoordinator.recordStateChangeIfDegraded`
    /// for this coordinator's per-adapter servers: only the explicit
    /// `crashed`/`disabled` failure states are recorded, tagging which
    /// adapter's `languageKey` degraded (a fixed, non-identifying label,
    /// not repository content) alongside the workspace root path.
    private func recordStateChangeIfDegraded(adapter: any LanguageAdapter.Type, _ newState: LanguageServerState) {
        let reason: String
        switch newState {
        case .crashed(let message):
            reason = message
        case .disabled(let message):
            reason = message
        default:
            return
        }
        Task {
            await diagnosticsLog.record(
                subsystem: .languageServer,
                level: .warning,
                message: Localized.string(
                    "\(adapter.languageKey) language server entered \(newState.displayName.lowercased()) state",
                    comment: "Diagnostics log message recorded when a language server adapter transitions to a degraded state"
                ),
                context: [
                    DiagnosticContextField(name: "workspaceRoot", category: .fullPath, value: identity.root.path),
                    DiagnosticContextField(name: "reason", category: .diagnosticMessage, value: reason)
                ]
            )
        }
    }

    private func syncDocument(adapter: any LanguageAdapter.Type, snapshot: SourceSnapshot) async {
        guard let service = await startServiceIfNeeded(adapter: adapter) else {
            return
        }
        do {
            try await service.didOpen(snapshot)
        } catch {
            try? await service.didChange(snapshot)
        }
    }

    /// Stops every already-started adapter service for this workspace
    /// (SPEC 13.1: revoking trust must be immediately effective, mirrored
    /// from `LanguageServicesCoordinator.handleTrustRevoked()`), resetting
    /// each adapter's reported state to `.disabled` so the combined
    /// server-state UI reflects the revocation right away rather than
    /// only on the next document open.
    func handleTrustRevoked() {
        guard !services.isEmpty else {
            return
        }
        let runningServices = services
        services.removeAll()
        for key in statesByAdapter.keys {
            statesByAdapter[key] = .disabled(reason: "Workspace trust revoked")
        }
        onStateChange?()
        Task {
            for service in runningServices.values {
                await service.stop()
            }
            await diagnosticsLog.record(
                subsystem: .languageServer,
                level: .info,
                message: Localized.string(
                    "Language servers stopped after workspace trust was revoked",
                    comment: "Diagnostics log message recorded when language servers are stopped due to trust revocation"
                ),
                context: [
                    DiagnosticContextField(name: "workspaceRoot", category: .fullPath, value: identity.root.path)
                ]
            )
        }
    }
}
