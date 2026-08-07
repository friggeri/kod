import CodeViewport
import DiagnosticsCore
import Foundation
import LanguageClient
import SourceModel
import WorkspaceCore

/// Owns the single, lazily-started `SwiftWorkspaceLanguageService` for one
/// workspace, wiring it into the editor UI: document synchronization on
/// open/reload, semantic tokens fed into each open `CodeDocumentViewController`'s
/// decoration compositor above the lexical layer (SPEC 7.1), diagnostics
/// forwarded to the Problems sidebar, and server state forwarded to the
/// server-state UI (SPEC 6.2). Syntax highlighting and search never depend
/// on any of this: every language-service call here is best-effort and
/// failures are swallowed only after being surfaced through `state`/logs,
/// never regressing the already-working read-only viewer.
@MainActor
final class LanguageServicesCoordinator {
    private let identity: WorkspaceIdentity
    private let trustStore: WorkspaceTrustStore
    /// Shared, app-lifetime bounded diagnostics log (SPEC 15): a crashed
    /// or disabled server state is exactly the kind of explicit,
    /// user-visible-elsewhere failure this coordinator also records here
    /// so a support bundle/Diagnostics viewer can show it even after the
    /// in-UI server-state label has moved on.
    private let diagnosticsLog: BoundedEventLog
    private var service: SwiftWorkspaceLanguageService?
    private(set) var state: LanguageServerState = .missing(reason: "Not started")
    /// Tracks the most recently seen controller per relative path so a
    /// semantic-tokens response that arrives after the user has already
    /// switched tabs still lands on the right (still-alive) viewport.
    private var controllersByRelativePath: [String: WeakDocumentController] = [:]
    private var semanticDecorationTasks: [String: Task<Void, Never>] = [:]

    var onStateChange: (() -> Void)?
    var onDiagnostics: ((URL, [Diagnostic]) -> Void)?

    init(identity: WorkspaceIdentity, trustStore: WorkspaceTrustStore, diagnosticsLog: BoundedEventLog = BoundedEventLog()) {
        self.identity = identity
        self.trustStore = trustStore
        self.diagnosticsLog = diagnosticsLog
    }

    private var isTrusted: Bool {
        trustStore.isTrusted(identity)
    }

    /// Called whenever a Swift document becomes visible (first open or
    /// after a reload). Starts the shared SourceKit-LSP connection lazily
    /// on first use, never before the workspace is trusted (SPEC 13.1).
    func handleDocumentReady(relativePath: String, controller: CodeDocumentViewController) {
        guard relativePath.hasSuffix(".swift") else {
            return
        }
        controllersByRelativePath[relativePath] = WeakDocumentController(controller)
        guard isTrusted else {
            return
        }
        Task {
            await self.syncAndDecorate(relativePath: relativePath, controller: controller)
        }
    }

    /// Manual Restart action (SPEC 6.2), available regardless of current
    /// state — most useful once `state` is `.disabled`.
    func restart() {
        guard let service else {
            return
        }
        semanticDecorationTasks.values.forEach { $0.cancel() }
        semanticDecorationTasks.removeAll()
        Task {
            do {
                try await service.restart()
            } catch {
                // Failure is already reflected via the state-change
                // callback (the connection reports its own crashed/
                // disabled/missing state); nothing further to do here.
                return
            }
            for (relativePath, weakController) in self.controllersByRelativePath {
                guard let controller = weakController.controller else {
                    continue
                }
                await self.syncAndDecorate(
                    relativePath: relativePath,
                    controller: controller
                )
            }
        }
    }

    /// Workspace-wide symbol search for the Symbols sidebar.
    func workspaceSymbols(query: String) async throws -> [WorkspaceSymbolLocation] {
        guard let service else {
            throw SwiftLanguageServiceError.notStarted
        }
        return try await service.workspaceSymbols(query: query)
    }

    // MARK: - Phase 7 extended navigation/hierarchy surface
    //
    // Every method below simply forwards to the already-started
    // `SwiftWorkspaceLanguageService` (throwing `.notStarted` if none is
    // running yet, exactly like `workspaceSymbols` above) so the
    // Peek/Hierarchy/Inlay UI surfaces can call them uniformly whether
    // or not a server happens to be ready.

    func hover(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> Hover? {
        guard let service else { throw SwiftLanguageServiceError.notStarted }
        return try await service.hover(snapshot: snapshot, utf8Offset: utf8Offset)
    }

    func definition(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> [NavigationTarget] {
        guard let service else { throw SwiftLanguageServiceError.notStarted }
        return try await service.definition(snapshot: snapshot, utf8Offset: utf8Offset)
    }

    func declaration(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> [NavigationTarget] {
        guard let service else { throw SwiftLanguageServiceError.notStarted }
        return try await service.declaration(snapshot: snapshot, utf8Offset: utf8Offset)
    }

    func typeDefinition(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> [NavigationTarget] {
        guard let service else { throw SwiftLanguageServiceError.notStarted }
        return try await service.typeDefinition(snapshot: snapshot, utf8Offset: utf8Offset)
    }

    func implementation(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> [NavigationTarget] {
        guard let service else { throw SwiftLanguageServiceError.notStarted }
        return try await service.implementation(snapshot: snapshot, utf8Offset: utf8Offset)
    }

    func references(snapshot: SourceSnapshot, utf8Offset: Int, includeDeclaration: Bool) async throws -> [NavigationTarget] {
        guard let service else { throw SwiftLanguageServiceError.notStarted }
        return try await service.references(snapshot: snapshot, utf8Offset: utf8Offset, includeDeclaration: includeDeclaration)
    }

    func documentHighlights(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> [ValidatedDocumentHighlight] {
        guard let service else { throw SwiftLanguageServiceError.notStarted }
        return try await service.documentHighlights(snapshot: snapshot, utf8Offset: utf8Offset)
    }

    func foldingRanges(snapshot: SourceSnapshot) async throws -> [ValidatedFoldingRange] {
        guard let service else { throw SwiftLanguageServiceError.notStarted }
        return try await service.foldingRanges(snapshot: snapshot)
    }

    func selectionRanges(snapshot: SourceSnapshot, utf8Offsets: [Int]) async throws -> [ValidatedSelectionRange] {
        guard let service else { throw SwiftLanguageServiceError.notStarted }
        return try await service.selectionRanges(snapshot: snapshot, utf8Offsets: utf8Offsets)
    }

    func documentLinks(snapshot: SourceSnapshot) async throws -> [ValidatedDocumentLink] {
        guard let service else { throw SwiftLanguageServiceError.notStarted }
        return try await service.documentLinks(snapshot: snapshot)
    }

    func inlayHints(snapshot: SourceSnapshot, utf8Range: Range<Int>) async throws -> [ValidatedInlayHint] {
        guard let service else { throw SwiftLanguageServiceError.notStarted }
        return try await service.inlayHints(snapshot: snapshot, utf8Range: utf8Range)
    }

    func signatureHelp(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> SignatureHelp? {
        guard let service else { throw SwiftLanguageServiceError.notStarted }
        return try await service.signatureHelp(snapshot: snapshot, utf8Offset: utf8Offset)
    }

    func prepareCallHierarchy(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> [ValidatedHierarchyItem] {
        guard let service else { throw SwiftLanguageServiceError.notStarted }
        return try await service.prepareCallHierarchy(snapshot: snapshot, utf8Offset: utf8Offset)
    }

    func callHierarchyIncomingCalls(item: ValidatedHierarchyItem) async throws -> [ValidatedIncomingCall] {
        guard let service else { throw SwiftLanguageServiceError.notStarted }
        return try await service.callHierarchyIncomingCalls(item: item)
    }

    func callHierarchyOutgoingCalls(item: ValidatedHierarchyItem) async throws -> [ValidatedOutgoingCall] {
        guard let service else { throw SwiftLanguageServiceError.notStarted }
        return try await service.callHierarchyOutgoingCalls(item: item)
    }

    func prepareTypeHierarchy(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> [ValidatedHierarchyItem] {
        guard let service else { throw SwiftLanguageServiceError.notStarted }
        return try await service.prepareTypeHierarchy(snapshot: snapshot, utf8Offset: utf8Offset)
    }

    func typeHierarchySupertypes(item: ValidatedHierarchyItem) async throws -> [ValidatedHierarchyItem] {
        guard let service else { throw SwiftLanguageServiceError.notStarted }
        return try await service.typeHierarchySupertypes(item: item)
    }

    func typeHierarchySubtypes(item: ValidatedHierarchyItem) async throws -> [ValidatedHierarchyItem] {
        guard let service else { throw SwiftLanguageServiceError.notStarted }
        return try await service.typeHierarchySubtypes(item: item)
    }

    private func startServiceIfNeeded() async -> SwiftWorkspaceLanguageService? {
        if let service {
            return service
        }
        guard isTrusted else {
            return nil
        }
        let newService = SwiftWorkspaceLanguageService(
            identity: identity,
            trustStore: trustStore,
            onStateChange: { [weak self] newState in
                Task { @MainActor in
                    self?.state = newState
                    self?.recordStateChangeIfDegraded(newState)
                    self?.onStateChange?()
                }
            },
            onDiagnostics: { [weak self] url, diagnostics in
                Task { @MainActor in
                    self?.onDiagnostics?(url, diagnostics)
                }
            }
        )
        service = newService
        do {
            try await newService.start()
        } catch {
            // `newService`'s own state-change callback already reported
            // `.missing`/`.crashed` as appropriate; keep the instance so a
            // later manual Restart can retry rather than silently
            // pretending nothing was attempted.
        }
        return newService
    }

    /// Records a bounded diagnostic event (SPEC 15) the moment the Swift
    /// language server enters a degraded (`crashed`/`disabled`) state —
    /// this is the real, already-existing failure path
    /// `refreshLanguageServerStateUI` also reflects in the sidebar label,
    /// simply also captured for the Diagnostics viewer/support bundle.
    /// `.ready`/`.starting`/etc. are not logged: only the explicit
    /// failure states are noteworthy here.
    private func recordStateChangeIfDegraded(_ newState: LanguageServerState) {
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
                    "Swift language server entered \(newState.displayName.lowercased()) state",
                    comment: "Diagnostics log message recorded when the Swift language server transitions to a degraded state"
                ),
                context: [
                    DiagnosticContextField(name: "workspaceRoot", category: .fullPath, value: identity.root.path),
                    DiagnosticContextField(name: "reason", category: .diagnosticMessage, value: reason)
                ]
            )
        }
    }

    /// Called when the workspace's trust is revoked while this
    /// coordinator's server may already be running (SPEC 13.1: trust
    /// "can be revoked" and must become immediately effective). Stops
    /// any already-started service and resets state back to `.disabled`
    /// so `isTrusted`'s existing gate in `handleDocumentReady`/
    /// `startServiceIfNeeded` — left completely unchanged — simply has
    /// nothing left running to gate around, and a subsequent re-trust
    /// starts a fresh service rather than resuming a stale connection.
    func handleTrustRevoked() {
        semanticDecorationTasks.values.forEach { $0.cancel() }
        semanticDecorationTasks.removeAll()
        guard let runningService = service else {
            return
        }
        service = nil
        state = .disabled(reason: "Workspace trust revoked")
        onStateChange?()
        Task {
            await runningService.stop()
            await diagnosticsLog.record(
                subsystem: .languageServer,
                level: .info,
                message: Localized.string(
                    "Swift language server stopped after workspace trust was revoked",
                    comment: "Diagnostics log message recorded when the Swift language server is stopped due to trust revocation"
                ),
                context: [
                    DiagnosticContextField(name: "workspaceRoot", category: .fullPath, value: identity.root.path)
                ]
            )
        }
    }

    func handleTrustGranted() {
        guard isTrusted else {
            return
        }
        for (relativePath, weakController) in controllersByRelativePath {
            guard let controller = weakController.controller else {
                continue
            }
            Task {
                await self.syncAndDecorate(relativePath: relativePath, controller: controller)
            }
        }
    }

    private func syncAndDecorate(relativePath: String, controller: CodeDocumentViewController) async {
        let snapshot = controller.snapshot
        guard let service = await startServiceIfNeeded() else {
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
            relativePath: relativePath,
            controller: liveController,
            service: service
        )
    }

    private func scheduleSemanticDecoration(
        relativePath: String,
        controller: CodeDocumentViewController,
        service: SwiftWorkspaceLanguageService,
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
                relativePath: relativePath,
                controller: controller,
                service: service,
                snapshot: snapshot
            )
        }
    }

    private func applySemanticDecoration(
        relativePath: String,
        controller: CodeDocumentViewController,
        service: SwiftWorkspaceLanguageService,
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
                relativePath: relativePath,
                controller: controller,
                service: service,
                delay: .milliseconds(250)
            )
        } catch SwiftLanguageServiceError.capabilityUnavailable {
            // Capability-gated off for this server (e.g. no semantic
            // tokens support): the lexical layer remains the only
            // highlighting, which is the correct degraded behavior.
        } catch {
            // Any other failure (timeout, stale snapshot, server crash
            // mid-request) simply leaves semantic highlighting absent for
            // this pass; lexical highlighting is unaffected.
        }
    }
}

/// A non-retaining handle to a `CodeDocumentViewController`, since the
/// coordinator must never be the thing keeping a closed tab's controller
/// alive.
private struct WeakDocumentController {
    weak var controller: CodeDocumentViewController?

    init(_ controller: CodeDocumentViewController) {
        self.controller = controller
    }
}
