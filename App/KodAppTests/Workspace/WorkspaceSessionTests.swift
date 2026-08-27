import DiagnosticsCore
import Foundation
import GitCore
import SearchCore
import WorkspaceCore
import XCTest
@testable import Kod

/// Deterministic, headless coverage for `WorkspaceSession` — the explicit
/// owner of a workspace's non-view subsystem lifetime. Every seam is
/// injected (scan stream, watcher, Git/language startup, search engine)
/// and every wait is a real continuation gate, so no test sleeps, polls,
/// or launches a real external server.
@MainActor
final class WorkspaceSessionTests: XCTestCase {
    // MARK: - Fixture

    /// Lets already-enqueued main-actor work (the watcher's callback hop)
    /// run without sleeping.
    private func drainMainActorWork() async {
        for _ in 0..<4 {
            await Task.yield()
        }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    /// Builds a session whose subsystems are entirely injected. The shallow
    /// directory scan defaults to a single immediately-finished batch so discovery
    /// completes (and therefore the watcher starts) deterministically.
    private func makeFixture(
        watcherStartError: (any Error)? = nil,
        gitStartError: (any Error)? = nil,
        languageStartError: (any Error)? = nil,
        searcherError: (any Error)? = nil,
        recorder suppliedRecorder: Recorder? = nil,
        directoryScan: (@MainActor (
            URL,
            String,
            WorkspaceDiscoveryOptions
        ) -> AsyncThrowingStream<WorkspaceDiscoveryBatch, any Error>)? = nil,
        filenameScan: (@MainActor (
            URL,
            WorkspaceDiscoveryOptions
        ) -> AsyncThrowingStream<WorkspaceDiscoveryBatch, any Error>)? = nil
    ) throws -> Fixture {
        let root = try makeRoot()
        let identity = try WorkspaceIdentity(root: root)
        let appFixture = try KodAppTestEnvironment.make(in: self)
        let dependencies = appFixture.environment.makeWorkspaceDependencies()
        let recorder = suppliedRecorder ?? Recorder()

        var services = WorkspaceSessionServices()
        services.scanDirectory = { url, relativePath, options in
            recorder.scanCount += 1
            if let directoryScan {
                return directoryScan(url, relativePath, options)
            }
            return AsyncThrowingStream { continuation in
                continuation.yield(
                    WorkspaceDiscoveryBatch(entries: [], discoveredCount: 0)
                )
                continuation.finish()
            }
        }
        services.scan = { url, options in
            recorder.filenameScanCount += 1
            if let filenameScan {
                return filenameScan(url, options)
            }
            return AsyncThrowingStream { continuation in
                continuation.finish()
            }
        }
        services.makeFileWatcher = { _, onBatch in
            recorder.watcherFactoryCount += 1
            let watcher = FakeFileWatcher(
                startError: watcherStartError,
                onBatch: onBatch
            )
            recorder.watchers.append(watcher)
            return watcher
        }
        services.makeGitCoordinator = { dependencies, root, onStatusChanged in
            recorder.gitStatusPublish = onStatusChanged
            return GitWorkspaceCoordinator(
                root: root,
                diagnosticsLog: dependencies.diagnosticsLog,
                onStatusChanged: onStatusChanged
            )
        }
        services.startGitCoordinator = { _ in
            recorder.gitStartCount += 1
            if let gitStartError {
                throw gitStartError
            }
        }
        services.startLanguageServices = { _ in
            recorder.languageStartCount += 1
            if let languageStartError {
                throw languageStartError
            }
        }
        services.stopLanguageServices = { coordinator in
            recorder.languageStopCount += 1
            await coordinator.stopAll()
        }
        services.makeTextSearcher = {
            recorder.searcherFactoryCount += 1
            if let searcherError {
                throw searcherError
            }
            return try WorkspaceTextSearcher()
        }

        let session = WorkspaceSession(
            identity: identity,
            dependencies: dependencies,
            services: services
        )
        session.onDiscoveryStatus = { recorder.discoveryStatuses.append($0) }
        session.onDiscoveryBatch = { recorder.discoveryBatches.append($0) }
        session.onFileChangeBatch = { recorder.fileChangeBatches.append($0) }
        session.onGitStatusChanged = { _ in recorder.gitStatusEvents += 1 }
        session.onLanguageStateChanged = { recorder.languageStateEvents += 1 }
        session.onHealthChanged = { recorder.healthEvents.append($0) }
        session.persistState = { recorder.persistStateCount += 1 }
        addTeardownBlock { await session.shutdown() }
        return Fixture(root: root, session: session, recorder: recorder)
    }

    // MARK: - Start / shutdown idempotence

    func testConcurrentStartsJoinOneStartupAndRepeatedStartsDoNothing() async throws {
        let fixture = try makeFixture()
        let session = fixture.session

        XCTAssertEqual(session.state, .initialized)
        let first = Task { @MainActor in await session.start() }
        let second = Task { @MainActor in await session.start() }
        _ = await (first.value, second.value)
        await session.start()
        await session.waitForPendingWork()

        XCTAssertEqual(fixture.recorder.languageStartCount, 1)
        XCTAssertEqual(fixture.recorder.gitStartCount, 1)
        XCTAssertEqual(fixture.recorder.scanCount, 1)
        XCTAssertEqual(fixture.recorder.filenameScanCount, 0)
        XCTAssertEqual(fixture.recorder.watcherFactoryCount, 1)
        XCTAssertEqual(session.state, .running)
        XCTAssertTrue(session.isWatchingFileSystem)
        XCTAssertFalse(session.health.isDegraded)
    }

    func testFilenameIndexStartsLazilyOnFirstRequest() async throws {
        let fixture = try makeFixture(
            filenameScan: { root, _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(
                        WorkspaceDiscoveryBatch(
                            entries: [
                                WorkspaceFileEntry(
                                    url: root.appendingPathComponent("Sources/main.swift"),
                                    relativePath: "Sources/main.swift",
                                    kind: .file,
                                    isHidden: false,
                                    isIgnored: false
                                )
                            ],
                            discoveredCount: 1
                        )
                    )
                    continuation.finish()
                }
            }
        )
        await fixture.session.start()
        await fixture.session.waitForPendingWork()

        XCTAssertEqual(fixture.recorder.filenameScanCount, 0)
        let initialMatches = await fixture.session.filenameIndex.search("main")
        XCTAssertTrue(initialMatches.isEmpty)

        fixture.session.startFilenameIndexing()
        await fixture.session.waitForPendingWork()
        let matches = await fixture.session.filenameIndex.search("main")

        XCTAssertEqual(fixture.recorder.filenameScanCount, 1)
        XCTAssertEqual(
            matches.first?.entry.relativePath,
            "Sources/main.swift"
        )
    }

    func testConcurrentShutdownsJoinOneTeardownAndAreIdempotent() async throws {
        let fixture = try makeFixture()
        let session = fixture.session
        await session.start()
        await session.waitForPendingWork()
        let watcher = try XCTUnwrap(fixture.recorder.watchers.first)

        let first = Task { @MainActor in await session.shutdown() }
        let second = Task { @MainActor in await session.shutdown() }
        _ = await (first.value, second.value)
        await session.shutdown()

        XCTAssertEqual(session.state, .stopped)
        XCTAssertEqual(fixture.recorder.languageStopCount, 1)
        XCTAssertEqual(watcher.stopCount, 1)
        XCTAssertEqual(fixture.recorder.persistStateCount, 1)
        XCTAssertTrue(session.languageServices.isShutDown)
        XCTAssertFalse(session.isWatchingFileSystem)
    }

    func testShutdownSessionNeverRestarts() async throws {
        let fixture = try makeFixture()
        let session = fixture.session
        await session.start()
        await session.waitForPendingWork()
        await session.shutdown()

        await session.start()
        session.startDiscovery()
        await session.refresh([.watcher, .git, .language])

        XCTAssertEqual(session.state, .stopped)
        XCTAssertEqual(fixture.recorder.scanCount, 1)
        XCTAssertEqual(fixture.recorder.gitStartCount, 1)
        XCTAssertEqual(fixture.recorder.languageStartCount, 1)
        XCTAssertEqual(fixture.recorder.watcherFactoryCount, 1)
    }

    // MARK: - Degraded startup

    func testPartialSubsystemFailureLeavesSessionRunningButDegraded() async throws {
        let fixture = try makeFixture(
            watcherStartError: WorkspaceFileWatcherError.streamStartFailed,
            gitStartError: SubsystemFailure.cannotStart,
            languageStartError: SubsystemFailure.cannotStart
        )
        let session = fixture.session

        await session.start()
        await session.waitForPendingWork()

        XCTAssertEqual(session.state, .degraded)
        XCTAssertTrue(session.health.isDegraded)
        XCTAssertEqual(
            session.health.degradedSubsystems,
            [.watcher, .git, .language]
        )
        XCTAssertEqual(
            session.health.issue(for: .watcher)?.severity,
            .unavailable
        )
        XCTAssertFalse(session.isWatchingFileSystem)
        // Source viewing/discovery/search stay usable: discovery still
        // completed and the session is still started.
        XCTAssertNil(session.health.issue(for: .discovery))
        XCTAssertNil(session.health.issue(for: .search))
        XCTAssertTrue(
            fixture.recorder.discoveryStatuses.contains(.completed(fileCount: 0))
        )
    }

    func testSearchEngineFailureEntersHealthWithoutStoppingTheSession() async throws {
        let fixture = try makeFixture(searcherError: SubsystemFailure.cannotStart)
        let session = fixture.session
        await session.start()
        await session.waitForPendingWork()

        XCTAssertThrowsError(try session.textSearcher())
        XCTAssertEqual(session.health.degradedSubsystems, [.search])
        XCTAssertEqual(session.state, .degraded)
        XCTAssertTrue(session.isWatchingFileSystem)
    }

    func testLanguageProfileHealthIssuesRemainDistinctAndClearNarrowly() throws {
        let fixture = try makeFixture()
        let session = fixture.session
        session.recordHealthIssue(
            scope: .languageProfile(identifier: "swift"),
            severity: .unavailable,
            message: "Swift language support is unavailable",
            reason: "missing",
            recoveryActionIDs: [.retry]
        )
        session.recordHealthIssue(
            scope: .languageProfile(identifier: "typescript"),
            severity: .degraded,
            message: "TypeScript language support is unavailable",
            reason: "crashed",
            recoveryActionIDs: [.retry]
        )

        XCTAssertEqual(session.health.issues.count, 2)
        XCTAssertEqual(session.health.degradedSubsystems, [.language])

        session.clearHealthIssue(
            scope: .languageProfile(identifier: "swift")
        )

        XCTAssertEqual(session.health.issues.count, 1)
        XCTAssertEqual(
            session.health.issues.first?.id.rawValue,
            "language-profile:typescript"
        )
    }

    func testLayoutPersistenceFailureEntersHealthAndIsRecordedOnce() async throws {
        let fixture = try makeFixture()
        let session = fixture.session
        await session.start()
        await session.waitForPendingWork()
        let healthEventsBefore = fixture.recorder.healthEvents.count

        // A layout whose tree names the same group twice fails
        // validation inside the store, so persistence throws.
        let duplicated = EditorGroupID()
        var invalid = WorkspaceLayoutState.singleGroup()
        invalid.root = .split(
            orientation: .horizontal,
            ratio: 0.5,
            first: .leaf(duplicated),
            second: .leaf(duplicated)
        )
        session.persistLayout(invalid)
        session.persistLayout(invalid)

        XCTAssertEqual(session.health.degradedSubsystems, [.persistence])
        XCTAssertEqual(
            fixture.recorder.healthEvents.count,
            healthEventsBefore + 1,
            "A repeated identical failure must not re-publish or re-log"
        )

        session.persistLayout(.singleGroup())
        XCTAssertFalse(session.health.isDegraded)
        XCTAssertEqual(session.state, .running)
    }

    // MARK: - Refresh

    func testRefreshRetriesOnlyTheFailedSubsystem() async throws {
        let fixture = try makeFixture(
            watcherStartError: WorkspaceFileWatcherError.streamCreationFailed
        )
        let session = fixture.session
        await session.start()
        await session.waitForPendingWork()
        XCTAssertEqual(session.health.degradedSubsystems, [.watcher])

        await session.refresh()

        XCTAssertEqual(fixture.recorder.watcherFactoryCount, 2)
        XCTAssertEqual(
            fixture.recorder.gitStartCount,
            1,
            "A watcher failure must not restart Git"
        )
        XCTAssertEqual(
            fixture.recorder.languageStartCount,
            1,
            "A watcher failure must not restart language services"
        )
        XCTAssertEqual(
            fixture.recorder.scanCount,
            1,
            "A watcher failure must not re-run discovery"
        )
        XCTAssertEqual(session.state, .degraded)
    }

    func testRefreshClearsHealthWhenTheSubsystemRecovers() async throws {
        let root = try makeRoot()
        let identity = try WorkspaceIdentity(root: root)
        let appFixture = try KodAppTestEnvironment.make(in: self)
        let recorder = Recorder()
        recorder.shouldWatcherFail = true

        var services = WorkspaceSessionServices()
        services.scanDirectory = { _, _, _ in
            recorder.scanCount += 1
            return AsyncThrowingStream { continuation in
                continuation.finish()
            }
        }
        services.makeFileWatcher = { _, onBatch in
            recorder.watcherFactoryCount += 1
            let watcher = FakeFileWatcher(
                startError: recorder.shouldWatcherFail
                    ? WorkspaceFileWatcherError.streamStartFailed
                    : nil,
                onBatch: onBatch
            )
            recorder.watchers.append(watcher)
            return watcher
        }
        services.startGitCoordinator = { _ in recorder.gitStartCount += 1 }
        services.startLanguageServices = { _ in recorder.languageStartCount += 1 }
        services.stopLanguageServices = { coordinator in
            recorder.languageStopCount += 1
            await coordinator.stopAll()
        }
        let session = WorkspaceSession(
            identity: identity,
            dependencies: appFixture.environment.makeWorkspaceDependencies(),
            services: services
        )
        addTeardownBlock { await session.shutdown() }

        await session.start()
        await session.waitForPendingWork()
        XCTAssertEqual(session.state, .degraded)

        recorder.shouldWatcherFail = false
        await session.refresh([.watcher])

        XCTAssertTrue(session.isWatchingFileSystem)
        XCTAssertFalse(session.health.isDegraded)
        XCTAssertEqual(session.state, .running)
    }

    func testTypedRecoveryRetriesOnlyTheAddressedFailedSubsystem() async throws {
        let fixture = try makeFixture(
            watcherStartError: WorkspaceFileWatcherError.streamStartFailed,
            gitStartError: SubsystemFailure.cannotStart
        )
        let session = fixture.session
        await session.start()
        await session.waitForPendingWork()
        let watcherIssue = try XCTUnwrap(session.health.issue(for: .watcher))

        await session.performRecovery(
            WorkspaceHealthRecoveryIntent(
                issueID: watcherIssue.id,
                actionID: .retry
            )
        )

        XCTAssertEqual(fixture.recorder.watcherFactoryCount, 2)
        XCTAssertEqual(
            fixture.recorder.gitStartCount,
            1,
            "Retrying the watcher issue must not retry a separate Git issue"
        )
        XCTAssertEqual(session.health.issue(for: .watcher)?.state, .failed)
        XCTAssertNotNil(session.health.issue(for: .git))
    }

    func testUnsupportedRecoveryActionDoesNothing() async throws {
        let fixture = try makeFixture(gitStartError: SubsystemFailure.cannotStart)
        let session = fixture.session
        await session.start()
        await session.waitForPendingWork()
        let gitIssue = try XCTUnwrap(session.health.issue(for: .git))

        await session.performRecovery(
            WorkspaceHealthRecoveryIntent(
                issueID: gitIssue.id,
                actionID: .refresh
            )
        )

        XCTAssertEqual(fixture.recorder.gitStartCount, 1)
        XCTAssertEqual(session.health.issue(for: .git)?.state, .failed)
    }

    // MARK: - Watcher survives a root that changes

    /// The bug this pins down: `startFileWatcherIfNeeded()` short-circuits
    /// on a non-`nil` handle, so once the root changed underneath the
    /// stream, live updates were dead for the rest of the session even
    /// though the session still reported itself as watching.
    func testRootInvalidationAlwaysBuildsAFreshStream() async throws {
        let fixture = try makeFixture()
        let session = fixture.session
        await session.start()
        await session.waitForPendingWork()
        XCTAssertEqual(fixture.recorder.watcherFactoryCount, 1)
        let original = try XCTUnwrap(fixture.recorder.watchers.first)

        XCTAssertEqual(session.handleRootInvalidation(), .restored)

        XCTAssertEqual(original.stopCount, 1)
        XCTAssertEqual(fixture.recorder.watcherFactoryCount, 2)
        XCTAssertEqual(fixture.recorder.watchers.count, 2)
        XCTAssertTrue(session.isWatchingFileSystem)
        XCTAssertNil(session.health.issue(for: .watcher))
    }

    func testReplacedRootIsReportedAndRewatched() async throws {
        let fixture = try makeFixture()
        let session = fixture.session
        await session.start()
        await session.waitForPendingWork()

        // Same path, different directory.
        try FileManager.default.removeItem(at: fixture.root)
        try FileManager.default.createDirectory(
            at: fixture.root,
            withIntermediateDirectories: true
        )

        XCTAssertEqual(session.handleRootInvalidation(), .replaced)
        XCTAssertEqual(fixture.recorder.watcherFactoryCount, 2)
        XCTAssertTrue(session.isWatchingFileSystem)
        XCTAssertNil(session.health.issue(for: .watcher))
    }

    func testMissingRootStopsWatchingUntilTheRootComesBack() async throws {
        let fixture = try makeFixture()
        let session = fixture.session
        await session.start()
        await session.waitForPendingWork()
        let original = try XCTUnwrap(fixture.recorder.watchers.first)

        try FileManager.default.removeItem(at: fixture.root)

        XCTAssertEqual(session.handleRootInvalidation(), .missing)
        XCTAssertEqual(original.stopCount, 1)
        XCTAssertFalse(session.isWatchingFileSystem)
        XCTAssertEqual(
            fixture.recorder.watcherFactoryCount,
            1,
            "there is nothing to watch, so no stream is created for a path that does not exist"
        )
        XCTAssertEqual(
            session.health.issue(for: .watcher)?.severity,
            .unavailable
        )

        // Discovery finding the root again is what brings live updates
        // back; nothing else has to be restarted for it.
        try FileManager.default.createDirectory(
            at: fixture.root,
            withIntermediateDirectories: true
        )
        session.startFileWatcherIfNeeded()

        XCTAssertTrue(session.isWatchingFileSystem)
        XCTAssertEqual(fixture.recorder.watcherFactoryCount, 2)
        XCTAssertNil(session.health.issue(for: .watcher))
    }

    func testWatcherRecoveryReplacesAHealthyLookingStream() async throws {
        let fixture = try makeFixture()
        let session = fixture.session
        await session.start()
        await session.waitForPendingWork()
        let original = try XCTUnwrap(fixture.recorder.watchers.first)

        await session.refresh([.watcher])

        XCTAssertEqual(
            original.stopCount,
            1,
            "an explicit watcher retry must discard the old stream rather than no-op on a non-nil handle"
        )
        XCTAssertEqual(fixture.recorder.watcherFactoryCount, 2)
        XCTAssertTrue(session.isWatchingFileSystem)
    }

    // MARK: - Shutdown cancels in-flight work

    func testShutdownCancelsAndAwaitsDiscoverySearchAndReloadWork() async throws {
        let scanGate = ContinuationGate()
        let searchGate = ContinuationGate()
        let reloadGate = ContinuationGate()
        let recorderBox = Recorder()

        let fixture = try makeFixture(
            recorder: recorderBox,
            directoryScan: { _, _, _ in
                AsyncThrowingStream { continuation in
                    // Deliberately never finished: discovery stays in
                    // flight until shutdown cancels it.
                    continuation.onTermination = { _ in
                        Task { @MainActor in
                            recorderBox.scanTerminated = true
                            scanGate.open()
                        }
                    }
                }
            }
        )
        let session = fixture.session
        let recorder = fixture.recorder
        await session.start()

        session.runSearch {
            recorder.searchStarted = true
            await searchGate.wait()
            recorder.searchObservedCancellation = Task.isCancelled
        }

        session.beginExternalReload(forPath: "reloaded.swift") {
            recorder.reloadStarted = true
            await reloadGate.wait()
            recorder.reloadObservedCancellation = Task.isCancelled
        }

        await session.shutdown()
        await scanGate.wait()

        XCTAssertEqual(session.state, .stopped)
        XCTAssertTrue(recorder.searchStarted)
        XCTAssertTrue(recorder.reloadStarted)
        XCTAssertTrue(
            recorder.searchObservedCancellation,
            "Shutdown must cancel in-flight search work"
        )
        XCTAssertTrue(
            recorder.reloadObservedCancellation,
            "Shutdown must cancel the in-flight external reload"
        )
        XCTAssertTrue(
            recorder.scanTerminated,
            "Shutdown must cancel the running scan"
        )
        XCTAssertFalse(
            recorder.discoveryStatuses.contains {
                if case .completed = $0 {
                    return true
                }
                return false
            },
            "A cancelled scan must never report completion"
        )
        XCTAssertEqual(recorder.languageStopCount, 1)
        XCTAssertTrue(session.languageServices.isShutDown)
        XCTAssertFalse(session.isWatchingFileSystem)
    }

    /// One FSEvents batch routinely touches several open files. Each
    /// path's reload must stand on its own: only a newer reload of the
    /// *same* path may supersede an older one.
    func testExternalReloadsOfDifferentPathsDoNotCancelEachOther() async throws {
        let fixture = try makeFixture()
        let session = fixture.session
        await session.start()
        await session.waitForPendingWork()

        let firstGate = ContinuationGate()
        let secondGate = ContinuationGate()
        let observations = ReloadObservations()

        session.beginExternalReload(forPath: "first.swift") {
            await firstGate.wait()
            observations.record("first", cancelled: Task.isCancelled)
        }
        session.beginExternalReload(forPath: "second.swift") {
            await secondGate.wait()
            observations.record("second", cancelled: Task.isCancelled)
        }

        XCTAssertEqual(
            session.pathsWithExternalReloadInFlight,
            ["first.swift", "second.swift"]
        )

        firstGate.open()
        secondGate.open()
        await session.waitForPendingWork()

        XCTAssertEqual(Set(observations.completedPaths), ["first", "second"])
        XCTAssertEqual(observations.cancelledPaths, [])
        XCTAssertTrue(session.pathsWithExternalReloadInFlight.isEmpty)
    }

    func testExternalReloadOfTheSamePathSupersedesTheOlderOne() async throws {
        let fixture = try makeFixture()
        let session = fixture.session
        await session.start()
        await session.waitForPendingWork()

        let staleGate = ContinuationGate()
        let freshGate = ContinuationGate()
        let observations = ReloadObservations()

        session.beginExternalReload(forPath: "same.swift") {
            await staleGate.wait()
            observations.record("stale", cancelled: Task.isCancelled)
        }
        session.beginExternalReload(forPath: "same.swift") {
            await freshGate.wait()
            observations.record("fresh", cancelled: Task.isCancelled)
        }
        freshGate.open()
        await session.waitForPendingWork()

        XCTAssertEqual(observations.cancelledPaths, ["stale"])
        XCTAssertEqual(Set(observations.completedPaths), ["fresh", "stale"])
        XCTAssertTrue(session.pathsWithExternalReloadInFlight.isEmpty)
    }

    func testCancellingAnExternalReloadStopsOnlyThatPath() async throws {
        let fixture = try makeFixture()
        let session = fixture.session
        await session.start()
        await session.waitForPendingWork()

        let deletedGate = ContinuationGate()
        let survivingGate = ContinuationGate()
        let observations = ReloadObservations()

        session.beginExternalReload(forPath: "deleted.swift") {
            await deletedGate.wait()
            observations.record("deleted", cancelled: Task.isCancelled)
        }
        session.beginExternalReload(forPath: "surviving.swift") {
            await survivingGate.wait()
            observations.record("surviving", cancelled: Task.isCancelled)
        }
        session.cancelExternalReload(forPath: "deleted.swift")
        survivingGate.open()
        await session.waitForPendingWork()

        XCTAssertEqual(observations.cancelledPaths, ["deleted"])
        XCTAssertEqual(
            session.pathsWithExternalReloadInFlight,
            []
        )
    }

    /// A cancelled reload finishing late must not deregister the reload
    /// that replaced it, or the next change to that path would have
    /// nothing to supersede and two reads would race for the same tab.
    func testARestartedReloadStaysTrackedWhenItsPredecessorFinishesLate() async throws {
        let fixture = try makeFixture()
        let session = fixture.session
        await session.start()
        await session.waitForPendingWork()

        let staleGate = ContinuationGate()
        let freshGate = ContinuationGate()
        let observations = ReloadObservations()

        let stale = session.beginExternalReload(forPath: "restarted.swift") {
            await staleGate.wait()
            observations.record("stale", cancelled: Task.isCancelled)
        }
        session.cancelExternalReload(forPath: "restarted.swift")
        let fresh = session.beginExternalReload(forPath: "restarted.swift") {
            await freshGate.wait()
            observations.record("fresh", cancelled: Task.isCancelled)
        }
        await stale.value

        XCTAssertEqual(
            session.pathsWithExternalReloadInFlight,
            ["restarted.swift"],
            "the restarted reload must still be the tracked one for its path"
        )

        freshGate.open()
        await fresh.value

        XCTAssertEqual(observations.cancelledPaths, ["stale"])
        XCTAssertTrue(session.pathsWithExternalReloadInFlight.isEmpty)
    }

    func testWorkStartedAfterShutdownIsRefused() async throws {
        let fixture = try makeFixture()
        let session = fixture.session
        let recorder = fixture.recorder
        await session.start()
        await session.waitForPendingWork()
        await session.shutdown()

        let task = session.runTracked(.search) {
            recorder.ranAfterShutdown = true
        }
        await task.value

        XCTAssertFalse(recorder.ranAfterShutdown)
    }

    // MARK: - Events stop after shutdown

    func testEventsStopAfterShutdown() async throws {
        let fixture = try makeFixture()
        let session = fixture.session
        let recorder = fixture.recorder
        await session.start()
        await session.waitForPendingWork()

        let watcher = try XCTUnwrap(recorder.watchers.first)
        let fileChangeCountBefore = recorder.fileChangeBatches.count
        watcher.onBatch(WorkspaceChangeBatch(paths: []))
        await drainMainActorWork()
        XCTAssertEqual(
            recorder.fileChangeBatches.count,
            fileChangeCountBefore + 1,
            "pre-shutdown file event"
        )
        let gitStatusCountBefore = recorder.gitStatusEvents
        recorder.gitStatusPublish?(nil)
        XCTAssertEqual(
            recorder.gitStatusEvents,
            gitStatusCountBefore + 1,
            "pre-shutdown Git event"
        )
        let languageStateCountBefore = recorder.languageStateEvents
        session.languageServices.onStateChange?()
        XCTAssertEqual(
            recorder.languageStateEvents,
            languageStateCountBefore + 1,
            "pre-shutdown language event"
        )

        await session.shutdown()

        let fileChangeCountAtShutdown = recorder.fileChangeBatches.count
        let gitStatusCountAtShutdown = recorder.gitStatusEvents
        let languageStateCountAtShutdown = recorder.languageStateEvents
        let discoveryStatusesAfterStart = recorder.discoveryStatuses.count
        watcher.onBatch(WorkspaceChangeBatch(paths: []))
        await drainMainActorWork()
        recorder.gitStatusPublish?(nil)
        session.languageServices.onStateChange?()
        session.startDiscovery()
        session.persistLayout(.singleGroup())

        XCTAssertEqual(
            recorder.fileChangeBatches.count,
            fileChangeCountAtShutdown,
            "post-shutdown file event"
        )
        XCTAssertEqual(
            recorder.gitStatusEvents,
            gitStatusCountAtShutdown,
            "post-shutdown Git event"
        )
        XCTAssertEqual(
            recorder.languageStateEvents,
            languageStateCountAtShutdown,
            "post-shutdown language event"
        )
        XCTAssertEqual(
            recorder.discoveryStatuses.count,
            discoveryStatusesAfterStart,
            "post-shutdown discovery event"
        )
    }

    // MARK: - Git change routing

    func testFileSystemChangesAreRoutedToGitAsSessionOwnedWork() async throws {
        let fixture = try makeFixture()
        let session = fixture.session
        await session.start()
        await session.waitForPendingWork()

        session.handleFileSystemChanges(WorkspaceChangeBatch(paths: []))
        await session.waitForPendingWork()

        // No repository exists for the temp root, so the coordinator has
        // nothing to refresh — the point is that the work completed under
        // the session rather than in an untracked detached task.
        XCTAssertNil(session.gitCoordinator.context)
        XCTAssertEqual(session.state, .running)
    }
}

// MARK: - Test doubles

private enum SubsystemFailure: Error {
    case cannotStart
}

/// Records which per-path external reloads ran and which of them
/// observed cancellation, from inside session-owned work.
@MainActor
private final class ReloadObservations {
    private(set) var completedPaths: [String] = []
    private(set) var cancelledPaths: [String] = []

    func record(_ path: String, cancelled: Bool) {
        completedPaths.append(path)
        if cancelled {
            cancelledPaths.append(path)
        }
    }
}

/// Resumes exactly once, either explicitly or on task cancellation,
/// so a test can hold work "in flight" without sleeping.
@MainActor
private final class ContinuationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen {
            return
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if isOpen {
                    continuation.resume()
                } else {
                    self.continuation = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.open()
            }
        }
    }

    func open() {
        isOpen = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

private final class FakeFileWatcher: WorkspaceFileWatching, @unchecked Sendable {
    private let startError: (any Error)?
    /// Only ever touched from the main actor (the session starts and
    /// stops it there, and the tests read it there).
    private(set) var startCount = 0
    private(set) var stopCount = 0
    let onBatch: @Sendable (WorkspaceChangeBatch) -> Void

    init(
        startError: (any Error)? = nil,
        onBatch: @escaping @Sendable (WorkspaceChangeBatch) -> Void
    ) {
        self.startError = startError
        self.onBatch = onBatch
    }

    func start() throws {
        startCount += 1
        if let startError {
            throw startError
        }
    }

    func stop() {
        stopCount += 1
    }
}

/// Everything the injected services record, so assertions are about
/// observed calls rather than timing.
@MainActor
private final class Recorder {
    var scanCount = 0
    var filenameScanCount = 0
    var watcherFactoryCount = 0
    var gitStartCount = 0
    var languageStartCount = 0
    var languageStopCount = 0
    var searcherFactoryCount = 0
    var persistStateCount = 0
    var watchers: [FakeFileWatcher] = []
    var gitStatusPublish: ((GitStatusSnapshot?) -> Void)?

    var discoveryStatuses: [WorkspaceDiscoveryStatus] = []
    var discoveryBatches: [WorkspaceDiscoveryBatch] = []
    var fileChangeBatches: [WorkspaceChangeBatch] = []
    var gitStatusEvents = 0
    var languageStateEvents = 0
    var healthEvents: [WorkspaceHealth] = []

    /// Observations made from inside session-owned work. Held in a
    /// reference type so the work closures stay `@Sendable`.
    var searchStarted = false
    var searchObservedCancellation = false
    var reloadStarted = false
    var reloadObservedCancellation = false
    var ranAfterShutdown = false
    var scanTerminated = false
    var shouldWatcherFail = false
}

private struct Fixture {
    let root: URL
    let session: WorkspaceSession
    let recorder: Recorder
}
