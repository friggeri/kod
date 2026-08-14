import DiagnosticsCore
import Foundation
import GitCore
import LanguageAdapters
import LanguageClient
import SearchCore
import SettingsCore
import WorkspaceCore

/// The non-view subsystems one open workspace owns. Health is reported
/// per subsystem so a single failing piece (a watcher that cannot start,
/// a language server that cannot launch) degrades exactly that
/// capability instead of failing the whole workspace: source viewing,
/// discovery, and search stay usable (SPEC 5.6/6.2/15).
enum WorkspaceSubsystem: String, CaseIterable, Sendable, Hashable {
    case discovery
    case watcher
    case search
    case git
    case language
    case trust
    case persistence

    var diagnosticSubsystem: DiagnosticSubsystem {
        switch self {
        case .discovery, .watcher, .trust, .persistence:
            return .workspace
        case .search:
            return .search
        case .git:
            return .git
        case .language:
            return .languageServer
        }
    }
}

enum WorkspaceHealthScope: Hashable, Sendable {
    case subsystem(WorkspaceSubsystem)
    case languageProfile(identifier: String)

    var subsystem: WorkspaceSubsystem {
        switch self {
        case .subsystem(let subsystem):
            return subsystem
        case .languageProfile:
            return .language
        }
    }

    var stableIdentifier: String {
        switch self {
        case .subsystem(let subsystem):
            return subsystem.rawValue
        case .languageProfile(let identifier):
            return "language-profile:\(identifier)"
        }
    }
}

enum WorkspaceHealthRecoveryActionID: String, CaseIterable, Hashable, Sendable {
    case retry
    case refresh
}

struct WorkspaceHealthRecoveryIntent: Equatable, Sendable {
    let issueID: WorkspaceHealthIssue.ID
    let actionID: WorkspaceHealthRecoveryActionID
}

/// One optional subsystem's current failure. The value is closure-free and
/// Sendable; recovery is routed separately as a typed intent.
struct WorkspaceHealthIssue: Equatable, Sendable, Identifiable {
    struct ID: RawRepresentable, Hashable, Sendable {
        let rawValue: String

        init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    enum Severity: Sendable, Equatable {
        /// The subsystem still works, but with reduced capability.
        case degraded
        /// The subsystem is not running at all.
        case unavailable
    }

    enum State: Sendable, Equatable {
        case failed
        case recovering
    }

    static let maximumReasonLength = 512

    let id: ID
    let scope: WorkspaceHealthScope
    let severity: Severity
    let state: State
    let summary: String
    let reason: String
    let recoveryActionIDs: [WorkspaceHealthRecoveryActionID]
    let generation: UInt64

    var subsystem: WorkspaceSubsystem {
        scope.subsystem
    }

    /// Compatibility spelling for diagnostics and contextual feature UI.
    var message: String {
        summary
    }

    init(
        scope: WorkspaceHealthScope,
        severity: Severity,
        state: State = .failed,
        summary: String,
        reason: String,
        recoveryActionIDs: [WorkspaceHealthRecoveryActionID],
        generation: UInt64 = 0
    ) {
        self.id = ID(rawValue: scope.stableIdentifier)
        self.scope = scope
        self.severity = severity
        self.state = state
        self.summary = summary
        self.reason = Self.bounded(reason)
        self.recoveryActionIDs = recoveryActionIDs
        self.generation = generation
    }

    private static func bounded(_ reason: String) -> String {
        let flattened = reason
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        guard flattened.count > maximumReasonLength else {
            return flattened
        }
        return String(flattened.prefix(maximumReasonLength - 1)) + "…"
    }

    func withGeneration(_ generation: UInt64) -> Self {
        Self(
            scope: scope,
            severity: severity,
            state: state,
            summary: summary,
            reason: reason,
            recoveryActionIDs: recoveryActionIDs,
            generation: generation
        )
    }
}

struct WorkspaceHealth: Equatable, Sendable {
    private(set) var issuesByID: [WorkspaceHealthIssue.ID: WorkspaceHealthIssue] = [:]
    private var generationByID: [WorkspaceHealthIssue.ID: UInt64] = [:]

    init() {}

    var isDegraded: Bool {
        !issuesByID.isEmpty
    }

    var issues: [WorkspaceHealthIssue] {
        issuesByID.values.sorted {
            if $0.subsystem != $1.subsystem {
                return Self.subsystemRank($0.subsystem)
                    < Self.subsystemRank($1.subsystem)
            }
            return $0.id.rawValue < $1.id.rawValue
        }
    }

    var degradedSubsystems: Set<WorkspaceSubsystem> {
        Set(issuesByID.values.map(\.subsystem))
    }

    func issue(for subsystem: WorkspaceSubsystem) -> WorkspaceHealthIssue? {
        issues.first { $0.subsystem == subsystem }
    }

    func issue(id: WorkspaceHealthIssue.ID) -> WorkspaceHealthIssue? {
        issuesByID[id]
    }

    @discardableResult
    mutating func record(_ issue: WorkspaceHealthIssue) -> Bool {
        let previous = issuesByID[issue.id]
        let comparablePrevious = previous?.withGeneration(0)
        let comparableNew = issue.withGeneration(0)
        guard comparablePrevious != comparableNew else {
            return false
        }
        let generation = generationByID[issue.id, default: 0] &+ 1
        generationByID[issue.id] = generation
        issuesByID[issue.id] = issue.withGeneration(generation)
        return true
    }

    @discardableResult
    mutating func clear(_ id: WorkspaceHealthIssue.ID) -> Bool {
        issuesByID.removeValue(forKey: id) != nil
    }

    @discardableResult
    mutating func clear(scope: WorkspaceHealthScope) -> Bool {
        clear(WorkspaceHealthIssue.ID(rawValue: scope.stableIdentifier))
    }

    private static func subsystemRank(_ subsystem: WorkspaceSubsystem) -> Int {
        WorkspaceSubsystem.allCases.firstIndex(of: subsystem) ?? Int.max
    }
}

/// Explicit session lifecycle. `running`/`degraded` are both "started";
/// they differ only in whether any subsystem currently reports an issue.
enum WorkspaceSessionState: Equatable, Sendable {
    case initialized
    case starting
    case running
    case degraded
    case stopping
    case stopped

    var isStarted: Bool {
        self == .running || self == .degraded
    }
}

/// Discovery progress, published to whatever UI is attached. The session
/// never formats user-facing status text itself.
enum WorkspaceDiscoveryStatus: Equatable, Sendable {
    case scanning
    case completed(fileCount: Int)
    case failed(reason: String)
}

/// The watcher capability the session depends on, so tests can inject a
/// watcher that fails to start without touching FSEvents.
protocol WorkspaceFileWatching: AnyObject, Sendable {
    func start() throws
    func stop()
}

extension WorkspaceFileWatcher: WorkspaceFileWatching {}

/// Indirection that lets a session hand its Git coordinator a status
/// callback during `init`, before `self` is fully initialized, without
/// resorting to an implicitly-unwrapped coordinator.
@MainActor
private final class GitStatusRelay {
    var publish: ((GitStatusSnapshot?) -> Void)?
}

/// Injectable construction/startup seams for everything a session owns.
/// Production values are the real subsystems; tests substitute failing
/// or gated versions so startup failures and shutdown ordering are
/// deterministic without sleeps or real external processes. Every seam
/// is `@MainActor`, matching where workspace composition happens.
struct WorkspaceSessionServices {
    var makeFileWatcher: @MainActor (
        URL,
        @escaping @Sendable (WorkspaceChangeBatch) -> Void
    ) -> any WorkspaceFileWatching = { root, onBatch in
        WorkspaceFileWatcher(root: root, onBatch: onBatch)
    }

    var makeTextSearcher: @MainActor () throws -> WorkspaceTextSearcher = {
        try WorkspaceTextSearcher()
    }

    var scan: @MainActor (
        URL,
        WorkspaceDiscoveryOptions
    ) -> AsyncThrowingStream<WorkspaceDiscoveryBatch, any Error> = { root, options in
        WorkspaceScanner().scan(root: root, options: options)
    }

    var makeGitCoordinator: @MainActor (
        WorkspaceDependencies,
        URL,
        @escaping (GitStatusSnapshot?) -> Void
    ) -> GitWorkspaceCoordinator = { dependencies, root, onStatusChanged in
        dependencies.makeGitCoordinator(root: root, onStatusChanged: onStatusChanged)
    }

    var startGitCoordinator: @MainActor (GitWorkspaceCoordinator) async throws -> Void = {
        await $0.start()
    }

    var makeLanguageServices: @MainActor (
        WorkspaceDependencies,
        WorkspaceIdentity
    ) -> MultiLanguageServicesCoordinator = { dependencies, identity in
        dependencies.makeLanguageServicesCoordinator(identity: identity)
    }

    /// Language services start lazily per profile once documents open,
    /// so production has no eager startup step; the seam exists so a
    /// failing language startup can be exercised, and so a future eager
    /// warm-up has one place to live.
    var startLanguageServices: @MainActor (
        MultiLanguageServicesCoordinator
    ) async throws -> Void = { _ in }

    var stopLanguageServices: @MainActor (
        MultiLanguageServicesCoordinator
    ) async -> Void = { await $0.stopAll() }

    init() {}
}

/// Headless owner of one workspace's non-view subsystem lifetime:
/// discovery, the filename index, the FSEvents watcher, text search, Git,
/// language services, and layout persistence. It owns no `NSWindow` and
/// builds no views — UI attaches by setting the narrow event callbacks
/// below — so workspace lifetime no longer depends on when AppKit happens
/// to release a view controller.
@MainActor
final class WorkspaceSession {
    let identity: WorkspaceIdentity
    let dependencies: WorkspaceDependencies
    let filenameIndex = FilenameIndex()
    let scanner = WorkspaceScanner()
    let gitCoordinator: GitWorkspaceCoordinator
    let languageServices: MultiLanguageServicesCoordinator

    private let services: WorkspaceSessionServices
    private let gitStatusRelay: GitStatusRelay

    private(set) var state: WorkspaceSessionState = .initialized
    private(set) var health = WorkspaceHealth()
    private(set) var discoveryOptions = WorkspaceDiscoveryOptions()
    private(set) var discoveryGeneration = 0

    // MARK: - Events published to UI

    var onDiscoveryBatch: ((WorkspaceDiscoveryBatch) -> Void)?
    var onDiscoveryStatus: ((WorkspaceDiscoveryStatus) -> Void)?
    var onFileChangeBatch: ((WorkspaceChangeBatch) -> Void)?
    var onGitStatusChanged: ((GitStatusSnapshot?) -> Void)?
    var onLanguageStateChanged: (() -> Void)?
    var onLanguageDiagnostics: ((URL, [NormalizedDiagnostic]) -> Void)?
    var onLanguageMissingServer: ((LanguageProfile) -> Void)?
    var onLanguageUnknownFileType: ((URL) -> Void)?
    var onLanguageDocumentClosed: ((URL) -> Void)?
    var onHealthChanged: ((WorkspaceHealth) -> Void)?
    /// Invoked during `shutdown()` so UI-held state (split layout,
    /// window geometry, reading anchors) is captured before subsystems
    /// stop. The session never reaches into views for it.
    var persistState: (() -> Void)?

    // MARK: - Owned work

    private var hasBegun = false
    private var startTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var externalReloadTask: Task<Void, Never>?
    private var trackedTasks: [UInt64: Task<Void, Never>] = [:]
    private var nextTrackedTaskValue: UInt64 = 0
    private var fileWatcher: (any WorkspaceFileWatching)?
    private var cachedTextSearcher: WorkspaceTextSearcher?
    private var searchFailureRequiresSuccessfulQuery = false
    private var replayFailureProfileIDs: Set<String> = []
    private var lastFailedLayoutState: WorkspaceLayoutState?

    init(
        identity: WorkspaceIdentity,
        dependencies: WorkspaceDependencies,
        services: WorkspaceSessionServices = WorkspaceSessionServices()
    ) {
        self.identity = identity
        self.dependencies = dependencies
        self.services = services
        self.languageServices = services.makeLanguageServices(dependencies, identity)
        let relay = GitStatusRelay()
        self.gitStatusRelay = relay
        self.gitCoordinator = services.makeGitCoordinator(
            dependencies,
            identity.root
        ) { snapshot in
            relay.publish?(snapshot)
        }
        relay.publish = { [weak self] snapshot in
            self?.publishGitStatus(snapshot)
        }
    }

    // MARK: - Lifecycle

    var isAcceptingWork: Bool {
        state != .stopping && state != .stopped
    }

    /// Synchronous entry point: installs subsystem callbacks and starts
    /// discovery immediately (so UI wired before this call never misses
    /// an event), then finishes asynchronous subsystem startup in the
    /// returned task. Idempotent — repeated calls join the same startup.
    @discardableResult
    func begin() -> Task<Void, Never> {
        if let startTask {
            return startTask
        }
        guard isAcceptingWork, !hasBegun else {
            return Task {}
        }
        hasBegun = true
        state = .starting
        installLanguageServiceCallbacks()
        startDiscovery()
        // The task holds a strong reference, so startup always runs to
        // completion even if the UI that created the session is released
        // mid-start.
        let task = Task<Void, Never> { @MainActor in
            await self.startLanguageServices()
            await self.startGitCoordinator()
            if self.state == .starting {
                self.state = self.health.isDegraded ? .degraded : .running
            }
            self.startTask = nil
        }
        startTask = task
        return task
    }

    /// Idempotent, concurrency-safe start. Concurrent callers join the
    /// same startup rather than racing a second one.
    func start() async {
        await begin().value
    }

    /// Retries subsystems. With no argument, only subsystems that
    /// currently report a health issue are retried — a failed watcher
    /// never re-runs discovery, Git, or language startup.
    func refresh(_ subsystems: Set<WorkspaceSubsystem>? = nil) async {
        guard isAcceptingWork else {
            return
        }
        guard let subsystems else {
            let retryableIssues = health.issues.filter {
                $0.recoveryActionIDs.contains(.retry)
            }
            for issue in retryableIssues {
                await performRecovery(
                    WorkspaceHealthRecoveryIntent(
                        issueID: issue.id,
                        actionID: .retry
                    )
                )
            }
            return
        }
        let targets = subsystems
        guard !targets.isEmpty else {
            return
        }
        if targets.contains(.discovery) {
            startDiscovery()
        }
        if targets.contains(.language) {
            await startLanguageServices()
        }
        if targets.contains(.git) {
            await startGitCoordinator()
        }
        if targets.contains(.watcher) {
            startFileWatcherIfNeeded()
        }
        if targets.contains(.search) {
            cachedTextSearcher = nil
            _ = try? textSearcher()
        }
        updateStateForHealth()
    }

    /// Routes a presenter action without embedding executable behavior in
    /// the Sendable health model. Stale or unsupported intents are ignored.
    @discardableResult
    func beginRecovery(
        _ intent: WorkspaceHealthRecoveryIntent
    ) -> Task<Void, Never> {
        guard let issue = health.issue(id: intent.issueID) else {
            return Task {}
        }
        return runTracked(issue.subsystem) { [weak self] in
            await self?.performRecovery(intent)
        }
    }

    func performRecovery(_ intent: WorkspaceHealthRecoveryIntent) async {
        guard isAcceptingWork,
              let issue = health.issue(id: intent.issueID),
              issue.state == .failed,
              issue.recoveryActionIDs.contains(intent.actionID) else {
            return
        }

        if intent.actionID == .refresh, issue.subsystem == .watcher {
            startDiscovery()
            return
        }

        markRecovering(issue)
        switch issue.scope {
        case .languageProfile(let identifier):
            if replayFailureProfileIDs.contains(identifier) {
                languageServices.restart(profileIdentifier: identifier)
            } else {
                languageServices.handleLanguageServerExecutableAvailable(
                    languageKey: identifier
                )
            }
        case .subsystem(.discovery):
            startDiscovery()
        case .subsystem(.watcher):
            startFileWatcherIfNeeded()
        case .subsystem(.search):
            cachedTextSearcher = nil
            _ = try? textSearcher()
        case .subsystem(.git):
            await startGitCoordinator()
        case .subsystem(.language):
            await startLanguageServices()
        case .subsystem(.trust):
            break
        case .subsystem(.persistence):
            if let lastFailedLayoutState {
                persistLayout(lastFailedLayoutState)
            }
        }
    }

    /// Starts (once) the explicit teardown of everything this session
    /// owns. The returned task holds a strong reference to the session,
    /// so cleanup always runs to completion regardless of when the UI
    /// that created it is released.
    @discardableResult
    func beginShutdown() -> Task<Void, Never> {
        if let shutdownTask {
            return shutdownTask
        }
        guard state != .stopped else {
            return Task {}
        }
        state = .stopping
        let task = Task<Void, Never> { @MainActor in
            await self.performShutdown()
        }
        shutdownTask = task
        return task
    }

    /// Headless seam: awaits the shutdown started by `beginShutdown()`,
    /// so callers and tests can assert it actually completed instead of
    /// sleeping. Idempotent; concurrent callers join the same shutdown.
    func shutdown() async {
        await beginShutdown().value
    }

    private func performShutdown() async {
        persistState?()

        let startup = startTask
        startTask = nil
        startup?.cancel()
        await startup?.value

        discoveryGeneration &+= 1
        let discovery = discoveryTask
        discoveryTask = nil
        discovery?.cancel()
        await discovery?.value

        externalReloadTask = nil
        while !trackedTasks.isEmpty {
            let inFlight = trackedTasks
            trackedTasks.removeAll()
            for task in inFlight.values {
                task.cancel()
            }
            for task in inFlight.values {
                await task.value
            }
        }

        fileWatcher?.stop()
        fileWatcher = nil
        let textSearcher = cachedTextSearcher
        cachedTextSearcher = nil
        await textSearcher?.cancelActiveSearch()

        await services.stopLanguageServices(languageServices)

        state = .stopped
        clearEventHandlers()
    }

    /// Headless seam: awaits startup, discovery, and every tracked
    /// subsystem task currently in flight, so tests observe completion
    /// deterministically instead of sleeping.
    func waitForPendingWork() async {
        for _ in 0..<32 {
            let startup = startTask
            let discovery = discoveryTask
            let tracked = Array(trackedTasks.values)
            if startup == nil, discovery == nil, tracked.isEmpty {
                return
            }
            await startup?.value
            await discovery?.value
            for task in tracked {
                await task.value
            }
            if startTask == nil, discoveryTask == nil, trackedTasks.isEmpty {
                return
            }
        }
    }

    private func clearEventHandlers() {
        onDiscoveryBatch = nil
        onDiscoveryStatus = nil
        onFileChangeBatch = nil
        onGitStatusChanged = nil
        onLanguageStateChanged = nil
        onLanguageDiagnostics = nil
        onLanguageMissingServer = nil
        onLanguageUnknownFileType = nil
        onLanguageDocumentClosed = nil
        onHealthChanged = nil
        persistState = nil
    }

    // MARK: - Tracked work

    /// Runs `operation` as a session-owned task: cancelled and awaited by
    /// `shutdown()`, and refused once the session is stopping, so no
    /// subsystem work outlives the session.
    @discardableResult
    func runTracked(
        _ subsystem: WorkspaceSubsystem,
        priority: TaskPriority? = nil,
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never> {
        guard isAcceptingWork else {
            return Task {}
        }
        let id = nextTrackedTaskValue
        nextTrackedTaskValue &+= 1
        let task = Task<Void, Never>(priority: priority) { @MainActor [weak self] in
            await operation()
            self?.trackedTasks.removeValue(forKey: id)
        }
        trackedTasks[id] = task
        return task
    }

    /// The single in-flight reload of externally modified open files.
    /// Starting a new one supersedes its predecessor, exactly as the
    /// view controller's own task handle used to.
    @discardableResult
    func beginExternalReload(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never> {
        externalReloadTask?.cancel()
        let task = runTracked(.discovery, operation)
        externalReloadTask = task
        return task
    }

    // MARK: - Discovery

    /// Restarts discovery, superseding any scan in flight. Every batch
    /// and status transition is published; the session holds no
    /// Explorer-shaped state itself.
    func startDiscovery(options: WorkspaceDiscoveryOptions? = nil) {
        guard isAcceptingWork else {
            return
        }
        if let options {
            discoveryOptions = options
        }
        discoveryTask?.cancel()
        discoveryGeneration += 1
        let generation = discoveryGeneration
        let activeOptions = discoveryOptions
        publishDiscoveryStatus(.scanning)
        discoveryTask = Task { [weak self] in
            guard let self else {
                return
            }
            await self.performDiscovery(
                generation: generation,
                options: activeOptions
            )
            if self.discoveryGeneration == generation {
                self.discoveryTask = nil
            }
        }
    }

    private func performDiscovery(
        generation: Int,
        options: WorkspaceDiscoveryOptions
    ) async {
        do {
            await filenameIndex.removeAll()
            guard discoveryGeneration == generation else {
                return
            }
            for try await batch in services.scan(identity.root, options) {
                try Task.checkCancellation()
                guard discoveryGeneration == generation else {
                    return
                }
                await filenameIndex.append(batch.entries)
                guard discoveryGeneration == generation else {
                    return
                }
                publishDiscoveryBatch(batch)
            }
            guard discoveryGeneration == generation else {
                return
            }
            let fileCount = await filenameIndex.count
            guard discoveryGeneration == generation else {
                return
            }
            clearHealthIssue(.discovery)
            publishDiscoveryStatus(.completed(fileCount: fileCount))
            startFileWatcherIfNeeded()
        } catch is CancellationError {
            return
        } catch {
            guard discoveryGeneration == generation else {
                return
            }
            recordHealthIssue(
                .discovery,
                severity: .degraded,
                message: Localized.string(
                    "Workspace discovery did not finish",
                    comment: "Health message shown when the workspace file scan fails"
                ),
                reason: error.localizedDescription
            )
            publishDiscoveryStatus(
                .failed(reason: error.localizedDescription)
            )
        }
    }

    // MARK: - Live filesystem updates (FSEvents)

    /// The workspace stays fully usable when the watcher cannot start —
    /// discovery, search, Git, and language services do not depend on it
    /// — so a failure enters health and diagnostics instead of failing
    /// the workspace, leaving only live external-change updates off.
    func startFileWatcherIfNeeded() {
        guard isAcceptingWork, fileWatcher == nil else {
            return
        }
        let watcher = services.makeFileWatcher(identity.root) { [weak self] batch in
            Task { @MainActor in
                self?.publishFileChangeBatch(batch)
            }
        }
        do {
            try watcher.start()
            fileWatcher = watcher
            clearHealthIssue(.watcher)
        } catch let error as WorkspaceFileWatcherError {
            recordFileWatcherFailure(reason: Self.diagnosticReason(for: error))
        } catch {
            recordFileWatcherFailure(reason: error.localizedDescription)
        }
    }

    var isWatchingFileSystem: Bool {
        fileWatcher != nil
    }

    private func recordFileWatcherFailure(reason: String) {
        fileWatcher = nil
        recordHealthIssue(
            .watcher,
            severity: .unavailable,
            message: Localized.string(
                "Live external-change updates are unavailable: the workspace file watcher could not start",
                comment: "Diagnostics log message recorded when the workspace file watcher fails to start"
            ),
            reason: reason
        )
    }

    private static func diagnosticReason(
        for error: WorkspaceFileWatcherError
    ) -> String {
        switch error {
        case .streamCreationFailed:
            return Localized.string(
                "FSEvents stream could not be created",
                comment: "Diagnostics log reason recorded when the workspace file watcher's FSEvents stream cannot be created"
            )
        case .streamStartFailed:
            return Localized.string(
                "FSEvents stream could not be started",
                comment: "Diagnostics log reason recorded when the workspace file watcher's FSEvents stream cannot be started"
            )
        }
    }

    /// Feeds a filesystem change batch to Git as session-owned work, so
    /// shutdown cancels and awaits it like every other subsystem task.
    func handleFileSystemChanges(_ batch: WorkspaceChangeBatch) {
        runTracked(.git) { [weak self] in
            guard let self else {
                return
            }
            await self.gitCoordinator.handle(batch)
            self.synchronizeGitHealthAfterRefresh()
        }
    }

    func updateFilenameIndex(
        removing relativePaths: [String],
        appending entries: [WorkspaceFileEntry] = []
    ) {
        let filenameIndex = filenameIndex
        runTracked(.discovery) {
            if !relativePaths.isEmpty {
                await filenameIndex.remove(relativePaths: relativePaths)
            }
            if !entries.isEmpty {
                await filenameIndex.append(entries)
            }
        }
    }

    // MARK: - Search

    /// The workspace's lazily created text-search engine. Creation is
    /// attempted once; a failure enters health (search unavailable) and
    /// is rethrown so the caller can show its own status text.
    func textSearcher() throws -> WorkspaceTextSearcher {
        if let cachedTextSearcher {
            return cachedTextSearcher
        }
        do {
            let searcher = try services.makeTextSearcher()
            cachedTextSearcher = searcher
            if !searchFailureRequiresSuccessfulQuery {
                clearHealthIssue(.search)
            }
            return searcher
        } catch {
            recordHealthIssue(
                .search,
                severity: .unavailable,
                message: Localized.string(
                    "Workspace search engine failed to initialize",
                    comment: "Diagnostics log message recorded when the workspace text search engine fails to start"
                ),
                reason: String(describing: error)
            )
            throw error
        }
    }

    /// Runs a search stream as session-owned work so an in-flight search
    /// is cancelled and awaited by `shutdown()`.
    @discardableResult
    func runSearch(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never> {
        runTracked(.search, operation)
    }

    func reportSearchFailure(reason: String) {
        searchFailureRequiresSuccessfulQuery = true
        recordHealthIssue(
            .search,
            severity: .unavailable,
            message: Localized.string(
                "Workspace search failed",
                comment: "Health message shown when a workspace search fails while running"
            ),
            reason: reason
        )
    }

    func reportSearchSuccess() {
        searchFailureRequiresSuccessfulQuery = false
        clearHealthIssue(.search)
    }

    // MARK: - Git

    private func startGitCoordinator() async {
        do {
            try await services.startGitCoordinator(gitCoordinator)
            synchronizeGitHealthAfterRefresh()
        } catch {
            recordHealthIssue(
                .git,
                severity: .unavailable,
                message: Localized.string(
                    "Git information is unavailable for this workspace",
                    comment: "Health message shown when the workspace's Git coordinator cannot start"
                ),
                reason: String(describing: error)
            )
        }
    }

    private func synchronizeGitHealthAfterRefresh() {
        guard gitCoordinator.context != nil else {
            // A folder that is not a repository is a valid state, not a
            // degraded Git subsystem.
            clearHealthIssue(.git)
            return
        }
        guard gitCoordinator.latestStatus != nil else {
            recordHealthIssue(
                .git,
                severity: .degraded,
                message: Localized.string(
                    "Git status is temporarily unavailable",
                    comment: "Workspace health message shown when refreshing Git status fails"
                ),
                reason: Localized.string(
                    "Git status refresh did not produce a snapshot",
                    comment: "Workspace health diagnostic reason when a Git repository refresh fails"
                )
            )
            return
        }
        clearHealthIssue(.git)
    }

    // MARK: - Language services

    private func installLanguageServiceCallbacks() {
        languageServices.onStateChange = { [weak self] in
            self?.synchronizeLanguageHealth()
            self?.publishLanguageStateChange()
        }
        languageServices.onNormalizedDiagnostics = { [weak self] url, diagnostics in
            self?.publishLanguageDiagnostics(url: url, diagnostics: diagnostics)
        }
        languageServices.onMissingServer = { [weak self] profile in
            self?.publishLanguageMissingServer(profile)
        }
        languageServices.onUnknownFileType = { [weak self] url in
            self?.publishLanguageUnknownFileType(url)
        }
        languageServices.onDocumentReplayFailure = {
            [weak self] profile, reason in
            self?.recordLanguageReplayFailure(
                profile: profile,
                reason: reason
            )
        }
        languageServices.onDocumentClosed = { [weak self] url in
            self?.publishLanguageDocumentClosed(url)
        }
    }

    private func startLanguageServices() async {
        do {
            try await services.startLanguageServices(languageServices)
            clearHealthIssue(.language)
        } catch {
            recordHealthIssue(
                .language,
                severity: .unavailable,
                message: Localized.string(
                    "Language services are unavailable for this workspace",
                    comment: "Health message shown when this workspace's language services cannot start"
                ),
                reason: String(describing: error)
            )
        }
    }

    private func synchronizeLanguageHealth() {
        let profileStates = languageServices.states
        let activeProfileIDs = Set(profileStates.map { $0.profile.identifier })
        let existingProfileIssues = health.issues.filter {
            if case .languageProfile = $0.scope {
                return true
            }
            return false
        }

        for item in profileStates {
            let profile = item.profile
            let scope = WorkspaceHealthScope.languageProfile(
                identifier: profile.identifier
            )
            switch item.state {
            case .missing(let reason):
                recordLanguageProfileIssue(
                    scope: scope,
                    displayName: profile.displayName,
                    reason: reason,
                    severity: .unavailable
                )
            case .crashed(let reason):
                recordLanguageProfileIssue(
                    scope: scope,
                    displayName: profile.displayName,
                    reason: reason,
                    severity: .degraded
                )
            case .disabled(let reason):
                guard trustStoreAllowsLanguageHealth else {
                    clearHealthIssue(scope: scope)
                    continue
                }
                recordLanguageProfileIssue(
                    scope: scope,
                    displayName: profile.displayName,
                    reason: reason,
                    severity: .unavailable
                )
            case .ready, .busy:
                replayFailureProfileIDs.remove(profile.identifier)
                clearHealthIssue(scope: scope)
            case .indexing:
                if !replayFailureProfileIDs.contains(profile.identifier) {
                    clearHealthIssue(scope: scope)
                }
            case .starting:
                if let issue = health.issue(
                    id: WorkspaceHealthIssue.ID(
                        rawValue: scope.stableIdentifier
                    )
                ) {
                    markRecovering(issue)
                }
            case .stopping, .stopped:
                break
            }
        }

        for issue in existingProfileIssues {
            guard case .languageProfile(let identifier) = issue.scope,
                  !activeProfileIDs.contains(identifier) else {
                continue
            }
            clearHealthIssue(scope: issue.scope)
            replayFailureProfileIDs.remove(identifier)
        }
    }

    private var trustStoreAllowsLanguageHealth: Bool {
        dependencies.trustStore.isTrusted(identity)
    }

    private func recordLanguageProfileIssue(
        scope: WorkspaceHealthScope,
        displayName: String,
        reason: String,
        severity: WorkspaceHealthIssue.Severity
    ) {
        recordHealthIssue(
            scope: scope,
            severity: severity,
            message: Localized.string(
                "\(displayName) language support is unavailable",
                comment: "Workspace health summary for one failed language profile"
            ),
            reason: reason,
            recoveryActionIDs: [.retry]
        )
    }

    private func recordLanguageReplayFailure(
        profile: LanguageProfile,
        reason: String
    ) {
        replayFailureProfileIDs.insert(profile.identifier)
        recordHealthIssue(
            scope: .languageProfile(identifier: profile.identifier),
            severity: .degraded,
            message: Localized.string(
                "\(profile.displayName) language documents could not be restored",
                comment: "Workspace health summary when a language server cannot reopen documents after restarting"
            ),
            reason: reason,
            recoveryActionIDs: [.retry]
        )
    }

    // MARK: - Layout persistence

    func loadLayoutState() -> WorkspaceLayoutState {
        do {
            switch try dependencies.layoutStore.load(for: identity) {
            case .value(let state, _):
                return state
            case .absent:
                return .singleGroup()
            case .quarantined(let record):
                recordLayoutPersistenceFailure(reason: record.reason)
                return .singleGroup()
            }
        } catch {
            recordLayoutPersistenceFailure(
                reason: error.localizedDescription
            )
            return .singleGroup()
        }
    }

    /// Layout persistence is best effort from the UI's point of view: a
    /// state that fails validation or encoding must not interrupt
    /// editing, so the failure enters health/diagnostics and the
    /// in-memory layout keeps working unchanged. Recorded once per
    /// failure streak — this runs on essentially every layout mutation.
    func persistLayout(_ state: WorkspaceLayoutState) {
        do {
            try dependencies.layoutStore.save(state, for: identity)
            lastFailedLayoutState = nil
            clearHealthIssue(.persistence)
        } catch let error as WorkspaceLayoutValidationError {
            lastFailedLayoutState = state
            recordLayoutPersistenceFailure(reason: String(describing: error))
        } catch let error as SettingsRepositoryError {
            lastFailedLayoutState = state
            recordLayoutPersistenceFailure(reason: error.localizedDescription)
        } catch {
            lastFailedLayoutState = state
            recordLayoutPersistenceFailure(reason: String(describing: error))
        }
    }

    private func recordLayoutPersistenceFailure(reason: String) {
        recordHealthIssue(
            .persistence,
            severity: .degraded,
            message: Localized.string(
                "Workspace layout could not be saved",
                comment: "Diagnostics log message recorded when persisting the workspace's split/tab layout fails"
            ),
            reason: reason
        )
    }

    // MARK: - Health

    func recordHealthIssue(
        _ subsystem: WorkspaceSubsystem,
        severity: WorkspaceHealthIssue.Severity,
        message: String,
        reason: String
    ) {
        let recoveryActionIDs: [WorkspaceHealthRecoveryActionID]
        switch subsystem {
        case .watcher:
            recoveryActionIDs = [.retry, .refresh]
        default:
            recoveryActionIDs = [.retry]
        }
        recordHealthIssue(
            scope: .subsystem(subsystem),
            severity: severity,
            message: message,
            reason: reason,
            recoveryActionIDs: recoveryActionIDs
        )
    }

    func recordHealthIssue(
        scope: WorkspaceHealthScope,
        severity: WorkspaceHealthIssue.Severity,
        message: String,
        reason: String,
        recoveryActionIDs: [WorkspaceHealthRecoveryActionID]
    ) {
        let issue = WorkspaceHealthIssue(
            scope: scope,
            severity: severity,
            summary: message,
            reason: reason,
            recoveryActionIDs: recoveryActionIDs
        )
        guard health.record(issue) else {
            return
        }
        log(issue)
        updateStateForHealth()
        publishHealth()
    }

    func clearHealthIssue(_ subsystem: WorkspaceSubsystem) {
        clearHealthIssue(scope: .subsystem(subsystem))
    }

    func clearHealthIssue(scope: WorkspaceHealthScope) {
        guard health.clear(scope: scope) else {
            return
        }
        updateStateForHealth()
        publishHealth()
    }

    private func markRecovering(_ issue: WorkspaceHealthIssue) {
        let recovering = WorkspaceHealthIssue(
            scope: issue.scope,
            severity: issue.severity,
            state: .recovering,
            summary: issue.summary,
            reason: issue.reason,
            recoveryActionIDs: issue.recoveryActionIDs
        )
        guard health.record(recovering) else {
            return
        }
        publishHealth()
    }

    private func updateStateForHealth() {
        guard state.isStarted else {
            return
        }
        state = health.isDegraded ? .degraded : .running
    }

    private func log(_ issue: WorkspaceHealthIssue) {
        let diagnosticsLog = dependencies.diagnosticsLog
        let rootPath = identity.root.path
        runTracked(issue.subsystem) {
            await diagnosticsLog.record(
                subsystem: issue.subsystem.diagnosticSubsystem,
                level: .warning,
                message: issue.message,
                context: [
                    DiagnosticContextField(
                        name: "workspaceRoot",
                        category: .fullPath,
                        value: rootPath
                    ),
                    DiagnosticContextField(
                        name: "reason",
                        category: .diagnosticMessage,
                        value: issue.reason
                    )
                ]
            )
        }
    }

    // MARK: - Publication

    private var isPublishing: Bool {
        state != .stopped
    }

    private func publishDiscoveryBatch(_ batch: WorkspaceDiscoveryBatch) {
        guard isPublishing else {
            return
        }
        onDiscoveryBatch?(batch)
    }

    private func publishDiscoveryStatus(_ status: WorkspaceDiscoveryStatus) {
        guard isPublishing else {
            return
        }
        onDiscoveryStatus?(status)
    }

    private func publishFileChangeBatch(_ batch: WorkspaceChangeBatch) {
        guard isPublishing, state != .stopping else {
            return
        }
        onFileChangeBatch?(batch)
    }

    private func publishGitStatus(_ snapshot: GitStatusSnapshot?) {
        guard isPublishing else {
            return
        }
        onGitStatusChanged?(snapshot)
    }

    private func publishLanguageStateChange() {
        guard isPublishing else {
            return
        }
        onLanguageStateChanged?()
    }

    private func publishLanguageDiagnostics(
        url: URL,
        diagnostics: [NormalizedDiagnostic]
    ) {
        guard isPublishing else {
            return
        }
        onLanguageDiagnostics?(url, diagnostics)
    }

    private func publishLanguageMissingServer(_ profile: LanguageProfile) {
        guard isPublishing else {
            return
        }
        onLanguageMissingServer?(profile)
    }

    private func publishLanguageUnknownFileType(_ url: URL) {
        guard isPublishing else {
            return
        }
        onLanguageUnknownFileType?(url)
    }

    private func publishLanguageDocumentClosed(_ url: URL) {
        guard isPublishing else {
            return
        }
        onLanguageDocumentClosed?(url)
    }

    private func publishHealth() {
        guard isPublishing else {
            return
        }
        onHealthChanged?(health)
    }
}
