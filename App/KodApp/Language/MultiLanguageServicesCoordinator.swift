import CodeViewport
import DiagnosticsCore
import Foundation
import LanguageAdapters
import LanguageClient
import SettingsCore
import SourceModel
import WorkspaceCore

/// Cancellation handle for a document close that has been scheduled but has
/// not started its `didClose` yet. Declared outside the coordinator so it is
/// plainly non-isolated: `MultiLanguageServicesCoordinator`'s default
/// scheduler constructs one from inside a closure that is not itself
/// main-actor isolated.
struct LanguageDocumentCloseSchedule {
    let cancel: @MainActor () -> Void

    init(cancel: @escaping @MainActor () -> Void) {
        self.cancel = cancel
    }
}

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
    /// Provider-ID-to-service routing for cross-file results. A definition,
    /// workspace symbol, or hierarchy item is routed back through the
    /// provider that produced it, never through whichever profile happens
    /// to claim its target file: a cross-language target would otherwise
    /// reach a different server, with a different negotiated position
    /// encoding and no knowledge of the item's opaque `data`.
    private var providerRouter = LanguageProviderRouter<LanguageWorkspaceService>()
    /// The provider identity currently registered for each profile. A
    /// replacement service gets a new identity, so handles bound to its
    /// predecessor stop routing rather than silently reaching its successor.
    private var providerIDsByProfile: [String: LanguageProviderID] = [:]
    private var startupTasks: [String: Task<Void, Never>] = [:]
    private var startupGenerations: [String: Int] = [:]
    private var statesByProfile: [String: LanguageServerState] = [:]
    /// Every live `CodeDocumentViewController` showing a file, keyed by the
    /// canonical standardized document URL. The same file can legitimately
    /// be open in several editor groups at once (split panes), so this is a
    /// list per URL rather than the single weak entry per relative path
    /// that used to silently drop every pane but the newest one.
    private var registrationsByURL: [URL: [DocumentRegistration]] = [:]
    /// One in-flight semantic-token request per *registration* — one pane's
    /// cancellation or close must never cancel another pane's decoration
    /// work for the same file.
    private var semanticDecorationTasks: [
        DocumentRegistrationID: Task<Void, Never>
    ] = [:]
    /// What a language service has actually accepted per document URL,
    /// recorded only *after* `synchronize` returns, so a close knows
    /// whether the server really holds the document.
    private var synchronizedDocuments: [URL: DocumentSynchronizationRecord] = [:]
    /// The one in-flight `synchronize` per document URL. Every other pane
    /// arriving for the same (profile, version) awaits this task instead of
    /// issuing its own didOpen/didChange, and no pane may request document
    /// features until it has resolved successfully.
    private var synchronizationsInFlight: [URL: DocumentSynchronization] = [:]
    /// Closes that are either waiting out `documentCloseGracePeriod` or
    /// already running their `didClose`. Retained until the close operation
    /// completes so a reopen can either cancel a still-sleeping close or
    /// await one that has already begun.
    private var pendingDocumentCloses: [URL: PendingDocumentClose] = [:]
    private var nextRegistrationValue: UInt64 = 0
    private var nextOperationGeneration: UInt64 = 0
    private var nextTrackedTaskValue: UInt64 = 0
    /// Every unstructured task the coordinator itself starts (document
    /// synchronization, restarts, profile-change and trust-revocation
    /// service stops, close re-evaluation). Tracked so `stopAll()` can
    /// cancel and await all of them instead of letting them outlive the
    /// coordinator's own shutdown.
    private var trackedTasks: [UInt64: Task<Void, Never>] = [:]
    /// Profile-replacement stop/close work is serialized separately from
    /// resynchronization so every service start can safely await this barrier.
    private var profileReplacementBarrier: Task<Void, Never>?
    private var profileReconciliationGeneration: UInt64 = 0
    private var profileObserver: SettingsObservation?
    /// The single in-flight `stopAll()`; concurrent and repeated calls
    /// join it rather than racing a second shutdown.
    private var shutdownTask: Task<Void, Never>?
    private(set) var isShutDown = false
    /// How many times a pane joined an already in-flight synchronization
    /// instead of issuing a duplicate request. Exposed so tests can observe
    /// coalescing deterministically rather than by sleeping.
    private(set) var synchronizationJoinCount = 0

    var onStateChange: (() -> Void)?
    /// Snapshot-normalized diagnostics for the currently open editors.
    /// Raw, workspace-wide diagnostics live in `diagnosticsStore` instead.
    var onNormalizedDiagnostics: ((URL, [NormalizedDiagnostic]) -> Void)?
    var onUnknownFileType: ((URL) -> Void)?
    var onDocumentReplayFailure: ((LanguageProfile, String) -> Void)?
    /// Fires with the standardized document URL once its *final* live pane
    /// has been unregistered and the document closed on its language
    /// service. Editor-facing markers are cleared with it; workspace-wide
    /// Problems entries in `diagnosticsStore` deliberately survive, exactly
    /// like a file that was never opened at all.
    var onDocumentClosed: ((URL) -> Void)?
    /// SPEC 6.3: "Closing the last view sends `didClose` after a short
    /// reuse grace period." Closing a tab and immediately reopening the
    /// same file — or a split-tree rebuild that re-creates the pane —
    /// therefore keeps the document open on the server instead of churning
    /// through didClose/didOpen.
    var documentCloseGracePeriod: Duration = .milliseconds(250)
    /// Injectable timer behind the grace period. Production sleeps for
    /// `delay` and then fires; tests substitute a scheduler that captures
    /// `fire` and invokes (or drops) it explicitly, so close timing is
    /// deterministic and no test ever sleeps.
    var scheduleDocumentClose: (
        _ delay: Duration,
        _ fire: @escaping @Sendable @MainActor () -> Void
    ) -> LanguageDocumentCloseSchedule = { delay, fire in
        let task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else {
                return
            }
            fire()
        }
        return LanguageDocumentCloseSchedule { task.cancel() }
    }

    /// The callbacks the coordinator binds into every language service it
    /// creates, grouped so service construction itself can be injected.
    struct LanguageServiceBinding {
        let providerID: LanguageProviderID
        let onStateChange: @Sendable (LanguageServerState) -> Void
        let onDiagnostics: @Sendable (URL, [Diagnostic]) -> Void
        let onNormalizedDiagnostics: @Sendable (URL, [NormalizedDiagnostic]) -> Void
        let onWorkspaceDiagnosticsFailure: @Sendable (String) -> Void
        let onDocumentReplayFailure: @Sendable ([LanguageDocumentReplayFailure]) -> Void
    }

    /// Replaces profile-driven service construction. Production leaves
    /// this `nil` and resolves the profile's executable through
    /// `LanguageProfileServiceFactory`; tests substitute a factory so
    /// headless coverage never launches a real server process.
    var makeLanguageService: (
        (_ profile: LanguageProfile, _ binding: LanguageServiceBinding)
            throws -> LanguageWorkspaceService
    )?

    private func makeService(
        for profile: LanguageProfile,
        binding: LanguageServiceBinding
    ) throws -> LanguageWorkspaceService {
        if let makeLanguageService {
            return try makeLanguageService(profile, binding)
        }
        return try LanguageProfileServiceFactory.makeService(
            for: profile,
            identity: identity,
            trustStore: trustStore,
            overrideStore: overrideStore,
            providerID: binding.providerID,
            onStateChange: binding.onStateChange,
            onDiagnostics: binding.onDiagnostics,
            onNormalizedDiagnostics: binding.onNormalizedDiagnostics,
            onWorkspaceDiagnosticsFailure: binding.onWorkspaceDiagnosticsFailure,
            onDocumentReplayFailure: binding.onDocumentReplayFailure
        )
    }

    init(
        identity: WorkspaceIdentity,
        trustStore: WorkspaceTrustStore,
        profileRegistry: LanguageProfileRegistry,
        overrideStore: LanguageServerOverrideStore,
        diagnosticsLog: BoundedEventLog,
        diagnosticsStore: WorkspaceDiagnosticsStore
    ) {
        self.identity = identity
        self.trustStore = trustStore
        self.profileRegistry = profileRegistry
        self.overrideStore = overrideStore
        self.diagnosticsLog = diagnosticsLog
        self.diagnosticsStore = diagnosticsStore
        self.profileObserver = profileRegistry.observeChanges {
            [weak self] in
            self?.handleProfilesChanged()
        }
    }

    private var isTrusted: Bool {
        trustStore.isTrusted(identity)
    }

    /// Starts one coordinator-owned unstructured task and retains it
    /// until it finishes, so `stopAll()` can cancel and await everything
    /// this coordinator set in motion. Work requested after shutdown is
    /// dropped rather than started.
    @discardableResult
    private func track(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never>? {
        guard !isShutDown else {
            return nil
        }
        nextTrackedTaskValue &+= 1
        let identifier = nextTrackedTaskValue
        let task = Task { @MainActor [weak self] in
            await operation()
            self?.trackedTasks.removeValue(forKey: identifier)
        }
        trackedTasks[identifier] = task
        return task
    }

    /// Explicit, idempotent shutdown for the whole workspace's language
    /// services (SPEC 6.2). Cancels and awaits every piece of work this
    /// coordinator owns — startup, per-registration semantic decoration,
    /// in-flight synchronization, scheduled and running document closes,
    /// decoration retries, and profile restart/replacement work — then
    /// awaits `stop()` on every service before returning. Concurrent and
    /// repeated calls join the same operation instead of racing.
    func stopAll() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        guard !isShutDown else {
            return
        }
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.performShutdown()
        }
        shutdownTask = task
        await task.value
    }

    /// Spelling used by app lifecycle code; identical to `stopAll()`.
    func shutdown() async {
        await stopAll()
    }

    private func performShutdown() async {
        isShutDown = true
        if let profileObserver {
            profileObserver.cancel()
            self.profileObserver = nil
        }

        // Nothing new may be scheduled from here on; every generation is
        // advanced first so any callback that resumes mid-shutdown is
        // already stale.
        for key in Set(startupTasks.keys).union(services.keys) {
            startupGenerations[key, default: 0] += 1
        }

        // Closes still waiting out the grace period never run; closes
        // already issuing `didClose` are awaited so the server is not
        // left holding a document Kod has forgotten.
        let closes = pendingDocumentCloses
        pendingDocumentCloses = closes.filter { $0.value.closeTask != nil }
        var runningCloses: [Task<Void, Never>] = []
        for (_, pending) in closes {
            pending.schedule?.cancel()
            if let closeTask = pending.closeTask {
                runningCloses.append(closeTask)
            }
        }

        let semanticTasks = Array(semanticDecorationTasks.values)
        semanticDecorationTasks.removeAll()
        semanticTasks.forEach { $0.cancel() }

        let synchronizations = synchronizationsInFlight.values.map(\.task)
        synchronizationsInFlight.removeAll()
        synchronizations.forEach { $0.cancel() }

        let startups = Array(startupTasks.values)
        startupTasks.removeAll()
        startups.forEach { $0.cancel() }

        let pendingWork = Array(trackedTasks.values)
        trackedTasks.removeAll()
        pendingWork.forEach { $0.cancel() }

        for task in runningCloses {
            await task.value
        }
        for task in semanticTasks {
            await task.value
        }
        for task in synchronizations {
            _ = await task.value
        }
        for task in startups {
            await task.value
        }
        for task in pendingWork {
            await task.value
        }
        profileReplacementBarrier = nil
        pendingDocumentCloses.removeAll()

        // Editor-facing markers are cleared for every document that was
        // still open; workspace-wide Problems entries deliberately
        // survive, exactly like a file that was never opened at all.
        clearNormalizedDiagnosticsForOpenDocuments()
        registrationsByURL.removeAll()
        synchronizedDocuments.removeAll()

        let runningServices = services
        services.removeAll()
        serviceProfiles.removeAll()
        providerRouter.removeAll()
        providerIDsByProfile.removeAll()
        statesByProfile.removeAll()
        onStateChange?()

        for service in runningServices.values {
            await service.stop()
        }
    }

    /// Awaits the coordinator-owned work started so far without
    /// cancelling anything. Exposed so tests can observe document
    /// synchronization and restart work deterministically.
    func waitForPendingWork() async {
        while !trackedTasks.isEmpty {
            for task in Array(trackedTasks.values) {
                await task.value
            }
        }
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
        guard !isShutDown else {
            return
        }
        guard let resolved = resolvedProfile(for: controller.snapshot) else {
            onUnknownFileType?(controller.snapshot.url)
            return
        }
        guard resolved.profile.languageServer != nil else {
            return
        }
        let registrationID = register(
            controller: controller,
            relativePath: relativePath
        )
        guard isTrusted else {
            return
        }
        track { [weak self] in
            await self?.syncAndDecorate(
                resolved: resolved,
                registrationID: registrationID
            )
        }
    }

    /// Counterpart to `handleDocumentReady`: the editor group is about to
    /// permanently discard `controller`'s content (tab closed, replaced,
    /// tombstoned, or its group removed). Only this pane's in-flight work
    /// is cancelled; the document stays open on the language service for as
    /// long as any other pane still shows the same file, and only the final
    /// pane's removal sends `textDocument/didClose`.
    ///
    /// Never called for a live tab transfer between editor groups: the same
    /// controller keeps running in the destination group, so there is no
    /// close/open churn on the server.
    func handleDocumentClosed(
        relativePath _: String,
        controller: CodeDocumentViewController
    ) {
        unregister(controller: controller)
    }

    // MARK: - Document registration

    /// Registers (or refreshes) `controller` as a live pane for its
    /// document URL and returns its stable registration identity. Repeated
    /// calls for the same controller — every reload emits one — reuse the
    /// existing registration rather than accumulating duplicates.
    private func register(
        controller: CodeDocumentViewController,
        relativePath: String
    ) -> DocumentRegistrationID {
        let url = controller.snapshot.url.standardizedFileURL
        // Reopening reuses the still-open document. A close that has not
        // started yet is cancelled outright; one whose didClose is already
        // running cannot be — the synchronization path awaits it instead,
        // so didOpen can never overtake it.
        cancelScheduledDocumentClose(at: url)
        var registrations = registrationsByURL[url] ?? []
        if let index = registrations.firstIndex(
            where: { $0.controller === controller }
        ) {
            registrations[index].relativePath = relativePath
            registrationsByURL[url] = registrations
            // A dead pane for another file may have been released since the
            // last registration; sweep it now so nothing accumulates.
            pruneDeadRegistrations()
            return registrations[index].id
        }
        nextRegistrationValue &+= 1
        let id = DocumentRegistrationID(value: nextRegistrationValue)
        registrations.append(
            DocumentRegistration(
                id: id,
                controller: controller,
                relativePath: relativePath
            )
        )
        registrationsByURL[url] = registrations
        // Pruning *after* inserting the live registration matters: a reload
        // registers the replacement controller while the superseded one may
        // already be deallocated, and closing the document in between would
        // produce a pointless didClose/didOpen round trip.
        pruneDeadRegistrations()
        return id
    }

    private func unregister(controller: CodeDocumentViewController) {
        let url = controller.snapshot.url.standardizedFileURL
        if var registrations = registrationsByURL[url] {
            let removed = registrations.filter {
                $0.controller === controller || $0.controller == nil
            }
            registrations.removeAll {
                $0.controller === controller || $0.controller == nil
            }
            cancelSemanticDecorations(for: removed)
            if registrations.isEmpty {
                registrationsByURL.removeValue(forKey: url)
                closeDocument(at: url)
            } else {
                registrationsByURL[url] = registrations
            }
        }
        pruneDeadRegistrations()
    }

    /// Drops registrations whose controller has been released without an
    /// explicit close (e.g. an editor group deallocated wholesale), so the
    /// table never accumulates dead weak entries and their semantic-token
    /// tasks never outlive the pane that requested them.
    private func pruneDeadRegistrations() {
        for (url, registrations) in registrationsByURL {
            let dead = registrations.filter { $0.controller == nil }
            guard !dead.isEmpty else {
                continue
            }
            cancelSemanticDecorations(for: dead)
            let live = registrations.filter { $0.controller != nil }
            if live.isEmpty {
                registrationsByURL.removeValue(forKey: url)
                closeDocument(at: url)
            } else {
                registrationsByURL[url] = live
            }
        }
    }

    private func cancelSemanticDecorations(
        for registrations: [DocumentRegistration]
    ) {
        for registration in registrations {
            semanticDecorationTasks.removeValue(
                forKey: registration.id
            )?.cancel()
        }
    }

    // MARK: - Document close lifecycle

    /// Schedules `url`'s close for after SPEC 6.3's short reuse grace
    /// period. The scheduled close is represented by a generation-tagged
    /// entry that lives until the whole operation completes, so a reopen
    /// can tell "still sleeping, cancel it" from "didClose already running,
    /// await it".
    private func closeDocument(at url: URL) {
        guard !isShutDown else {
            return
        }
        if let pending = pendingDocumentCloses[url] {
            guard pending.closeTask == nil else {
                // A close is already running. It owns the URL until it
                // finishes; re-evaluate afterwards so a reopen-then-close
                // that happened inside that window is not dropped and
                // cannot leave the document open on the server forever.
                let runningClose = pending.closeTask
                track { [weak self] in
                    await runningClose?.value
                    guard let self,
                          !self.isShutDown,
                          self.registrationsByURL[url] == nil,
                          self.synchronizedDocuments[url] != nil else {
                        return
                    }
                    self.closeDocument(at: url)
                }
                return
            }
            pending.schedule?.cancel()
        }
        nextOperationGeneration &+= 1
        let generation = nextOperationGeneration
        let schedule = scheduleDocumentClose(documentCloseGracePeriod) {
            [weak self] in
            self?.fireScheduledDocumentClose(at: url, generation: generation)
        }
        pendingDocumentCloses[url] = PendingDocumentClose(
            generation: generation,
            schedule: schedule,
            closeTask: nil
        )
    }

    /// Cancels a close that has not started its `didClose` yet. A close
    /// already in progress is deliberately left alone — cancelling it
    /// mid-flight is exactly the race that let a reopen's didOpen be
    /// followed by a stale didClose.
    private func cancelScheduledDocumentClose(at url: URL) {
        guard let pending = pendingDocumentCloses[url],
              pending.closeTask == nil else {
            return
        }
        pending.schedule?.cancel()
        pendingDocumentCloses.removeValue(forKey: url)
    }

    /// The grace period elapsed. A fire from a superseded or already-
    /// started schedule is inert, and a file that was reopened in the
    /// meantime is never closed.
    private func fireScheduledDocumentClose(at url: URL, generation: UInt64) {
        guard let pending = pendingDocumentCloses[url],
              pending.generation == generation,
              pending.closeTask == nil else {
            return
        }
        guard registrationsByURL[url] == nil else {
            pendingDocumentCloses.removeValue(forKey: url)
            return
        }
        beginDocumentClose(at: url, generation: generation)
    }

    /// Runs the close itself. Any synchronization already in flight for
    /// this file is awaited *first*: closing around it would let a didOpen
    /// land after didClose and leave a document open on the server that
    /// nobody owns. Only once nothing is in flight — and the file is still
    /// unowned — is the completed synchronization record read and
    /// `didClose` issued, followed by the editor-facing marker clear and
    /// the close output. The pending entry and the synchronization record
    /// are dropped only after all of that has completed. The workspace-wide
    /// diagnostics store is left untouched: Problems keeps reporting a file
    /// nobody has open.
    private func beginDocumentClose(at url: URL, generation: UInt64) {
        let closeTask = Task { @MainActor [weak self] in
            await self?.awaitSynchronizations(at: url)
            guard let self else {
                return
            }
            guard self.registrationsByURL[url] == nil else {
                // Reopened while we waited: the document stays open, and
                // its markers are deliberately left alone.
                self.finishDocumentClose(at: url, generation: generation)
                return
            }
            let record = self.synchronizedDocuments[url]
            if let record, let service = self.services[record.profileIdentifier] {
                do {
                    try await service.didClose(url: url)
                } catch {
                    // Recorded rather than swallowed; the document is still
                    // dropped locally so a later reopen resynchronizes.
                    self.recordDocumentCloseFailure(
                        profileIdentifier: record.profileIdentifier,
                        url: url,
                        reason: error.localizedDescription
                    )
                }
            }
            self.synchronizedDocuments.removeValue(forKey: url)
            self.onNormalizedDiagnostics?(url, [])
            self.onDocumentClosed?(url)
            self.finishDocumentClose(at: url, generation: generation)
        }
        pendingDocumentCloses[url] = PendingDocumentClose(
            generation: generation,
            schedule: nil,
            closeTask: closeTask
        )
    }

    private func finishDocumentClose(at url: URL, generation: UInt64) {
        if pendingDocumentCloses[url]?.generation == generation {
            pendingDocumentCloses.removeValue(forKey: url)
        }
    }

    /// Awaits whatever synchronization is in flight for `url`. A close must
    /// never overtake a didOpen/didChange that has already been issued, and
    /// no *new* synchronization can start while a close is running (its
    /// caller blocks in `settleDocumentClose(before:)` first), so this
    /// settles in bounded time.
    private func awaitSynchronizations(at url: URL) async {
        var awaitedGenerations: Set<UInt64> = []
        while let inFlight = synchronizationsInFlight[url],
              !awaitedGenerations.contains(inFlight.generation) {
            awaitedGenerations.insert(inFlight.generation)
            _ = await inFlight.task.value
        }
    }

    /// Settles `url`'s close before a synchronization runs: a close that
    /// has not started is cancelled (the file is open again), and one that
    /// is already running is awaited to completion, so `didOpen` can never
    /// be overtaken by a `didClose` for the same document.
    private func settleDocumentClose(before url: URL) async {
        while let pending = pendingDocumentCloses[url] {
            guard let closeTask = pending.closeTask else {
                pending.schedule?.cancel()
                pendingDocumentCloses.removeValue(forKey: url)
                return
            }
            await closeTask.value
        }
    }

    /// Awaits an in-progress close for `url` without cancelling anything.
    /// Used by tests to observe close completion deterministically.
    func waitForDocumentClose(forURL url: URL) async {
        while let closeTask = pendingDocumentCloses[
            url.standardizedFileURL
        ]?.closeTask {
            await closeTask.value
        }
    }

    /// Closes that are scheduled or running right now. Exposed so tests
    /// can assert nothing survives `stopAll()`.
    var pendingDocumentCloseCount: Int {
        pendingDocumentCloses.count
    }

    /// Document synchronizations in flight right now.
    var inFlightSynchronizationCount: Int {
        synchronizationsInFlight.count
    }

    /// Coordinator-owned unstructured tasks still running right now.
    var pendingWorkCount: Int {
        trackedTasks.count
    }

    private func recordDocumentCloseFailure(
        profileIdentifier: String,
        url: URL,
        reason: String
    ) {
        Task {
            await diagnosticsLog.record(
                subsystem: .languageServer,
                level: .warning,
                message: Localized.string(
                    "\(profileIdentifier) language server failed to close a document",
                    comment: "Diagnostics log message recorded when a textDocument/didClose request fails"
                ),
                context: [
                    DiagnosticContextField(
                        name: "workspaceRoot",
                        category: .fullPath,
                        value: identity.root.path
                    ),
                    DiagnosticContextField(
                        name: "document",
                        category: .fullPath,
                        value: url.path
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

    private func liveRegistrations()
    -> [(url: URL, registration: DocumentRegistration)] {
        var live: [(url: URL, registration: DocumentRegistration)] = []
        for (url, registrations) in registrationsByURL {
            for registration in registrations where registration.controller != nil {
                live.append((url: url, registration: registration))
            }
        }
        return live
    }

    private func registration(
        with id: DocumentRegistrationID
    ) -> DocumentRegistration? {
        for registrations in registrationsByURL.values {
            if let match = registrations.first(where: { $0.id == id }) {
                return match
            }
        }
        return nil
    }

    private func liveController(
        with id: DocumentRegistrationID
    ) -> CodeDocumentViewController? {
        registration(with: id)?.controller
    }

    /// Live panes currently showing `url`. Exposed for tests, which assert
    /// that two split panes on one file are both tracked, that closing one
    /// leaves the other, and that nothing accumulates.
    func liveDocumentControllers(
        forURL url: URL
    ) -> [CodeDocumentViewController] {
        (registrationsByURL[url.standardizedFileURL] ?? []).compactMap(\.controller)
    }

    /// Applies one semantic-token result to *every* live pane showing
    /// `url` at `snapshotVersion`, each against its own theme, and returns
    /// how many panes accepted the layer. Fan-out is the point: two panes
    /// showing one file must both get decorated, and neither may clobber
    /// the other's compositor state.
    @discardableResult
    func applySemanticTokens(
        _ tokens: [SemanticToken],
        url: URL,
        snapshotVersion: Int
    ) -> Int {
        var applied = 0
        for registration in registrationsByURL[url.standardizedFileURL] ?? [] {
            guard let controller = registration.controller,
                  controller.snapshot.version == snapshotVersion else {
                continue
            }
            let layer = SemanticTokenDecorationSource.layer(
                fromTokens: tokens,
                theme: controller.theme,
                snapshotVersion: snapshotVersion,
                layerVersion: 1
            )
            if controller.viewport.applyDecorationLayer(layer) {
                applied += 1
            }
        }
        return applied
    }

    func restart(profileIdentifier: String) {
        guard !isShutDown,
              let service = services[profileIdentifier],
              let profile = profileRegistry.snapshot.profile(
                  identifier: profileIdentifier
              ) else {
            return
        }
        cancelDecorations(for: profileIdentifier)
        clearSemanticDecorations(for: profileIdentifier)
        // `LanguageWorkspaceService.restart()` drops every open document,
        // so the coordinator's "already open at this version" record must
        // go with it or the resynchronization below would skip didOpen.
        clearSynchronizationRecords(for: profileIdentifier)
        diagnosticsStore.clear(owner: profileIdentifier)
        track { [weak self] in
            do {
                try await service.restart()
            } catch {
                return
            }
            guard let self, !self.isShutDown else {
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
    ) -> (
        profileIdentifier: String,
        languageName: String,
        state: LanguageServerState
    )? {
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
        return (
            resolved.profile.identifier,
            resolved.profile.displayName,
            state
        )
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

    /// Converts a provider-bound cross-file location into a UTF-8 byte
    /// range inside `snapshot`, always through the encoding the
    /// *originating* provider negotiated. Deliberately pure and
    /// synchronous: looking the service up by `location.url` is exactly
    /// the bug this replaces — a Swift definition inside a TypeScript
    /// file, or a target whose own profile negotiated a different
    /// encoding, would otherwise be converted with the wrong one.
    func utf8Range(
        for location: ProviderBoundLocation,
        in snapshot: SourceSnapshot
    ) -> Range<Int>? {
        location.utf8Range(in: snapshot)
    }

    /// Converts an *unbound* raw LSP range — a published diagnostic, which
    /// is always reported for the file it belongs to by that file's own
    /// provider — using the position encoding negotiated with the service
    /// that owns the file. Falls back to the LSP default (UTF-16) only
    /// when no service exists for it, so navigation still works for files
    /// whose server never started. Cross-file results must use the bound
    /// overload instead.
    func utf8Range(
        for range: LSPRange,
        in snapshot: SourceSnapshot
    ) async -> Range<Int>? {
        guard let service = service(forURL: snapshot.url) else {
            return Self.utf8Range(range, in: snapshot, encoding: .utf16)
        }
        return await service.utf8Range(for: range, in: snapshot)
    }

    private static func utf8Range(
        _ range: LSPRange,
        in snapshot: SourceSnapshot,
        encoding: SourcePositionEncoding
    ) -> Range<Int>? {
        guard let start = try? snapshot.utf8Offset(
            for: SourcePosition(
                line: range.start.line,
                character: range.start.character
            ),
            encoding: encoding
        ), let end = try? snapshot.utf8Offset(
            for: SourcePosition(
                line: range.end.line,
                character: range.end.character
            ),
            encoding: encoding
        ), start <= end else {
            return nil
        }
        return start..<end
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

    /// Expands a call hierarchy item on the provider that produced it —
    /// verified live and at the same generation — so its opaque `data` is
    /// never sent to a server inferred from `item.url`.
    func callHierarchyIncomingCalls(
        item: ValidatedHierarchyItem
    ) async throws -> [ValidatedIncomingCall] {
        let service = try self.service(boundTo: item.provider)
        return try await service.callHierarchyIncomingCalls(item: item)
    }

    func callHierarchyOutgoingCalls(
        item: ValidatedHierarchyItem
    ) async throws -> [ValidatedOutgoingCall] {
        let service = try self.service(boundTo: item.provider)
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
        let service = try self.service(boundTo: item.provider)
        return try await service.typeHierarchySupertypes(item: item)
    }

    func typeHierarchySubtypes(
        item: ValidatedHierarchyItem
    ) async throws -> [ValidatedHierarchyItem] {
        let service = try self.service(boundTo: item.provider)
        return try await service.typeHierarchySubtypes(item: item)
    }

    // MARK: - Provider routing

    private func registerProvider(
        _ providerID: LanguageProviderID,
        service: LanguageWorkspaceService,
        for profileIdentifier: String
    ) {
        if let previous = providerIDsByProfile[profileIdentifier] {
            providerRouter.unregister(previous)
        }
        providerIDsByProfile[profileIdentifier] = providerID
        providerRouter.register(service, for: providerID)
    }

    private func unregisterProvider(for profileIdentifier: String) {
        guard let providerID = providerIDsByProfile
            .removeValue(forKey: profileIdentifier) else {
            return
        }
        providerRouter.unregister(providerID)
    }

    /// The provider identity currently serving `profileIdentifier`, or
    /// `nil` when no service has been created for it yet.
    func providerID(forProfileIdentifier profileIdentifier: String) -> LanguageProviderID? {
        providerIDsByProfile[profileIdentifier]
    }

    /// Routes a provider-bound result back to the service that produced
    /// it. Throws `LanguageProviderRoutingError.providerUnavailable` when
    /// that service is gone or has been replaced — never falls back to
    /// another provider, and never infers one from the result's URL.
    func service(
        boundTo binding: LanguageProviderBinding
    ) throws -> LanguageWorkspaceService {
        try providerRouter.service(for: binding)
    }

    /// Executable-discovery counterpart to profile-configuration changes.
    /// Call this only when `LanguageSupportService.refresh()` finds that
    /// `languageKey`'s executable, previously unavailable, is now
    /// available — never for a profile configuration edit. Unlike
    /// profile reconciliation, this never reloads the profile registry and
    /// never calls `LanguageSupportService.refresh()` (or anything that
    /// would), so it cannot recurse back into another discovery notification.
    ///
    /// For an already-open document matching `languageKey`: starts a
    /// service if none exists yet, restarts one that is stuck in a
    /// terminal failed state (`missing`/`crashed`/`stopped`/`disabled`)
    /// so `LanguageWorkspaceService.restart()` rediscovers the
    /// executable, and does nothing if a startup is already in flight or
    /// the service is already starting/indexing/ready/busy — repeated
    /// Settings refreshes must not restart a healthy service.
    func handleLanguageServerExecutableAvailable(languageKey: String) {
        guard !isShutDown,
              isTrusted,
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
            track { [weak self] in
                await self?.resynchronizeOpenDocuments(for: profile)
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
        guard !isShutDown, isTrusted else {
            return
        }
        resynchronizeAllOpenDocuments()
    }

    func handleTrustRevoked() {
        guard !isShutDown else {
            return
        }
        semanticDecorationTasks.values.forEach { $0.cancel() }
        semanticDecorationTasks.removeAll()
        clearSemanticDecorationsForOpenDocuments()
        synchronizedDocuments.removeAll()
        clearNormalizedDiagnosticsForOpenDocuments()
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
        providerRouter.removeAll()
        providerIDsByProfile.removeAll()
        for key in statesByProfile.keys {
            statesByProfile[key] = .disabled(
                reason: "Workspace trust revoked"
            )
        }
        onStateChange?()
        track { [weak self] in
            for service in runningServices.values {
                await service.stop()
            }
            guard let self else {
                return
            }
            await self.diagnosticsLog.record(
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
                        value: self.identity.root.path
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
        for registration in registrationsByURL[standardizedURL] ?? [] {
            guard let snapshot = registration.controller?.snapshot else {
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
        let reconciliationGeneration = profileReconciliationGeneration
        if let profileReplacementBarrier {
            await profileReplacementBarrier.value
        }
        guard !isShutDown,
              profileReconciliationGeneration == reconciliationGeneration else {
            return nil
        }
        let profile = resolved.profile
        let key = profile.identifier
        guard profileRegistry.snapshot.profile(identifier: key) == profile else {
            return nil
        }
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
        let providerID = LanguageProviderID(profileIdentifier: key)
        let binding = LanguageServiceBinding(
            providerID: providerID,
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
                    self.onStateChange?()
                }
            },
            onDiagnostics: { [weak self] url, diagnostics in
                Task { @MainActor in
                    guard let self,
                          self.startupGenerations[key] == generation,
                          self.services[key] != nil,
                          self.diagnosticsOwnerIsCurrent(key, for: url) else {
                        return
                    }
                    self.diagnosticsStore.replace(
                        owner: key,
                        resource: url,
                        diagnostics: diagnostics
                    )
                }
            },
            onNormalizedDiagnostics: { [weak self] url, diagnostics in
                Task { @MainActor in
                    guard let self,
                          self.startupGenerations[key] == generation,
                          self.services[key] != nil,
                          self.diagnosticsOwnerIsCurrent(key, for: url) else {
                        return
                    }
                    self.onNormalizedDiagnostics?(url, diagnostics)
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
            },
            onDocumentReplayFailure: { [weak self] failures in
                Task { @MainActor in
                    guard let self,
                          self.startupGenerations[key] == generation,
                          self.services[key] != nil else {
                        return
                    }
                    self.handleDocumentReplayFailures(
                        failures,
                        profile: profile
                    )
                }
            }
        )
        let newService: LanguageWorkspaceService
        do {
            newService = try makeService(for: profile, binding: binding)
        } catch {
            statesByProfile[key] = .missing(
                reason: error.localizedDescription
            )
            onStateChange?()
            return nil
        }

        services[key] = newService
        serviceProfiles[key] = profile
        registerProvider(providerID, service: newService, for: key)
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
              !isShutDown,
              startupGenerations[key] == generation,
              services[key] === newService else {
            return nil
        }
        return newService
    }

    /// Normalizes whatever raw diagnostics the workspace store already
    /// holds for a just-synchronized document and forwards them to the
    /// editor callback, so a file opened *after* its workspace/push
    /// diagnostics arrived still gets minimap markers. An empty result is
    /// published too, clearing markers left over from another version.
    private func publishStoredDiagnostics(
        owner: String,
        snapshot: SourceSnapshot,
        service: LanguageWorkspaceService
    ) async {
        let raw = diagnosticsStore.diagnostics(
            owner: owner,
            resource: snapshot.url
        )
        guard let normalized = await service.normalizedStoredDiagnostics(
            raw,
            for: snapshot
        ) else {
            return
        }
        // A report that landed while normalizing already published its own
        // markers through the service's normalized callback; republishing
        // this now-stale set would clobber it.
        guard services[owner] === service,
              diagnosticsStore.diagnostics(owner: owner, resource: snapshot.url) == raw else {
            return
        }
        onNormalizedDiagnostics?(snapshot.url.standardizedFileURL, normalized)
    }

    private func syncAndDecorate(
        resolved: ResolvedLanguageProfile,
        registrationID: DocumentRegistrationID
    ) async {
        guard let controller = liveController(with: registrationID) else {
            return
        }
        let snapshot = controller.snapshot
        guard let service = await startServiceIfNeeded(
            resolved: resolved
        ) else {
            return
        }
        guard let startedController = liveController(with: registrationID),
              startedController.snapshot.version == snapshot.version else {
            return
        }
        let profileIdentifier = resolved.profile.identifier
        // No document feature — semantic tokens included — may be requested
        // before the service has actually accepted this snapshot, so a
        // failed or superseded synchronization stops here.
        guard let synchronization = await synchronizeDocument(
            snapshot: snapshot,
            profileIdentifier: profileIdentifier,
            registrationID: registrationID,
            service: service
        ) else {
            return
        }
        guard let decoratedController = liveController(with: registrationID),
              decoratedController.snapshot.version == snapshot.version else {
            return
        }
        if synchronization != .changed {
            await publishStoredDiagnostics(
                owner: profileIdentifier,
                snapshot: snapshot,
                service: service
            )
        }
        scheduleSemanticDecoration(
            profileIdentifier: profileIdentifier,
            registrationID: registrationID,
            controller: decoratedController,
            service: service
        )
    }

    // MARK: - Document synchronization

    /// Synchronizes `snapshot` with `service`, returning `nil` if the
    /// service rejected it or the requesting pane went away first. Any
    /// pending or in-progress close for this file is settled first, and
    /// concurrent panes are coalesced onto a single request, so the server
    /// sees exactly one didOpen/didChange per (document, version) and never
    /// a didClose that overtakes it.
    private func synchronizeDocument(
        snapshot: SourceSnapshot,
        profileIdentifier: String,
        registrationID: DocumentRegistrationID,
        service: LanguageWorkspaceService
    ) async -> LanguageDocumentSynchronizationResult? {
        let url = snapshot.url.standardizedFileURL
        return await synchronizeCoalescing(
            url: url,
            profileIdentifier: profileIdentifier,
            version: snapshot.version,
            shouldStart: { [weak self] in
                // Settling a close (or an older synchronization) can take
                // long enough for the requesting pane to close: opening the
                // document again here would leave the server holding a file
                // nobody owns.
                guard let self,
                      let controller = self.liveController(with: registrationID),
                      controller.snapshot.version == snapshot.version,
                      self.isCurrentService(
                          service,
                          profileIdentifier: profileIdentifier,
                          snapshot: controller.snapshot
                      ) else {
                    return false
                }
                return true
            }
        ) { [weak self] in
            guard let self else {
                return nil
            }
            await self.closeSynchronizedDocumentIfNeeded(
                at: url,
                keepingProfileIdentifier: profileIdentifier
            )
            guard self.isCurrentService(
                service,
                profileIdentifier: profileIdentifier,
                snapshot: snapshot
            ) else {
                return nil
            }
            do {
                let result = try await service.synchronize(snapshot)
                // Recorded only now: before this point the server does not
                // hold the document, so nothing may assume it does.
                guard self.isCurrentService(
                    service,
                    profileIdentifier: profileIdentifier,
                    snapshot: snapshot
                ) else {
                    try? await service.didClose(url: url)
                    return nil
                }
                self.synchronizedDocuments[url] = DocumentSynchronizationRecord(
                    profileIdentifier: profileIdentifier,
                    version: snapshot.version
                )
                return result
            } catch {
                return nil
            }
        }
    }

    /// Serializes and coalesces synchronization for one document URL.
    /// A caller for the (profile, version) already in flight awaits that
    /// same task rather than issuing a duplicate request; a caller for a
    /// different version waits for the in-flight one to settle first, so an
    /// older version's didChange can never overtake a newer didOpen; and a
    /// close in progress is always settled before anything is issued.
    /// `shouldStart` is re-evaluated once everything has settled and
    /// immediately before the request is issued — a caller whose pane
    /// disappeared while waiting returns `nil` without a didOpen.
    /// `operation` performs the actual synchronization and returns `nil`
    /// when it fails. Exposed so tests can exercise the serialization
    /// directly, without a live language service.
    func synchronizeCoalescing(
        url: URL,
        profileIdentifier: String,
        version: Int,
        shouldStart: @Sendable @MainActor () -> Bool = { true },
        operation: @escaping @Sendable @MainActor () async
            -> LanguageDocumentSynchronizationResult?
    ) async -> LanguageDocumentSynchronizationResult? {
        guard !isShutDown else {
            return nil
        }
        let url = url.standardizedFileURL
        var awaitedGenerations: Set<UInt64> = []
        while true {
            guard !isShutDown, shouldStart() else {
                return nil
            }
            await settleDocumentClose(before: url)
            guard shouldStart() else {
                return nil
            }
            guard let inFlight = synchronizationsInFlight[url] else {
                break
            }
            if inFlight.profileIdentifier == profileIdentifier,
               inFlight.version == version {
                synchronizationJoinCount += 1
                return await inFlight.task.value
            }
            guard !awaitedGenerations.contains(inFlight.generation) else {
                break
            }
            awaitedGenerations.insert(inFlight.generation)
            _ = await inFlight.task.value
        }
        // Nothing below suspends before the new task is registered, so a
        // close cannot slip in between this check and the request.
        guard !isShutDown, shouldStart() else {
            return nil
        }
        nextOperationGeneration &+= 1
        let generation = nextOperationGeneration
        let task = Task { @MainActor in
            await operation()
        }
        synchronizationsInFlight[url] = DocumentSynchronization(
            generation: generation,
            profileIdentifier: profileIdentifier,
            version: version,
            task: task
        )
        let result = await task.value
        if synchronizationsInFlight[url]?.generation == generation {
            synchronizationsInFlight.removeValue(forKey: url)
        }
        return result
    }

    private func clearNormalizedDiagnosticsForOpenDocuments() {
        clearNormalizedDiagnostics(at: Set(
            liveRegistrations().map { $0.url }
        ))
    }

    private func clearNormalizedDiagnostics(at urls: Set<URL>) {
        for url in urls {
            onNormalizedDiagnostics?(url, [])
        }
    }

    private func clearSemanticDecorationsForOpenDocuments() {
        clearSemanticDecorations(at: Set(liveRegistrations().map(\.url)))
    }

    private func clearSemanticDecorations(for profileIdentifier: String) {
        let urls = Set(
            liveRegistrations().compactMap { entry -> URL? in
                guard let snapshot = entry.registration.controller?.snapshot,
                      resolvedProfile(for: snapshot)?.profile.identifier
                        == profileIdentifier else {
                    return nil
                }
                return entry.url
            }
        )
        clearSemanticDecorations(at: urls)
    }

    private func clearSemanticDecorations(at urls: Set<URL>) {
        for url in urls {
            for registration in registrationsByURL[url] ?? [] {
                registration.controller?.viewport.removeDecorationLayer(.semantic)
            }
        }
    }

    private func clearSynchronizationRecords(for profileIdentifier: String) {
        for (url, record) in synchronizedDocuments
        where record.profileIdentifier == profileIdentifier {
            synchronizedDocuments.removeValue(forKey: url)
        }
    }

    private func isCurrentService(
        _ service: LanguageWorkspaceService,
        profileIdentifier: String,
        snapshot: SourceSnapshot
    ) -> Bool {
        guard !isShutDown,
              isTrusted,
              services[profileIdentifier] === service,
              let resolved = resolvedProfile(for: snapshot),
              resolved.profile.identifier == profileIdentifier,
              resolved.profile.languageServer != nil else {
            return false
        }
        return true
    }

    private func desiredProfileIdentifier(forOpenURL url: URL) -> String? {
        let url = url.standardizedFileURL
        guard registrationsByURL[url]?.contains(where: {
            $0.controller != nil
        }) == true else {
            return nil
        }
        return routedServerProfileIdentifier(for: url)
    }

    private func routedServerProfileIdentifier(for url: URL) -> String? {
        guard let resolved = resolvedProfile(forOpenURL: url),
              resolved.profile.languageServer != nil else {
            return nil
        }
        return resolved.profile.identifier
    }

    private func diagnosticsOwnerIsCurrent(
        _ owner: String,
        for url: URL
    ) -> Bool {
        let url = url.standardizedFileURL
        let hasLiveRegistration = registrationsByURL[url]?.contains {
            $0.controller != nil
        } == true
        if hasLiveRegistration {
            return routedServerProfileIdentifier(for: url) == owner
        }
        if let resolved = profileRegistry.resolve(url: url) {
            return resolved.profile.identifier == owner
                && resolved.profile.languageServer != nil
        }
        guard let ownerProfile = profileRegistry.snapshot.profile(
            identifier: owner
        ), ownerProfile.languageServer != nil else {
            return false
        }
        return ownerProfile.associations.contains {
            !$0.contentMatchers.isEmpty
        }
    }

    private func documentURLsNeedingProviderReconciliation() -> Set<URL> {
        Set(synchronizedDocuments.compactMap { url, record in
            desiredProfileIdentifier(forOpenURL: url)
                == record.profileIdentifier ? nil : url
        })
    }

    private func prepareDocumentProviderTransitions(at urls: Set<URL>) {
        guard !urls.isEmpty else {
            return
        }
        for url in urls {
            for registration in registrationsByURL[url] ?? [] {
                semanticDecorationTasks.removeValue(
                    forKey: registration.id
                )?.cancel()
            }
            diagnosticsStore.clear(resource: url)
        }
        clearNormalizedDiagnostics(at: urls)
        clearSemanticDecorations(at: urls)
    }

    private func closeSynchronizedDocumentIfNeeded(
        at url: URL,
        keepingProfileIdentifier desiredProfileIdentifier: String?
    ) async {
        let url = url.standardizedFileURL
        guard let record = synchronizedDocuments[url],
              record.profileIdentifier != desiredProfileIdentifier else {
            return
        }
        prepareDocumentProviderTransitions(at: [url])
        synchronizedDocuments.removeValue(forKey: url)
        if let service = services[record.profileIdentifier] {
            do {
                try await service.didClose(url: url)
            } catch {
                recordDocumentCloseFailure(
                    profileIdentifier: record.profileIdentifier,
                    url: url,
                    reason: error.localizedDescription
                )
            }
        }
    }

    private func reconcileSynchronizedDocumentsWithCurrentProfiles() async {
        for url in Array(synchronizedDocuments.keys) {
            await closeSynchronizedDocumentIfNeeded(
                at: url,
                keepingProfileIdentifier:
                    desiredProfileIdentifier(forOpenURL: url)
            )
        }
    }

    private func reconcileStoredDiagnosticsWithCurrentProfiles() {
        let diagnostics = diagnosticsStore.snapshot.diagnosticsByOwner
        for (owner, resources) in diagnostics {
            for resource in resources.keys
            where !diagnosticsOwnerIsCurrent(owner, for: resource) {
                diagnosticsStore.replace(
                    owner: owner,
                    resource: resource,
                    diagnostics: []
                )
            }
        }
    }

    private func scheduleSemanticDecoration(
        profileIdentifier: String,
        registrationID: DocumentRegistrationID,
        controller: CodeDocumentViewController,
        service: LanguageWorkspaceService,
        delay: Duration = .zero
    ) {
        guard !isShutDown else {
            return
        }
        semanticDecorationTasks[registrationID]?.cancel()
        let snapshot = controller.snapshot
        semanticDecorationTasks[registrationID] = Task {
            @MainActor [weak self, weak controller] in
            if delay != .zero {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            guard let self, let controller,
                  self.liveController(with: registrationID) === controller,
                  controller.snapshot.version == snapshot.version else {
                return
            }
            await self.applySemanticDecoration(
                profileIdentifier: profileIdentifier,
                registrationID: registrationID,
                controller: controller,
                service: service,
                snapshot: snapshot
            )
        }
    }

    private func applySemanticDecoration(
        profileIdentifier: String,
        registrationID: DocumentRegistrationID,
        controller: CodeDocumentViewController,
        service: LanguageWorkspaceService,
        snapshot: SourceSnapshot
    ) async {
        do {
            let tokens = try await service.semanticTokens(snapshot: snapshot)
            guard !Task.isCancelled,
                  liveController(with: registrationID) === controller,
                  controller.snapshot.version == snapshot.version,
                  isCurrentService(
                      service,
                      profileIdentifier: profileIdentifier,
                      snapshot: snapshot
                  ) else {
                return
            }
            // Decorations fan out to every pane showing this file at this
            // version, not just the one that requested them.
            applySemanticTokens(
                tokens,
                url: snapshot.url,
                snapshotVersion: snapshot.version
            )
        } catch is CancellationError {
            guard !Task.isCancelled,
                  liveController(with: registrationID) === controller,
                  controller.snapshot.version == snapshot.version else {
                return
            }
            scheduleSemanticDecoration(
                profileIdentifier: profileIdentifier,
                registrationID: registrationID,
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

    /// A relaunched server could not be re-sent every document Kod had
    /// open, so the service deliberately never reported `.ready` for that
    /// generation. The affected documents are dropped from the
    /// synchronization records — the server demonstrably does not hold
    /// them — and their editor markers are cleared, so a later reopen or
    /// manual restart resynchronizes from scratch instead of assuming a
    /// document the server never received is still live.
    private func handleDocumentReplayFailures(
        _ failures: [LanguageDocumentReplayFailure],
        profile: LanguageProfile
    ) {
        guard !failures.isEmpty else {
            return
        }
        let urls = Set(failures.map { $0.url.standardizedFileURL })
        for url in urls {
            synchronizedDocuments.removeValue(forKey: url)
        }
        clearNormalizedDiagnostics(at: urls)
        // Bounded: one entry per failed replay batch, listing at most the
        // first few documents rather than every open file.
        let listed = failures
            .prefix(3)
            .map(\.localizedDescription)
            .joined(separator: "; ")
        let remainder = failures.count - min(failures.count, 3)
        let reason = remainder > 0 ? "\(listed) (+\(remainder) more)" : listed
        onDocumentReplayFailure?(profile, reason)
        Task {
            await diagnosticsLog.record(
                subsystem: .languageServer,
                level: .warning,
                message: Localized.string(
                    "\(profile.identifier) language server could not be resynchronized after restarting",
                    comment: "Diagnostics log message recorded when documents cannot be reopened on a restarted language server"
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
        guard !isShutDown else {
            return
        }
        let activeProfiles = Dictionary(
            uniqueKeysWithValues: languageServerProfiles.map {
                ($0.identifier, $0)
            }
        )
        reconcileStoredDiagnosticsWithCurrentProfiles()
        let reroutedURLs = documentURLsNeedingProviderReconciliation()
        prepareDocumentProviderTransitions(at: reroutedURLs)
        var servicesToStop: [LanguageWorkspaceService] = []
        let changedServiceIdentifiers = services.compactMap { identifier, _ in
            activeProfiles[identifier] == serviceProfiles[identifier]
                ? nil
                : identifier
        }
        let changedProfiles = changedServiceIdentifiers.compactMap {
            serviceProfiles[$0]
        }
        if !changedProfiles.isEmpty {
            let previousProfiles = LanguageProfileRegistrySnapshot(
                profiles: changedProfiles
            )
            let affectedURLs = Set(
                liveRegistrations().compactMap { entry -> URL? in
                    guard let snapshot = entry.registration.controller?.snapshot,
                          previousProfiles.resolve(snapshot: snapshot) != nil else {
                        return nil
                    }
                    return snapshot.url.standardizedFileURL
                }
            )
            clearNormalizedDiagnostics(at: affectedURLs)
            clearSemanticDecorations(at: affectedURLs)
        }
        for identifier in changedServiceIdentifiers {
            guard let service = services[identifier] else {
                continue
            }
            startupGenerations[identifier, default: 0] += 1
            startupTasks.removeValue(forKey: identifier)?.cancel()
            services.removeValue(forKey: identifier)
            serviceProfiles.removeValue(forKey: identifier)
            unregisterProvider(for: identifier)
            statesByProfile.removeValue(forKey: identifier)
            diagnosticsStore.clear(owner: identifier)
            clearSynchronizationRecords(for: identifier)
            servicesToStop.append(service)
        }
        semanticDecorationTasks.values.forEach { $0.cancel() }
        semanticDecorationTasks.removeAll()
        onStateChange?()
        profileReconciliationGeneration &+= 1
        let generation = profileReconciliationGeneration
        let previousBarrier = profileReplacementBarrier
        let replacementBarrier = track { [weak self] in
            await previousBarrier?.value
            for service in servicesToStop {
                await service.stop()
            }
            guard let self, !self.isShutDown else {
                return
            }
            await self.reconcileSynchronizedDocumentsWithCurrentProfiles()
        }
        profileReplacementBarrier = replacementBarrier
        track { [weak self] in
            await replacementBarrier?.value
            guard let self,
                  !self.isShutDown,
                  self.profileReconciliationGeneration == generation else {
                return
            }
            await self.resynchronizeAllOpenDocumentsAwaitingCompletion(
                generation: generation
            )
        }
    }

    private func cancelDecorations(for profileIdentifier: String) {
        for entry in liveRegistrations() {
            guard let snapshot = entry.registration.controller?.snapshot,
                  resolvedProfile(for: snapshot)?.profile.identifier
                    == profileIdentifier else {
                continue
            }
            semanticDecorationTasks.removeValue(
                forKey: entry.registration.id
            )?.cancel()
        }
    }

    private func resynchronizeAllOpenDocuments() {
        guard !isShutDown, isTrusted else {
            return
        }
        for entry in liveRegistrations() {
            guard let controller = entry.registration.controller,
                  let resolved = resolvedProfile(for: controller.snapshot),
                  resolved.profile.languageServer != nil else {
                continue
            }
            let registrationID = entry.registration.id
            track { [weak self] in
                await self?.syncAndDecorate(
                    resolved: resolved,
                    registrationID: registrationID
                )
            }
        }
    }

    private func resynchronizeAllOpenDocumentsAwaitingCompletion(
        generation: UInt64
    ) async {
        guard !isShutDown,
              isTrusted,
              profileReconciliationGeneration == generation else {
            return
        }
        for entry in liveRegistrations() {
            guard profileReconciliationGeneration == generation else {
                return
            }
            guard let controller = entry.registration.controller,
                  let resolved = resolvedProfile(for: controller.snapshot),
                  resolved.profile.languageServer != nil else {
                continue
            }
            await syncAndDecorate(
                resolved: resolved,
                registrationID: entry.registration.id
            )
        }
    }

    private func resynchronizeOpenDocuments(
        for profile: LanguageProfile
    ) async {
        guard !isShutDown else {
            return
        }
        for entry in liveRegistrations() {
            guard let controller = entry.registration.controller,
                  let resolved = resolvedProfile(for: controller.snapshot),
                  resolved.profile.identifier == profile.identifier else {
                continue
            }
            await syncAndDecorate(
                resolved: resolved,
                registrationID: entry.registration.id
            )
        }
    }

    /// Stable identity for one registered pane, so per-pane semantic-token
    /// work can be cancelled without touching another pane showing the same
    /// file — and without keying off an object address that a released
    /// controller would make ambiguous.
    private struct DocumentRegistrationID: Hashable {
        let value: UInt64
    }

    private struct DocumentRegistration {
        let id: DocumentRegistrationID
        weak var controller: CodeDocumentViewController?
        var relativePath: String
    }

    private struct DocumentSynchronizationRecord: Equatable {
        let profileIdentifier: String
        let version: Int
    }

    /// The single in-flight synchronization for one document URL. Panes
    /// arriving for the same (profile, version) await `task`; the
    /// generation makes a superseded entry identifiable without relying on
    /// task identity.
    private struct DocumentSynchronization {
        let generation: UInt64
        let profileIdentifier: String
        let version: Int
        let task: Task<LanguageDocumentSynchronizationResult?, Never>
    }

    /// A close for one document URL, from the moment it is scheduled until
    /// its `didClose` (and the marker clear and close output that follow)
    /// has completed. `schedule` is non-nil only while it is still waiting
    /// out the grace period — that is exactly the window in which a reopen
    /// may cancel it; once `closeTask` is set the close is irreversible and
    /// a reopen must await it.
    private struct PendingDocumentClose {
        let generation: UInt64
        let schedule: LanguageDocumentCloseSchedule?
        let closeTask: Task<Void, Never>?
    }
}
