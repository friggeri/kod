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
    private var startupTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var startupGenerations: [ObjectIdentifier: Int] = [:]
    private var statesByAdapter: [ObjectIdentifier: LanguageServerState] = [:]
    private var controllersByRelativePath: [String: WeakMultiLanguageDocumentController] = [:]
    private var semanticDecorationTasks: [String: Task<Void, Never>] = [:]

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
    func handleDocumentReady(relativePath: String, controller: CodeDocumentViewController) {
        let url = controller.snapshot.url
        guard let adapter = Self.adapter(for: url) else {
            return
        }
        controllersByRelativePath[relativePath] = WeakMultiLanguageDocumentController(controller)
        guard isTrusted else {
            return
        }
        Task {
            await self.syncAndDecorate(
                adapter: adapter,
                relativePath: relativePath,
                controller: controller
            )
        }
    }

    /// Manual Restart action for one specific adapter's server (SPEC 6.2).
    func restart(adapter: any LanguageAdapter.Type) {
        guard let service = services[ObjectIdentifier(adapter)] else {
            return
        }
        for (relativePath, weakController) in controllersByRelativePath {
            guard let controller = weakController.controller,
                  let controllerAdapter = Self.adapter(for: controller.snapshot.url),
                  ObjectIdentifier(controllerAdapter) == ObjectIdentifier(adapter) else {
                continue
            }
            semanticDecorationTasks[relativePath]?.cancel()
            semanticDecorationTasks.removeValue(forKey: relativePath)
        }
        Task {
            do {
                try await service.restart()
            } catch {
                return
            }
            for (relativePath, weakController) in self.controllersByRelativePath {
                guard let controller = weakController.controller,
                      let controllerAdapter = Self.adapter(for: controller.snapshot.url),
                      ObjectIdentifier(controllerAdapter) == ObjectIdentifier(adapter) else {
                    continue
                }
                await self.syncAndDecorate(
                    adapter: adapter,
                    relativePath: relativePath,
                    controller: controller
                )
            }
        }
    }

    func restart(forURL url: URL) {
        guard let adapter = Self.adapter(for: url) else {
            return
        }
        restart(adapter: adapter)
    }

    func status(forURL url: URL) -> (languageName: String, state: LanguageServerState)? {
        guard let adapter = Self.adapter(for: url) else {
            return nil
        }
        let state: LanguageServerState
        if !isTrusted {
            state = .disabled(reason: "Workspace is not trusted")
        } else {
            state = statesByAdapter[ObjectIdentifier(adapter)] ?? .missing(reason: "Not started")
        }
        let languageName: String
        switch adapter.languageKey {
        case "typescript": languageName = "TypeScript"
        case "html": languageName = "HTML"
        case "css": languageName = "CSS"
        default: languageName = adapter.languageKey.capitalized
        }
        return (languageName, state)
    }

    func languageKey(forURL url: URL) -> String? {
        Self.adapter(for: url)?.languageKey
    }

    /// Returns the already-started service for `url`'s adapter, if any
    /// — used by Peek/Hierarchy/Inlay commands, which should simply be
    /// unavailable (hidden) rather than erroring when no server for that
    /// language is running yet.
    func service(forURL url: URL) -> LanguageWorkspaceService? {
        guard let adapter = Self.adapter(for: url) else {
            return nil
        }
        return services[ObjectIdentifier(adapter)]
    }

    func workspaceSymbols(
        forURL url: URL,
        query: String
    ) async throws -> [WorkspaceSymbolLocation] {
        guard let adapter = Self.adapter(for: url) else {
            return []
        }
        guard isTrusted else {
            throw LanguageWorkspaceServiceError.notTrusted
        }
        guard let service = await startServiceIfNeeded(adapter: adapter) else {
            throw LanguageWorkspaceServiceError.notStarted
        }
        return try await service.workspaceSymbols(query: query)
    }

    func hover(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> Hover? {
        guard let adapter = Self.adapter(for: snapshot.url),
              let service = services[ObjectIdentifier(adapter)] else {
            return nil
        }
        return try await service.hover(snapshot: snapshot, utf8Offset: utf8Offset)
    }

    func definition(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> [NavigationTarget] {
        guard let adapter = Self.adapter(for: snapshot.url),
              let service = services[ObjectIdentifier(adapter)] else {
            return []
        }
        return try await service.definition(snapshot: snapshot, utf8Offset: utf8Offset)
    }

    private static func adapter(for url: URL) -> (any LanguageAdapter.Type)? {
        managedAdapters.first { $0.fileExtensions.contains(url.pathExtension.lowercased()) }
    }

    private func startServiceIfNeeded(adapter: any LanguageAdapter.Type) async -> LanguageWorkspaceService? {
        let key = ObjectIdentifier(adapter)
        if let existing = services[key] {
            if let startupTask = startupTasks[key] {
                await startupTask.value
            }
            return isTrusted && services[key] === existing ? existing : nil
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
        startupGenerations[key, default: 0] += 1
        let startupGeneration = startupGenerations[key, default: 0]
        let startupTask = Task {
            do {
                try await newService.start()
            } catch {
                // The service's own state-change callback already reported
                // `.missing`/`.crashed` as appropriate.
            }
        }
        startupTasks[key] = startupTask
        await startupTask.value
        if startupGenerations[key] == startupGeneration {
            startupTasks.removeValue(forKey: key)
        }
        guard isTrusted, services[key] === newService else {
            return nil
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

    private func syncAndDecorate(
        adapter: any LanguageAdapter.Type,
        relativePath: String,
        controller: CodeDocumentViewController
    ) async {
        let snapshot = controller.snapshot
        guard let service = await startServiceIfNeeded(adapter: adapter) else {
            return
        }
        do {
            try await service.didOpen(snapshot)
        } catch {
            do {
                try await service.didChange(snapshot)
            } catch {
                return
            }
        }
        guard let liveController = controllersByRelativePath[relativePath]?.controller,
              liveController.snapshot.version == snapshot.version else {
            return
        }
        scheduleSemanticDecoration(
            adapter: adapter,
            relativePath: relativePath,
            controller: liveController,
            service: service
        )
    }

    private func scheduleSemanticDecoration(
        adapter: any LanguageAdapter.Type,
        relativePath: String,
        controller: CodeDocumentViewController,
        service: LanguageWorkspaceService,
        delay: Duration = .zero
    ) {
        semanticDecorationTasks[relativePath]?.cancel()
        let snapshot = controller.snapshot
        semanticDecorationTasks[relativePath] = Task { @MainActor [weak self, weak controller] in
            if delay != .zero {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            guard let self, let controller,
                  self.controllersByRelativePath[relativePath]?.controller === controller,
                  controller.snapshot.version == snapshot.version else {
                return
            }
            await self.applySemanticDecoration(
                adapter: adapter,
                relativePath: relativePath,
                controller: controller,
                service: service,
                snapshot: snapshot
            )
        }
    }

    private func applySemanticDecoration(
        adapter: any LanguageAdapter.Type,
        relativePath: String,
        controller: CodeDocumentViewController,
        service: LanguageWorkspaceService,
        snapshot: SourceSnapshot
    ) async {
        do {
            let tokens = try await service.semanticTokens(snapshot: snapshot)
            guard let stillLiveController = controllersByRelativePath[relativePath]?.controller,
                  stillLiveController.snapshot.version == snapshot.version else {
                return
            }
            let layer = SemanticTokenDecorationSource.layer(
                fromTokens: tokens,
                theme: stillLiveController.theme,
                snapshotVersion: snapshot.version,
                layerVersion: 1
            )
            stillLiveController.viewport.applyDecorationLayer(layer)
        } catch is CancellationError {
            guard !Task.isCancelled,
                  controllersByRelativePath[relativePath]?.controller === controller,
                  controller.snapshot.version == snapshot.version else {
                return
            }
            scheduleSemanticDecoration(
                adapter: adapter,
                relativePath: relativePath,
                controller: controller,
                service: service,
                delay: .milliseconds(250)
            )
        } catch LanguageWorkspaceServiceError.capabilityUnavailable {
            // Lexical highlighting remains active when this adapter does not
            // advertise semantic tokens.
        } catch {
            // Connection state and diagnostics expose server failures; the
            // independent lexical layer remains usable.
        }
    }

    func handleTrustGranted() {
        guard isTrusted else {
            return
        }
        for (relativePath, weakController) in controllersByRelativePath {
            guard let controller = weakController.controller,
                  let adapter = Self.adapter(for: controller.snapshot.url) else {
                continue
            }
            Task {
                await self.syncAndDecorate(
                    adapter: adapter,
                    relativePath: relativePath,
                    controller: controller
                )
            }
        }
    }

    /// Stops every already-started adapter service for this workspace
    /// (SPEC 13.1: revoking trust must be immediately effective, mirrored
    /// from `LanguageServicesCoordinator.handleTrustRevoked()`), resetting
    /// each adapter's reported state to `.disabled` so the combined
    /// server-state UI reflects the revocation right away rather than
    /// only on the next document open.
    func handleTrustRevoked() {
        semanticDecorationTasks.values.forEach { $0.cancel() }
        semanticDecorationTasks.removeAll()
        for key in startupTasks.keys {
            startupGenerations[key, default: 0] += 1
        }
        startupTasks.values.forEach { $0.cancel() }
        startupTasks.removeAll()
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

    private struct WeakMultiLanguageDocumentController {
        weak var controller: CodeDocumentViewController?

        init(_ controller: CodeDocumentViewController) {
            self.controller = controller
        }
    }
}
