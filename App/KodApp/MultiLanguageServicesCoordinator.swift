import CodeViewport
import DiagnosticsCore
import Foundation
import LanguageAdapters
import LanguageClient
import SourceModel
import WorkspaceCore

/// Owns one lazily-started generic LSP service per enabled language profile for
/// a workspace. Swift and every other language share this path; syntax and
/// search remain independent when a profile has no LSP configuration.
@MainActor
final class MultiLanguageServicesCoordinator {
    private let identity: WorkspaceIdentity
    private let trustStore: WorkspaceTrustStore
    private let overrideStore: LanguageServerOverrideStore
    private let diagnosticsLog: BoundedEventLog
    private let profileRegistry: LanguageProfileRegistry
    let diagnosticsStore: WorkspaceDiagnosticsStore

    private var services: [String: LanguageWorkspaceService] = [:]
    private var serviceProfiles: [String: LanguageProfile] = [:]
    private var startupTasks: [String: Task<Void, Never>] = [:]
    private var startupGenerations: [String: Int] = [:]
    private var statesByProfile: [String: LanguageServerState] = [:]
    private var controllersByRelativePath: [
        String: WeakMultiLanguageDocumentController
    ] = [:]
    private var semanticDecorationTasks: [String: Task<Void, Never>] = [:]
    private var profileObserver: UUID?

    var onStateChange: (() -> Void)?
    var onMissingServer: ((LanguageProfile) -> Void)?
    var onUnknownFileType: ((URL) -> Void)?

    init(
        identity: WorkspaceIdentity,
        trustStore: WorkspaceTrustStore,
        profileRegistry: LanguageProfileRegistry,
        overrideStore: LanguageServerOverrideStore = LanguageServerOverrideStore(),
        diagnosticsLog: BoundedEventLog = BoundedEventLog(),
        diagnosticsStore: WorkspaceDiagnosticsStore = WorkspaceDiagnosticsStore()
    ) {
        self.identity = identity
        self.trustStore = trustStore
        self.profileRegistry = profileRegistry
        self.overrideStore = overrideStore
        self.diagnosticsLog = diagnosticsLog
        self.diagnosticsStore = diagnosticsStore
        self.profileObserver = profileRegistry.store.observeChanges {
            [weak self] in
            self?.handleProfilesChanged()
        }
    }

    private var isTrusted: Bool {
        trustStore.isTrusted(identity)
    }

    var languageServerProfiles: [LanguageProfile] {
        profileRegistry.snapshot.profiles.filter {
            $0.languageServer != nil
        }
    }

    var states: [(profile: LanguageProfile, state: LanguageServerState)] {
        languageServerProfiles.compactMap { profile in
            statesByProfile[profile.identifier].map {
                (profile: profile, state: $0)
            }
        }
    }

    func handleDocumentReady(
        relativePath: String,
        controller: CodeDocumentViewController
    ) {
        guard let resolved = resolvedProfile(for: controller.snapshot) else {
            onUnknownFileType?(controller.snapshot.url)
            return
        }
        guard resolved.profile.languageServer != nil else {
            return
        }
        controllersByRelativePath[relativePath] =
            WeakMultiLanguageDocumentController(controller)
        guard isTrusted else {
            return
        }
        Task {
            await self.syncAndDecorate(
                resolved: resolved,
                relativePath: relativePath,
                controller: controller
            )
        }
    }

    func restart(profileIdentifier: String) {
        guard let service = services[profileIdentifier],
              let profile = profileRegistry.snapshot.profile(
                  identifier: profileIdentifier
              ) else {
            return
        }
        cancelDecorations(for: profileIdentifier)
        diagnosticsStore.clear(owner: profileIdentifier)
        Task {
            do {
                try await service.restart()
            } catch {
                return
            }
            await self.resynchronizeOpenDocuments(for: profile)
        }
    }

    func restart(forURL url: URL) {
        guard let resolved = resolvedProfile(forOpenURL: url) else {
            return
        }
        restart(profileIdentifier: resolved.profile.identifier)
    }

    func status(
        forURL url: URL
    ) -> (languageName: String, state: LanguageServerState)? {
        guard let resolved = resolvedProfile(forOpenURL: url),
              resolved.profile.languageServer != nil else {
            return nil
        }
        let state: LanguageServerState
        if !isTrusted {
            state = .disabled(reason: "Workspace is not trusted")
        } else {
            state = statesByProfile[resolved.profile.identifier]
                ?? .missing(reason: "Not started")
        }
        return (resolved.profile.displayName, state)
    }

    func languageKey(forURL url: URL) -> String? {
        resolvedProfile(forOpenURL: url)?.profile.identifier
    }

    func service(forURL url: URL) -> LanguageWorkspaceService? {
        guard let resolved = resolvedProfile(forOpenURL: url) else {
            return nil
        }
        return services[resolved.profile.identifier]
    }

    func workspaceSymbols(
        forURL url: URL,
        query: String
    ) async throws -> [WorkspaceSymbolLocation] {
        guard let resolved = resolvedProfile(forOpenURL: url),
              resolved.profile.languageServer != nil else {
            return []
        }
        guard isTrusted else {
            throw LanguageWorkspaceServiceError.notTrusted
        }
        guard let service = await startServiceIfNeeded(resolved: resolved) else {
            throw LanguageWorkspaceServiceError.notStarted
        }
        return try await service.workspaceSymbols(query: query)
    }

    func hover(
        snapshot: SourceSnapshot,
        utf8Offset: Int
    ) async throws -> Hover? {
        guard let service = startedService(for: snapshot) else {
            return nil
        }
        return try await service.hover(
            snapshot: snapshot,
            utf8Offset: utf8Offset
        )
    }

    func definition(
        snapshot: SourceSnapshot,
        utf8Offset: Int
    ) async throws -> [NavigationTarget] {
        guard let service = startedService(for: snapshot) else {
            return []
        }
        return try await service.definition(
            snapshot: snapshot,
            utf8Offset: utf8Offset
        )
    }

    func declaration(
        snapshot: SourceSnapshot,
        utf8Offset: Int
    ) async throws -> [NavigationTarget] {
        guard let service = startedService(for: snapshot) else {
            return []
        }
        return try await service.declaration(
            snapshot: snapshot,
            utf8Offset: utf8Offset
        )
    }

    func typeDefinition(
        snapshot: SourceSnapshot,
        utf8Offset: Int
    ) async throws -> [NavigationTarget] {
        guard let service = startedService(for: snapshot) else {
            return []
        }
        return try await service.typeDefinition(
            snapshot: snapshot,
            utf8Offset: utf8Offset
        )
    }

    func implementation(
        snapshot: SourceSnapshot,
        utf8Offset: Int
    ) async throws -> [NavigationTarget] {
        guard let service = startedService(for: snapshot) else {
            return []
        }
        return try await service.implementation(
            snapshot: snapshot,
            utf8Offset: utf8Offset
        )
    }

    func references(
        snapshot: SourceSnapshot,
        utf8Offset: Int,
        includeDeclaration: Bool
    ) async throws -> [NavigationTarget] {
        guard let service = startedService(for: snapshot) else {
            return []
        }
        return try await service.references(
            snapshot: snapshot,
            utf8Offset: utf8Offset,
            includeDeclaration: includeDeclaration
        )
    }

    func documentHighlights(
        snapshot: SourceSnapshot,
        utf8Offset: Int
    ) async throws -> [ValidatedDocumentHighlight] {
        guard let service = startedService(for: snapshot) else {
            return []
        }
        return try await service.documentHighlights(
            snapshot: snapshot,
            utf8Offset: utf8Offset
        )
    }

    func foldingRanges(
        snapshot: SourceSnapshot
    ) async throws -> [ValidatedFoldingRange] {
        guard let service = startedService(for: snapshot) else {
            return []
        }
        return try await service.foldingRanges(snapshot: snapshot)
    }

    func selectionRanges(
        snapshot: SourceSnapshot,
        utf8Offsets: [Int]
    ) async throws -> [ValidatedSelectionRange] {
        guard let service = startedService(for: snapshot) else {
            return []
        }
        return try await service.selectionRanges(
            snapshot: snapshot,
            utf8Offsets: utf8Offsets
        )
    }

    func documentLinks(
        snapshot: SourceSnapshot
    ) async throws -> [ValidatedDocumentLink] {
        guard let service = startedService(for: snapshot) else {
            return []
        }
        return try await service.documentLinks(snapshot: snapshot)
    }

    func inlayHints(
        snapshot: SourceSnapshot,
        utf8Range: Range<Int>
    ) async throws -> [ValidatedInlayHint] {
        guard let service = startedService(for: snapshot) else {
            return []
        }
        return try await service.inlayHints(
            snapshot: snapshot,
            utf8Range: utf8Range
        )
    }

    func signatureHelp(
        snapshot: SourceSnapshot,
        utf8Offset: Int
    ) async throws -> SignatureHelp? {
        guard let service = startedService(for: snapshot) else {
            return nil
        }
        return try await service.signatureHelp(
            snapshot: snapshot,
            utf8Offset: utf8Offset
        )
    }

    func prepareCallHierarchy(
        snapshot: SourceSnapshot,
        utf8Offset: Int
    ) async throws -> [ValidatedHierarchyItem] {
        guard let service = startedService(for: snapshot) else {
            return []
        }
        return try await service.prepareCallHierarchy(
            snapshot: snapshot,
            utf8Offset: utf8Offset
        )
    }

    func callHierarchyIncomingCalls(
        item: ValidatedHierarchyItem
    ) async throws -> [ValidatedIncomingCall] {
        guard let service = service(forURL: item.url) else {
            return []
        }
        return try await service.callHierarchyIncomingCalls(item: item)
    }

    func callHierarchyOutgoingCalls(
        item: ValidatedHierarchyItem
    ) async throws -> [ValidatedOutgoingCall] {
        guard let service = service(forURL: item.url) else {
            return []
        }
        return try await service.callHierarchyOutgoingCalls(item: item)
    }

    func prepareTypeHierarchy(
        snapshot: SourceSnapshot,
        utf8Offset: Int
    ) async throws -> [ValidatedHierarchyItem] {
        guard let service = startedService(for: snapshot) else {
            return []
        }
        return try await service.prepareTypeHierarchy(
            snapshot: snapshot,
            utf8Offset: utf8Offset
        )
    }

    func typeHierarchySupertypes(
        item: ValidatedHierarchyItem
    ) async throws -> [ValidatedHierarchyItem] {
        guard let service = service(forURL: item.url) else {
            return []
        }
        return try await service.typeHierarchySupertypes(item: item)
    }

    func typeHierarchySubtypes(
        item: ValidatedHierarchyItem
    ) async throws -> [ValidatedHierarchyItem] {
        guard let service = service(forURL: item.url) else {
            return []
        }
        return try await service.typeHierarchySubtypes(item: item)
    }

    func handleLanguageSupportChanged(languageKey: String) {
        profileRegistry.reload()
        handleProfilesChanged()
        if services[languageKey] != nil {
            restart(profileIdentifier: languageKey)
        }
    }

    /// Executable-discovery counterpart to `handleLanguageSupportChanged`.
    /// Call this only when `LanguageSupportService.refresh()` finds that
    /// `languageKey`'s executable, previously unavailable, is now
    /// available — never for a profile configuration edit. Unlike
    /// `handleLanguageSupportChanged`, this never reloads the profile
    /// registry and never calls `LanguageSupportService.refresh()` (or
    /// anything that would), so it cannot recurse back into another
    /// discovery notification.
    ///
    /// For an already-open document matching `languageKey`: starts a
    /// service if none exists yet, restarts one that is stuck in a
    /// terminal failed state (`missing`/`crashed`/`stopped`/`disabled`)
    /// so `LanguageWorkspaceService.restart()` rediscovers the
    /// executable, and does nothing if a startup is already in flight or
    /// the service is already starting/indexing/ready/busy — repeated
    /// Settings refreshes must not restart a healthy service.
    func handleLanguageServerExecutableAvailable(languageKey: String) {
        guard isTrusted,
              let profile = profileRegistry.snapshot.profile(
                  identifier: languageKey
              ),
              profile.languageServer != nil else {
            return
        }
        guard services[languageKey] != nil else {
            // No service has ever been created for this profile (e.g. no
            // document was open when it was last missing). Clear any
            // stale status and retry for whichever open documents match.
            statesByProfile.removeValue(forKey: languageKey)
            onStateChange?()
            Task {
                await self.resynchronizeOpenDocuments(for: profile)
            }
            return
        }
        guard startupTasks[languageKey] == nil else {
            // A startup attempt is already in flight; let it resolve
            // naturally rather than racing a second one.
            return
        }
        switch statesByProfile[languageKey] {
        case .missing, .crashed, .stopped, .disabled, .none:
            restart(profileIdentifier: languageKey)
        case .starting, .indexing, .ready, .busy, .stopping:
            break
        }
    }

    func handleTrustGranted() {
        guard isTrusted else {
            return
        }
        resynchronizeAllOpenDocuments()
    }

    func handleTrustRevoked() {
        semanticDecorationTasks.values.forEach { $0.cancel() }
        semanticDecorationTasks.removeAll()
        for identifier in diagnosticsStore.snapshot.diagnosticsByOwner.keys {
            diagnosticsStore.clear(owner: identifier)
        }
        let affectedIdentifiers = Set(startupTasks.keys).union(services.keys)
        for key in affectedIdentifiers {
            startupGenerations[key, default: 0] += 1
        }
        startupTasks.values.forEach { $0.cancel() }
        startupTasks.removeAll()
        guard !services.isEmpty else {
            return
        }
        let runningServices = services
        services.removeAll()
        serviceProfiles.removeAll()
        for key in statesByProfile.keys {
            statesByProfile[key] = .disabled(
                reason: "Workspace trust revoked"
            )
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
                    DiagnosticContextField(
                        name: "workspaceRoot",
                        category: .fullPath,
                        value: identity.root.path
                    )
                ]
            )
        }
    }

    private func resolvedProfile(
        for snapshot: SourceSnapshot
    ) -> ResolvedLanguageProfile? {
        profileRegistry.resolve(snapshot: snapshot)
    }

    private func resolvedProfile(
        forOpenURL url: URL
    ) -> ResolvedLanguageProfile? {
        let standardizedURL = url.standardizedFileURL
        for weakController in controllersByRelativePath.values {
            guard let snapshot = weakController.controller?.snapshot,
                  snapshot.url.standardizedFileURL == standardizedURL else {
                continue
            }
            return resolvedProfile(for: snapshot)
        }
        return profileRegistry.resolve(url: url)
    }

    private func startedService(
        for snapshot: SourceSnapshot
    ) -> LanguageWorkspaceService? {
        guard let resolved = resolvedProfile(for: snapshot) else {
            return nil
        }
        return services[resolved.profile.identifier]
    }

    private func startServiceIfNeeded(
        resolved: ResolvedLanguageProfile
    ) async -> LanguageWorkspaceService? {
        let profile = resolved.profile
        let key = profile.identifier
        if let existing = services[key] {
            if let startupTask = startupTasks[key] {
                await startupTask.value
            }
            return isTrusted && services[key] === existing ? existing : nil
        }
        guard isTrusted, profile.languageServer != nil else {
            return nil
        }

        startupGenerations[key, default: 0] += 1
        let generation = startupGenerations[key, default: 0]
        let newService: LanguageWorkspaceService
        do {
            newService = try LanguageProfileServiceFactory.makeService(
                for: profile,
                identity: identity,
                trustStore: trustStore,
                overrideStore: overrideStore,
                onStateChange: { [weak self] newState in
                    Task { @MainActor in
                        guard let self,
                              self.startupGenerations[key] == generation,
                              self.services[key] != nil else {
                            return
                        }
                        if newState == .starting,
                           self.statesByProfile[key] != nil {
                            self.diagnosticsStore.clear(owner: key)
                        }
                        self.statesByProfile[key] = newState
                        self.recordStateChangeIfDegraded(
                            profile: profile,
                            newState
                        )
                        if case .missing = newState {
                            self.onMissingServer?(profile)
                        }
                        self.onStateChange?()
                    }
                },
                onDiagnostics: { [weak self] url, diagnostics in
                    Task { @MainActor in
                        guard let self,
                              self.startupGenerations[key] == generation,
                              self.services[key] != nil else {
                            return
                        }
                        self.diagnosticsStore.replace(
                            owner: key,
                            resource: url,
                            diagnostics: diagnostics
                        )
                    }
                },
                onWorkspaceDiagnosticsFailure: { [weak self] reason in
                    Task { @MainActor in
                        guard let self,
                              self.startupGenerations[key] == generation,
                              self.services[key] != nil else {
                            return
                        }
                        self.recordWorkspaceDiagnosticsFailure(
                            profile: profile,
                            reason: reason
                        )
                    }
                }
            )
        } catch {
            statesByProfile[key] = .missing(
                reason: error.localizedDescription
            )
            onMissingServer?(profile)
            onStateChange?()
            return nil
        }

        services[key] = newService
        serviceProfiles[key] = profile
        let startupTask = Task {
            do {
                try await newService.start()
            } catch {
                // The service state callback reports discovery/start failures.
            }
        }
        startupTasks[key] = startupTask
        await startupTask.value
        if startupGenerations[key] == generation {
            startupTasks.removeValue(forKey: key)
        }
        guard isTrusted,
              startupGenerations[key] == generation,
              services[key] === newService else {
            return nil
        }
        return newService
    }

    private func syncAndDecorate(
        resolved: ResolvedLanguageProfile,
        relativePath: String,
        controller: CodeDocumentViewController
    ) async {
        let snapshot = controller.snapshot
        guard let service = await startServiceIfNeeded(
            resolved: resolved
        ) else {
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
        guard let liveController =
                controllersByRelativePath[relativePath]?.controller,
              liveController.snapshot.version == snapshot.version else {
            return
        }
        scheduleSemanticDecoration(
            profileIdentifier: resolved.profile.identifier,
            relativePath: relativePath,
            controller: liveController,
            service: service
        )
    }

    private func scheduleSemanticDecoration(
        profileIdentifier: String,
        relativePath: String,
        controller: CodeDocumentViewController,
        service: LanguageWorkspaceService,
        delay: Duration = .zero
    ) {
        semanticDecorationTasks[relativePath]?.cancel()
        let snapshot = controller.snapshot
        semanticDecorationTasks[relativePath] = Task {
            @MainActor [weak self, weak controller] in
            if delay != .zero {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            guard let self, let controller,
                  self.controllersByRelativePath[relativePath]?.controller
                    === controller,
                  controller.snapshot.version == snapshot.version else {
                return
            }
            await self.applySemanticDecoration(
                profileIdentifier: profileIdentifier,
                relativePath: relativePath,
                controller: controller,
                service: service,
                snapshot: snapshot
            )
        }
    }

    private func applySemanticDecoration(
        profileIdentifier: String,
        relativePath: String,
        controller: CodeDocumentViewController,
        service: LanguageWorkspaceService,
        snapshot: SourceSnapshot
    ) async {
        do {
            let tokens = try await service.semanticTokens(snapshot: snapshot)
            guard let stillLiveController =
                    controllersByRelativePath[relativePath]?.controller,
                  stillLiveController.snapshot.version
                    == snapshot.version else {
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
                  controllersByRelativePath[relativePath]?.controller
                    === controller,
                  controller.snapshot.version == snapshot.version else {
                return
            }
            scheduleSemanticDecoration(
                profileIdentifier: profileIdentifier,
                relativePath: relativePath,
                controller: controller,
                service: service,
                delay: .milliseconds(250)
            )
        } catch LanguageWorkspaceServiceError.capabilityUnavailable {
            // Tree-sitter highlighting remains active without semantic tokens.
        } catch {
            // Connection state exposes failures; syntax remains independent.
        }
    }

    private func recordStateChangeIfDegraded(
        profile: LanguageProfile,
        _ newState: LanguageServerState
    ) {
        let reason: String
        switch newState {
        case .crashed(let message), .disabled(let message):
            reason = message
        default:
            return
        }

        Task {
            await diagnosticsLog.record(
                subsystem: .languageServer,
                level: .warning,
                message: Localized.string(
                    "\(profile.identifier) language server entered \(newState.displayName.lowercased()) state",
                    comment: "Diagnostics log message recorded when a language profile's server transitions to a degraded state"
                ),
                context: [
                    DiagnosticContextField(
                        name: "workspaceRoot",
                        category: .fullPath,
                        value: identity.root.path
                    ),
                    DiagnosticContextField(
                        name: "reason",
                        category: .diagnosticMessage,
                        value: reason
                    )
                ]
            )
        }
    }

    private func recordWorkspaceDiagnosticsFailure(
        profile: LanguageProfile,
        reason: String
    ) {
        Task {
            await diagnosticsLog.record(
                subsystem: .languageServer,
                level: .warning,
                message: Localized.string(
                    "\(profile.identifier) workspace diagnostics request failed",
                    comment: "Diagnostics log message recorded when a language server's workspace diagnostics request fails"
                ),
                context: [
                    DiagnosticContextField(
                        name: "workspaceRoot",
                        category: .fullPath,
                        value: identity.root.path
                    ),
                    DiagnosticContextField(
                        name: "reason",
                        category: .diagnosticMessage,
                        value: reason
                    )
                ]
            )
        }
    }

    private func handleProfilesChanged() {
        profileRegistry.reload()
        let activeProfiles = Dictionary(
            uniqueKeysWithValues: languageServerProfiles.map {
                ($0.identifier, $0)
            }
        )
        var servicesToStop: [LanguageWorkspaceService] = []
        let changedServiceIdentifiers = services.compactMap { identifier, _ in
            activeProfiles[identifier] == serviceProfiles[identifier]
                ? nil
                : identifier
        }
        for identifier in changedServiceIdentifiers {
            guard let service = services[identifier] else {
                continue
            }
            startupGenerations[identifier, default: 0] += 1
            startupTasks.removeValue(forKey: identifier)?.cancel()
            services.removeValue(forKey: identifier)
            serviceProfiles.removeValue(forKey: identifier)
            statesByProfile.removeValue(forKey: identifier)
            diagnosticsStore.clear(owner: identifier)
            servicesToStop.append(service)
        }
        semanticDecorationTasks.values.forEach { $0.cancel() }
        semanticDecorationTasks.removeAll()
        onStateChange?()
        Task {
            for service in servicesToStop {
                await service.stop()
            }
            self.resynchronizeAllOpenDocuments()
        }
    }

    private func cancelDecorations(for profileIdentifier: String) {
        for (relativePath, weakController) in controllersByRelativePath {
            guard let snapshot = weakController.controller?.snapshot,
                  resolvedProfile(for: snapshot)?.profile.identifier
                    == profileIdentifier else {
                continue
            }
            semanticDecorationTasks.removeValue(
                forKey: relativePath
            )?.cancel()
        }
    }

    private func resynchronizeAllOpenDocuments() {
        guard isTrusted else {
            return
        }
        for (relativePath, weakController) in controllersByRelativePath {
            guard let controller = weakController.controller,
                  let resolved = resolvedProfile(for: controller.snapshot),
                  resolved.profile.languageServer != nil else {
                continue
            }
            Task {
                await self.syncAndDecorate(
                    resolved: resolved,
                    relativePath: relativePath,
                    controller: controller
                )
            }
        }
    }

    private func resynchronizeOpenDocuments(
        for profile: LanguageProfile
    ) async {
        for (relativePath, weakController) in controllersByRelativePath {
            guard let controller = weakController.controller,
                  let resolved = resolvedProfile(for: controller.snapshot),
                  resolved.profile.identifier == profile.identifier else {
                continue
            }
            await syncAndDecorate(
                resolved: resolved,
                relativePath: relativePath,
                controller: controller
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
