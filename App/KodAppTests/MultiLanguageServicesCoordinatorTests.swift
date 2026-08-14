import CodeViewport
import DiagnosticsCore
import LanguageAdapters
import LanguageClient
import SettingsCore
import SourceIO
import SourceModel
import WorkspaceCore
import XCTest
@testable import Kod

/// Headless coverage for `MultiLanguageServicesCoordinator`'s profile
/// selection and lazy-start behavior (SPEC 6.2: "one server process
/// shared per workspace, language adapter"). No real language server
/// process is launched here — `service(forURL:)` before any document is
/// opened simply returns `nil`.
@MainActor
final class MultiLanguageServicesCoordinatorTests: XCTestCase {
    private func makeRepository() -> CodableSettingsRepository {
        CodableSettingsRepository(
            store: InMemorySettingsKeyValueStore()
        )
    }

    private func makeTrustedIdentity() throws -> (WorkspaceIdentity, WorkspaceTrustStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let identity = try WorkspaceIdentity(root: root)
        let store = WorkspaceTrustStore(repository: makeRepository())
        try store.trust(identity)
        return (identity, store)
    }

    private func makeRegistry() throws -> LanguageProfileRegistry {
        return LanguageProfileRegistry(
            store: try LanguageProfileStore(repository: makeRepository())
        )
    }

    func testLanguageServerProfilesIncludeSwiftAndFirstWaveLanguages() throws {
        let (identity, store) = try makeTrustedIdentity()
        let coordinator = MultiLanguageServicesCoordinator(
            identity: identity,
            trustStore: store,
            profileRegistry: try makeRegistry(),
            overrideStore: try KodAppTestEnvironment.makeOverrideStore(in: self),
            diagnosticsLog: BoundedEventLog(),
            diagnosticsStore: WorkspaceDiagnosticsStore()
        )
        let identifiers = Set(
            coordinator.languageServerProfiles.map(\.identifier)
        )
        XCTAssertTrue(identifiers.contains("swift"))
        XCTAssertTrue(identifiers.contains("typescript"))
        XCTAssertTrue(identifiers.contains("shellscript"))
        XCTAssertTrue(identifiers.contains("markdown"))
        XCTAssertTrue(identifiers.contains("c"))
        XCTAssertTrue(identifiers.contains("go"))
        XCTAssertTrue(identifiers.contains("java"))
        XCTAssertTrue(identifiers.contains("ruby"))
        XCTAssertTrue(identifiers.contains("lua"))
        XCTAssertTrue(identifiers.contains("graphql"))
        XCTAssertTrue(identifiers.contains("xml"))
    }

    func testServiceForURLIsNilBeforeAnyDocumentIsOpened() throws {
        let (identity, store) = try makeTrustedIdentity()
        let coordinator = MultiLanguageServicesCoordinator(
            identity: identity,
            trustStore: store,
            profileRegistry: try makeRegistry(),
            overrideStore: try KodAppTestEnvironment.makeOverrideStore(in: self),
            diagnosticsLog: BoundedEventLog(),
            diagnosticsStore: WorkspaceDiagnosticsStore()
        )
        XCTAssertNil(coordinator.service(forURL: URL(fileURLWithPath: "/workspace/main.ts")))
    }

    func testServiceForURLReturnsNilForAnUnrecognizedExtension() throws {
        let (identity, store) = try makeTrustedIdentity()
        let coordinator = MultiLanguageServicesCoordinator(
            identity: identity,
            trustStore: store,
            profileRegistry: try makeRegistry(),
            overrideStore: try KodAppTestEnvironment.makeOverrideStore(in: self),
            diagnosticsLog: BoundedEventLog(),
            diagnosticsStore: WorkspaceDiagnosticsStore()
        )
        XCTAssertNil(
            coordinator.service(
                forURL: URL(fileURLWithPath: "/workspace/file.unknown")
            )
        )
    }

    func testTrustRevocationClearsEveryDiagnosticOwner() throws {
        let (identity, store) = try makeTrustedIdentity()
        let diagnosticsStore = WorkspaceDiagnosticsStore()
        let coordinator = MultiLanguageServicesCoordinator(
            identity: identity,
            trustStore: store,
            profileRegistry: try makeRegistry(),
            overrideStore: try KodAppTestEnvironment.makeOverrideStore(in: self),
            diagnosticsLog: BoundedEventLog(),
            diagnosticsStore: diagnosticsStore
        )
        let url = identity.root.appendingPathComponent("Shared.swift")
        let diagnostic = Diagnostic(
            range: LSPRange(
                start: LSPPosition(line: 0, character: 0),
                end: LSPPosition(line: 0, character: 1)
            ),
            severity: .warning,
            code: nil,
            source: nil,
            message: "Shared"
        )
        diagnosticsStore.replace(owner: "swift", resource: url, diagnostics: [diagnostic])
        diagnosticsStore.replace(owner: "typescript", resource: url, diagnostics: [diagnostic])

        try store.revoke(identity)
        coordinator.handleTrustRevoked()

        XCTAssertTrue(diagnosticsStore.snapshot.diagnosticsByOwner.isEmpty)
    }

    func testTrustRevocationClearsNormalizedMarkersForTrackedDocuments() throws {
        let (identity, store) = try makeTrustedIdentity()
        try store.revoke(identity)
        let coordinator = MultiLanguageServicesCoordinator(
            identity: identity,
            trustStore: store,
            profileRegistry: try makeRegistry(),
            overrideStore: try KodAppTestEnvironment.makeOverrideStore(in: self),
            diagnosticsLog: BoundedEventLog(),
            diagnosticsStore: WorkspaceDiagnosticsStore()
        )
        var emissions: [(URL, [NormalizedDiagnostic])] = []
        coordinator.onNormalizedDiagnostics = { url, diagnostics in
            emissions.append((url, diagnostics))
        }
        let snapshot = SourceSnapshot(
            text: "let value = 1\n",
            url: identity.root.appendingPathComponent("Tracked.swift"),
            version: 1
        )
        let controller = CodeDocumentViewController(snapshot: snapshot)
        coordinator.handleDocumentReady(
            relativePath: "Tracked.swift",
            controller: controller
        )

        withExtendedLifetime(controller) {
            coordinator.handleTrustRevoked()
        }

        XCTAssertEqual(emissions.count, 1)
        XCTAssertEqual(emissions.first?.0, snapshot.url.standardizedFileURL)
        XCTAssertTrue(emissions.first?.1.isEmpty == true)
    }

    /// Problems navigation converts wire ranges through the coordinator so
    /// the owning service's negotiated encoding is used. With no service
    /// started for the file it must still convert, falling back to the LSP
    /// default (UTF-16) rather than failing to navigate.
    func testUTF8RangeConversionFallsBackToUTF16WithoutAService() async throws {
        let (identity, store) = try makeTrustedIdentity()
        let coordinator = MultiLanguageServicesCoordinator(
            identity: identity,
            trustStore: store,
            profileRegistry: try makeRegistry(),
            overrideStore: try KodAppTestEnvironment.makeOverrideStore(in: self),
            diagnosticsLog: BoundedEventLog(),
            diagnosticsStore: WorkspaceDiagnosticsStore()
        )
        let snapshot = SourceSnapshot(
            text: "lét value\n",
            url: identity.root.appendingPathComponent("Encoding.ts"),
            version: 1
        )
        XCTAssertNil(coordinator.service(forURL: snapshot.url))

        let converted = await coordinator.utf8Range(
            for: LSPRange(
                start: LSPPosition(line: 0, character: 0),
                end: LSPPosition(line: 0, character: 4)
            ),
            in: snapshot
        )
        XCTAssertEqual(converted, 0..<5, "\"lét \" is four UTF-16 code units")

        let outOfBounds = await coordinator.utf8Range(
            for: LSPRange(
                start: LSPPosition(line: 42, character: 0),
                end: LSPPosition(line: 42, character: 1)
            ),
            in: snapshot
        )
        XCTAssertNil(outOfBounds)
    }

    /// A close must not discard workspace problems: only the editor-facing
    /// normalized callback is cleared, and the raw store keeps reporting
    /// files that are not open at all.
    func testRawWorkspaceDiagnosticsSurviveWithoutAnOpenDocument() throws {
        let (identity, store) = try makeTrustedIdentity()
        let diagnosticsStore = WorkspaceDiagnosticsStore()
        let coordinator = MultiLanguageServicesCoordinator(
            identity: identity,
            trustStore: store,
            profileRegistry: try makeRegistry(),
            overrideStore: try KodAppTestEnvironment.makeOverrideStore(in: self),
            diagnosticsLog: BoundedEventLog(),
            diagnosticsStore: diagnosticsStore
        )
        var normalized: [(URL, [NormalizedDiagnostic])] = []
        coordinator.onNormalizedDiagnostics = { url, diagnostics in
            normalized.append((url, diagnostics))
        }
        let url = identity.root.appendingPathComponent("Unopened.swift")
        let diagnostic = Diagnostic(
            range: LSPRange(
                start: LSPPosition(line: 0, character: 0),
                end: LSPPosition(line: 0, character: 1)
            ),
            severity: .error,
            code: nil,
            source: nil,
            message: "Unopened"
        )
        diagnosticsStore.replace(owner: "swift", resource: url, diagnostics: [diagnostic])

        XCTAssertEqual(
            diagnosticsStore.snapshot.presentationDiagnosticsByFile[url.standardizedFileURL],
            [diagnostic]
        )
        XCTAssertTrue(normalized.isEmpty)

        coordinator.diagnosticsStore.clear(owner: "swift")
        XCTAssertTrue(diagnosticsStore.snapshot.presentationDiagnosticsByFile.isEmpty)
    }

    func testHandleDocumentReadyIsANoOpForAnUntrustedWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let identity = try WorkspaceIdentity(root: root)
        let untrustedStore = WorkspaceTrustStore(
            repository: makeRepository()
        )
        let coordinator = MultiLanguageServicesCoordinator(
            identity: identity,
            trustStore: untrustedStore,
            profileRegistry: try makeRegistry(),
            overrideStore: try KodAppTestEnvironment.makeOverrideStore(in: self),
            diagnosticsLog: BoundedEventLog(),
            diagnosticsStore: WorkspaceDiagnosticsStore()
        )

        let fileURL = root.appendingPathComponent("main.ts")
        try "class Foo {}".write(to: fileURL, atomically: true, encoding: .utf8)
        let snapshot = try SourceSnapshotLoader().load(url: fileURL, version: 1)
        let documentController = CodeDocumentViewController(snapshot: snapshot)
        coordinator.handleDocumentReady(
            relativePath: "main.ts",
            controller: documentController
        )

        // Give any (incorrectly) started async work a moment to run.
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(coordinator.service(forURL: fileURL), "No service may start for an untrusted workspace")

        try untrustedStore.trust(identity)
        coordinator.handleTrustGranted()
        for _ in 0..<50 where coordinator.service(forURL: fileURL) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(
            coordinator.service(forURL: fileURL),
            "Granting trust must retry documents that were already open"
        )
    }

    func testOpenExtensionlessShellUsesSnapshotShebangForURLRouting() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let identity = try WorkspaceIdentity(root: root)
        let coordinator = MultiLanguageServicesCoordinator(
            identity: identity,
            trustStore: WorkspaceTrustStore(
                repository: makeRepository()
            ),
            profileRegistry: try makeRegistry(),
            overrideStore: try KodAppTestEnvironment.makeOverrideStore(in: self),
            diagnosticsLog: BoundedEventLog(),
            diagnosticsStore: WorkspaceDiagnosticsStore()
        )
        let fileURL = root.appendingPathComponent("deploy")
        try "#!/usr/bin/env bash\necho Kod\n".write(
            to: fileURL,
            atomically: true,
            encoding: .utf8
        )
        let snapshot = try SourceSnapshotLoader().load(url: fileURL, version: 1)
        let documentController = CodeDocumentViewController(snapshot: snapshot)

        coordinator.handleDocumentReady(
            relativePath: "deploy",
            controller: documentController
        )

        XCTAssertEqual(coordinator.languageKey(forURL: fileURL), "shellscript")
        XCTAssertEqual(
            coordinator.status(forURL: fileURL)?.languageName,
            DefaultLanguageProfiles.shell.displayName
        )
    }

    /// SPEC (implement-language-ui-refresh): once a language server's
    /// executable becomes available (e.g. after an external install and
    /// a Settings Refresh), `handleLanguageServerExecutableAvailable`
    /// must retry an already-open document whose service previously
    /// failed to launch — restarting it so discovery re-runs, rather
    /// than leaving the stale failure status in place.
    func testExecutableAvailableRestartsAPreviouslyFailedServiceForAnOpenDocument() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let identity = try WorkspaceIdentity(root: root)
        let repository = makeRepository()
        let trustStore = WorkspaceTrustStore(repository: repository)
        try trustStore.trust(identity)
        let overrideStore = LanguageServerOverrideStore(
            repository: repository
        )
        let profileStore = try LanguageProfileStore(
            defaultProfiles: [],
            repository: repository,
            overrideStore: overrideStore
        )
        // A custom profile whose only executable candidate cannot
        // possibly exist, so the very first launch attempt is
        // guaranteed to fail regardless of the host environment.
        let profile = try LanguageProfile(
            identifier: "flaky",
            displayName: "Flaky",
            origin: .custom,
            defaultRevision: 1,
            associations: [
                LanguageFileAssociation(
                    identifier: "files",
                    fileExtensions: ["flaky"],
                    syntax: .plainText
                )
            ],
            languageServer: LanguageServerConfiguration(
                defaultLanguageID: "flaky",
                executableCandidates: [
                    LanguageServerExecutableCandidate(
                        identifier: "flaky",
                        executableNames: [
                            "definitely-not-a-real-lsp-binary"
                        ],
                        arguments: [],
                        discoveryStrategies: [.path]
                    )
                ]
            )
        ).validated()
        try profileStore.createCustomProfile(profile)
        let registry = LanguageProfileRegistry(store: profileStore)

        let coordinator = MultiLanguageServicesCoordinator(
            identity: identity,
            trustStore: trustStore,
            profileRegistry: registry,
            overrideStore: overrideStore,
            diagnosticsLog: BoundedEventLog(),
            diagnosticsStore: WorkspaceDiagnosticsStore()
        )

        let fileURL = root.appendingPathComponent("example.flaky")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)
        let snapshot = try SourceSnapshotLoader().load(url: fileURL, version: 1)
        let documentController = CodeDocumentViewController(snapshot: snapshot)
        coordinator.handleDocumentReady(
            relativePath: "example.flaky",
            controller: documentController
        )

        for _ in 0..<150 {
            if case .missing = coordinator.status(forURL: fileURL)?.state {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .missing = coordinator.status(forURL: fileURL)?.state else {
            return XCTFail(
                "Expected discovery to fail for a nonexistent executable"
            )
        }

        // Install a fake, quickly-exiting "language server" as a
        // per-workspace override — the highest-precedence discovery
        // source — so the retry can actually find something to launch.
        let fakeServer = root.appendingPathComponent("fake-lsp")
        try "#!/bin/sh\nexit 0\n".write(
            to: fakeServer,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeServer.path
        )
        try overrideStore.setWorkspaceOverride(
            url: fakeServer,
            arguments: [],
            languageKey: "flaky",
            identity: identity
        )

        coordinator.handleLanguageServerExecutableAvailable(languageKey: "flaky")

        // The retry must re-run discovery (now finding the override) and
        // attempt a real launch, so the state moves off the original
        // "missing" status — e.g. to starting, then crashed once the
        // fake process exits without completing the LSP handshake.
        var movedPastOriginalMissingState = false
        for _ in 0..<150 {
            if case .missing = coordinator.status(forURL: fileURL)?.state {
                try await Task.sleep(for: .milliseconds(20))
                continue
            }
            movedPastOriginalMissingState = true
            break
        }
        XCTAssertTrue(
            movedPastOriginalMissingState,
            "Expected the coordinator to retry and move past the stale missing status"
        )
    }

    // MARK: - Document registration lifecycle

    /// SPEC 6.3 lifecycle: the same file can be open in several split
    /// panes at once. Every live pane must be tracked — the coordinator
    /// used to key registrations by relative path, so a second pane
    /// silently evicted the first and its decorations/diagnostics stopped
    /// updating.
    func testTwoPanesShowingTheSameFileAreBothRegistered() throws {
        let (identity, _, coordinator) = try makeUntrustedCoordinator()
        let snapshot = Self.snapshot(root: identity.root)

        let first = CodeDocumentViewController(snapshot: snapshot)
        let second = CodeDocumentViewController(snapshot: snapshot)
        coordinator.handleDocumentReady(relativePath: "Shared.swift", controller: first)
        coordinator.handleDocumentReady(relativePath: "Shared.swift", controller: second)

        let live = coordinator.liveDocumentControllers(forURL: snapshot.url)
        XCTAssertEqual(live.count, 2)
        XCTAssertTrue(live.contains { $0 === first })
        XCTAssertTrue(live.contains { $0 === second })
        // Registrations are weak by design, so the panes must be kept alive
        // for the whole test exactly as their editor group would.
        withExtendedLifetime((first, second)) {}
    }

    /// Re-registering the same controller (every reload emits a
    /// document-ready callback) must refresh the existing registration
    /// rather than accumulate duplicates.
    func testRepeatedRegistrationOfTheSameControllerDoesNotAccumulate() throws {
        let (identity, _, coordinator) = try makeUntrustedCoordinator()
        let snapshot = Self.snapshot(root: identity.root)
        let controller = CodeDocumentViewController(snapshot: snapshot)

        coordinator.handleDocumentReady(relativePath: "Shared.swift", controller: controller)
        coordinator.handleDocumentReady(relativePath: "Shared.swift", controller: controller)
        coordinator.handleDocumentReady(relativePath: "Shared.swift", controller: controller)

        XCTAssertEqual(coordinator.liveDocumentControllers(forURL: snapshot.url).count, 1)
        withExtendedLifetime(controller) {}
    }

    /// One semantic-token result decorates every pane showing that file at
    /// that snapshot version — one pane must never be the only one styled,
    /// and a pane on a different version must not be handed a stale layer.
    func testSemanticDecorationsFanOutToEveryPaneShowingTheFile() throws {
        let (identity, _, coordinator) = try makeUntrustedCoordinator()
        let snapshot = Self.snapshot(root: identity.root)
        let first = CodeDocumentViewController(snapshot: snapshot)
        let second = CodeDocumentViewController(snapshot: snapshot)
        let staleVersion = SourceSnapshot(
            text: snapshot.text,
            url: snapshot.url,
            version: snapshot.version + 1
        )
        let third = CodeDocumentViewController(snapshot: staleVersion)
        coordinator.handleDocumentReady(relativePath: "Shared.swift", controller: first)
        coordinator.handleDocumentReady(relativePath: "Shared.swift", controller: second)
        coordinator.handleDocumentReady(relativePath: "Shared.swift", controller: third)

        let tokens = [
            SemanticToken(utf8Range: 0..<3, tokenType: "keyword", tokenModifiers: [])
        ]
        let applied = coordinator.applySemanticTokens(
            tokens,
            url: snapshot.url,
            snapshotVersion: snapshot.version
        )

        XCTAssertEqual(applied, 2, "Both panes on this version must be decorated")
        withExtendedLifetime((first, second, third)) {}
    }

    /// Closing one of two panes cancels only that pane's work: the
    /// document stays open on the language service, no editor markers are
    /// cleared, and the surviving pane keeps receiving decorations.
    func testClosingOnePaneKeepsTheDocumentOpenForTheOther() throws {
        let (identity, _, coordinator) = try makeUntrustedCoordinator()
        let scheduler = CloseSchedulerSpy(installedOn: coordinator)
        let snapshot = Self.snapshot(root: identity.root)
        var closedURLs: [URL] = []
        var normalized: [(URL, [NormalizedDiagnostic])] = []
        coordinator.onDocumentClosed = { closedURLs.append($0) }
        coordinator.onNormalizedDiagnostics = { normalized.append(($0, $1)) }
        let first = CodeDocumentViewController(snapshot: snapshot)
        let second = CodeDocumentViewController(snapshot: snapshot)
        coordinator.handleDocumentReady(relativePath: "Shared.swift", controller: first)
        coordinator.handleDocumentReady(relativePath: "Shared.swift", controller: second)

        coordinator.handleDocumentClosed(relativePath: "Shared.swift", controller: first)

        XCTAssertTrue(closedURLs.isEmpty, "A surviving pane must keep the document open")
        XCTAssertEqual(scheduler.scheduledDelays.count, 0, "No close may even be scheduled")
        XCTAssertTrue(normalized.isEmpty, "Markers belong to the pane that is still open")
        let live = coordinator.liveDocumentControllers(forURL: snapshot.url)
        XCTAssertEqual(live.count, 1)
        XCTAssertTrue(live.first === second)
        XCTAssertEqual(
            coordinator.applySemanticTokens(
                [SemanticToken(utf8Range: 0..<3, tokenType: "keyword", tokenModifiers: [])],
                url: snapshot.url,
                snapshotVersion: snapshot.version
            ),
            1
        )
        withExtendedLifetime((first, second)) {}
    }

    /// Closing the *final* pane closes the document once the scheduled
    /// close fires: editor-facing markers are cleared and the close output
    /// fires, while workspace-wide Problems entries deliberately survive —
    /// a closed file still has problems.
    func testFiringTheScheduledCloseClosesTheDocumentButKeepsWorkspaceDiagnostics() async throws {
        let (identity, _, coordinator, diagnosticsStore) =
            try makeUntrustedCoordinatorWithStore()
        let scheduler = CloseSchedulerSpy(installedOn: coordinator)
        let snapshot = Self.snapshot(root: identity.root)
        let diagnostic = Diagnostic(
            range: LSPRange(
                start: LSPPosition(line: 0, character: 0),
                end: LSPPosition(line: 0, character: 1)
            ),
            severity: .error,
            code: nil,
            source: nil,
            message: "Still a problem"
        )
        diagnosticsStore.replace(
            owner: "swift",
            resource: snapshot.url,
            diagnostics: [diagnostic]
        )
        var closedURLs: [URL] = []
        var normalized: [(URL, [NormalizedDiagnostic])] = []
        coordinator.onDocumentClosed = { closedURLs.append($0) }
        coordinator.onNormalizedDiagnostics = { normalized.append(($0, $1)) }
        let first = CodeDocumentViewController(snapshot: snapshot)
        let second = CodeDocumentViewController(snapshot: snapshot)
        coordinator.handleDocumentReady(relativePath: "Shared.swift", controller: first)
        coordinator.handleDocumentReady(relativePath: "Shared.swift", controller: second)

        coordinator.handleDocumentClosed(relativePath: "Shared.swift", controller: first)
        coordinator.handleDocumentClosed(relativePath: "Shared.swift", controller: second)

        XCTAssertEqual(
            scheduler.scheduledDelays,
            [coordinator.documentCloseGracePeriod],
            "Only the final pane schedules a close, and it waits the grace period"
        )
        XCTAssertTrue(closedURLs.isEmpty, "Nothing closes until the grace period elapses")

        scheduler.fireAll()
        await coordinator.waitForDocumentClose(forURL: snapshot.url)

        XCTAssertEqual(closedURLs, [snapshot.url.standardizedFileURL])
        XCTAssertEqual(normalized.count, 1)
        XCTAssertEqual(normalized.first?.0, snapshot.url.standardizedFileURL)
        XCTAssertTrue(normalized.first?.1.isEmpty == true)
        XCTAssertTrue(coordinator.liveDocumentControllers(forURL: snapshot.url).isEmpty)
        XCTAssertEqual(
            diagnosticsStore.snapshot.presentationDiagnosticsByFile[
                snapshot.url.standardizedFileURL
            ],
            [diagnostic],
            "Problems must keep reporting a file that is no longer open"
        )
        withExtendedLifetime((first, second)) {}
    }

    /// Closing a pane that was never registered (or a second close for the
    /// same controller) must not emit a spurious document close.
    func testClosingAnUnregisteredControllerIsANoOp() async throws {
        let (identity, _, coordinator) = try makeUntrustedCoordinator()
        let scheduler = CloseSchedulerSpy(installedOn: coordinator)
        let snapshot = Self.snapshot(root: identity.root)
        var closedURLs: [URL] = []
        coordinator.onDocumentClosed = { closedURLs.append($0) }
        let controller = CodeDocumentViewController(snapshot: snapshot)
        coordinator.handleDocumentReady(relativePath: "Shared.swift", controller: controller)

        coordinator.handleDocumentClosed(relativePath: "Shared.swift", controller: controller)
        coordinator.handleDocumentClosed(relativePath: "Shared.swift", controller: controller)

        XCTAssertEqual(scheduler.scheduledDelays.count, 1, "A repeated close must not re-schedule")
        scheduler.fireAll()
        await coordinator.waitForDocumentClose(forURL: snapshot.url)

        XCTAssertEqual(closedURLs.count, 1, "A repeated close must not re-close the document")
        withExtendedLifetime(controller) {}
    }

    /// SPEC 6.3's reuse grace period, exercised deterministically through
    /// the injected close scheduler: the final unregister only *schedules*
    /// a close, a reopen cancels it, and firing the now-stale schedule
    /// afterwards must not close anything.
    func testReopeningCancelsAScheduledCloseAndAStaleFireIsInert() throws {
        let (identity, _, coordinator) = try makeUntrustedCoordinator()
        let scheduler = CloseSchedulerSpy(installedOn: coordinator)
        let snapshot = Self.snapshot(root: identity.root)
        var closedURLs: [URL] = []
        var normalized: [(URL, [NormalizedDiagnostic])] = []
        coordinator.onDocumentClosed = { closedURLs.append($0) }
        coordinator.onNormalizedDiagnostics = { normalized.append(($0, $1)) }
        let first = CodeDocumentViewController(snapshot: snapshot)
        coordinator.handleDocumentReady(relativePath: "Shared.swift", controller: first)

        coordinator.handleDocumentClosed(relativePath: "Shared.swift", controller: first)

        XCTAssertEqual(scheduler.scheduledDelays, [.milliseconds(250)])
        XCTAssertEqual(scheduler.cancelCount, 0)

        let reopened = CodeDocumentViewController(snapshot: snapshot)
        coordinator.handleDocumentReady(relativePath: "Shared.swift", controller: reopened)

        XCTAssertEqual(scheduler.cancelCount, 1, "A reopen cancels the still-sleeping close")

        scheduler.fireAll()

        XCTAssertTrue(closedURLs.isEmpty, "A stale fire must not close a reopened document")
        XCTAssertTrue(normalized.isEmpty)
        XCTAssertEqual(coordinator.liveDocumentControllers(forURL: snapshot.url).count, 1)
        withExtendedLifetime((first, reopened)) {}
    }

    /// A synchronization arriving while a close is merely scheduled must
    /// settle that close first — cancelling it, since the file is open
    /// again — so a later fire cannot close a document that was just
    /// synchronized.
    func testSynchronizationCancelsAStillScheduledClose() async throws {
        let (identity, _, coordinator) = try makeUntrustedCoordinator()
        let scheduler = CloseSchedulerSpy(installedOn: coordinator)
        let snapshot = Self.snapshot(root: identity.root)
        var closedURLs: [URL] = []
        coordinator.onDocumentClosed = { closedURLs.append($0) }
        let controller = CodeDocumentViewController(snapshot: snapshot)
        coordinator.handleDocumentReady(relativePath: "Shared.swift", controller: controller)
        coordinator.handleDocumentClosed(relativePath: "Shared.swift", controller: controller)
        XCTAssertEqual(scheduler.scheduledDelays.count, 1)

        let result = await coordinator.synchronizeCoalescing(
            url: snapshot.url,
            profileIdentifier: "swift",
            version: snapshot.version
        ) { .opened }

        XCTAssertEqual(result, .opened)
        XCTAssertEqual(scheduler.cancelCount, 1)
        scheduler.fireAll()
        XCTAssertTrue(closedURLs.isEmpty)
        withExtendedLifetime(controller) {}
    }

    func testVanishedSynchronizationDoesNotCancelTheFinalClose() async throws {
        let (identity, _, coordinator) = try makeUntrustedCoordinator()
        let scheduler = CloseSchedulerSpy(installedOn: coordinator)
        let snapshot = Self.snapshot(root: identity.root)
        let operationRan = MutableFlag(false)
        var closedURLs: [URL] = []
        coordinator.onDocumentClosed = { closedURLs.append($0) }
        let controller = CodeDocumentViewController(snapshot: snapshot)
        coordinator.handleDocumentReady(relativePath: "Shared.swift", controller: controller)
        coordinator.handleDocumentClosed(relativePath: "Shared.swift", controller: controller)

        let result = await coordinator.synchronizeCoalescing(
            url: snapshot.url,
            profileIdentifier: "swift",
            version: snapshot.version,
            shouldStart: { false }
        ) {
            operationRan.value = true
            return .opened
        }

        XCTAssertNil(result)
        XCTAssertFalse(operationRan.value)
        XCTAssertEqual(scheduler.cancelCount, 0)

        scheduler.fireAll()
        await coordinator.waitForDocumentClose(forURL: snapshot.url)
        XCTAssertEqual(closedURLs, [snapshot.url.standardizedFileURL])
        withExtendedLifetime(controller) {}
    }

    /// Two panes racing for the same document and version must produce
    /// exactly one synchronization request: the second joins the in-flight
    /// one instead of issuing a duplicate didOpen, and both callers only
    /// proceed once it has actually completed.
    func testConcurrentSynchronizationsForOneDocumentAreCoalesced() async throws {
        let (identity, _, coordinator) = try makeUntrustedCoordinator()
        let url = identity.root.appendingPathComponent("Shared.swift")
        let probe = SynchronizationProbe()

        let firstCaller = Task { @MainActor in
            await coordinator.synchronizeCoalescing(
                url: url,
                profileIdentifier: "swift",
                version: 1
            ) {
                probe.operationDidStart()
                await probe.waitForRelease()
                return .opened
            }
        }
        await probe.waitUntilStarted()

        let secondCaller = Task { @MainActor in
            await coordinator.synchronizeCoalescing(
                url: url,
                profileIdentifier: "swift",
                version: 1
            ) {
                probe.operationDidStart()
                return .opened
            }
        }
        // Deterministic, sleep-free wait: yield until the second caller has
        // observably joined the in-flight synchronization.
        var yields = 0
        while coordinator.synchronizationJoinCount == 0, yields < 1_000 {
            await Task.yield()
            yields += 1
        }
        XCTAssertEqual(
            coordinator.synchronizationJoinCount,
            1,
            "The second pane must join the in-flight request, not start its own"
        )

        probe.release()
        let results = [await firstCaller.value, await secondCaller.value]

        XCTAssertEqual(results, [.opened, .opened])
        XCTAssertEqual(
            probe.operationCount,
            1,
            "Exactly one didOpen/didChange may be issued for one document version"
        )
    }

    /// A close that fires while a synchronization is still in flight must
    /// wait for it: closing around an already-issued didOpen would leave
    /// the server holding a document nobody owns.
    func testAFiredCloseWaitsForAnInFlightSynchronization() async throws {
        let (identity, _, coordinator) = try makeUntrustedCoordinator()
        let scheduler = CloseSchedulerSpy(installedOn: coordinator)
        let snapshot = Self.snapshot(root: identity.root)
        let probe = SynchronizationProbe()
        let events = EventLog()
        coordinator.onDocumentClosed = { _ in events.append("closed") }
        let controller = CodeDocumentViewController(snapshot: snapshot)
        coordinator.handleDocumentReady(relativePath: "Shared.swift", controller: controller)

        let synchronization = Task { @MainActor in
            await coordinator.synchronizeCoalescing(
                url: snapshot.url,
                profileIdentifier: "swift",
                version: snapshot.version
            ) {
                probe.operationDidStart()
                await probe.waitForRelease()
                events.append("synchronized")
                return .opened
            }
        }
        await probe.waitUntilStarted()

        // The last pane goes away and the grace period elapses while the
        // synchronization is still running.
        coordinator.handleDocumentClosed(relativePath: "Shared.swift", controller: controller)
        XCTAssertEqual(scheduler.scheduledDelays.count, 1)
        scheduler.fireAll()

        for _ in 0..<50 {
            await Task.yield()
        }
        XCTAssertTrue(
            events.entries.isEmpty,
            "The close must not resolve while a synchronization is in flight"
        )

        probe.release()
        _ = await synchronization.value
        await coordinator.waitForDocumentClose(forURL: snapshot.url)

        XCTAssertEqual(events.entries, ["synchronized", "closed"])
        withExtendedLifetime(controller) {}
    }

    /// A pane can vanish while its synchronization waits behind a close or
    /// an older request. Revalidating before the request is issued keeps a
    /// document nobody owns from being opened on the server.
    func testASynchronizationWhoseRequesterVanishesWhileWaitingNeverRuns() async throws {
        let (identity, _, coordinator) = try makeUntrustedCoordinator()
        let snapshot = Self.snapshot(root: identity.root)
        let probe = SynchronizationProbe()
        let isStillNeeded = MutableFlag(true)
        let events = EventLog()

        let blocking = Task { @MainActor in
            await coordinator.synchronizeCoalescing(
                url: snapshot.url,
                profileIdentifier: "swift",
                version: 1
            ) {
                probe.operationDidStart()
                await probe.waitForRelease()
                return .opened
            }
        }
        await probe.waitUntilStarted()

        let waiting = Task { @MainActor in
            await coordinator.synchronizeCoalescing(
                url: snapshot.url,
                profileIdentifier: "swift",
                version: 2,
                shouldStart: { isStillNeeded.value }
            ) {
                events.append("second.ran")
                return .changed
            }
        }
        for _ in 0..<50 {
            await Task.yield()
        }
        isStillNeeded.value = false
        probe.release()

        _ = await blocking.value
        let result = await waiting.value

        XCTAssertNil(result, "A vanished pane must not issue a didOpen/didChange")
        XCTAssertTrue(events.entries.isEmpty)
    }

    private static func snapshot(root: URL) -> SourceSnapshot {
        SourceSnapshot(
            text: "let value = 1\n",
            url: root.appendingPathComponent("Shared.swift"),
            version: 1
        )
    }

    /// An untrusted workspace registers documents exactly as a trusted one
    /// does but never launches a server process, which keeps these
    /// lifecycle tests fully deterministic and headless.
    private func makeUntrustedCoordinator() throws -> (
        WorkspaceIdentity,
        WorkspaceTrustStore,
        MultiLanguageServicesCoordinator
    ) {
        let (identity, store, coordinator, _) = try makeUntrustedCoordinatorWithStore()
        return (identity, store, coordinator)
    }

    private func makeUntrustedCoordinatorWithStore() throws -> (
        WorkspaceIdentity,
        WorkspaceTrustStore,
        MultiLanguageServicesCoordinator,
        WorkspaceDiagnosticsStore
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let identity = try WorkspaceIdentity(root: root)
        let trustStore = WorkspaceTrustStore(
            repository: makeRepository()
        )
        let diagnosticsStore = WorkspaceDiagnosticsStore()
        let coordinator = MultiLanguageServicesCoordinator(
            identity: identity,
            trustStore: trustStore,
            profileRegistry: try makeRegistry(),
            overrideStore: try KodAppTestEnvironment.makeOverrideStore(in: self),
            diagnosticsLog: BoundedEventLog(),
            diagnosticsStore: diagnosticsStore
        )
        // The production 250 ms grace period is left in place; tests that
        // care about close timing install `CloseSchedulerSpy` and fire the
        // captured schedule explicitly instead of sleeping.
        return (identity, trustStore, coordinator, diagnosticsStore)
    }
}

/// Deterministic stand-in for the grace-period timer behind
/// `MultiLanguageServicesCoordinator.scheduleDocumentClose`: captures every
/// scheduled close so a test can fire it, drop it, or observe that it was
/// cancelled — no test ever sleeps waiting for a real timer.
@MainActor
private final class CloseSchedulerSpy {
    private(set) var scheduledDelays: [Duration] = []
    private(set) var cancelCount = 0
    private var pendingFires: [@MainActor () -> Void] = []

    init(installedOn coordinator: MultiLanguageServicesCoordinator) {
        coordinator.scheduleDocumentClose = { [weak self] delay, fire in
            self?.scheduledDelays.append(delay)
            self?.pendingFires.append(fire)
            return LanguageDocumentCloseSchedule {
                self?.cancelCount += 1
            }
        }
    }

    /// Fires every schedule captured so far, including ones the coordinator
    /// has since cancelled — that is exactly the stale-fire case a close
    /// must be inert for.
    func fireAll() {
        let fires = pendingFires
        pendingFires.removeAll()
        for fire in fires {
            fire()
        }
    }
}

/// Coordination seam for the synchronization-coalescing test: lets the test
/// observe when a synchronization operation has actually started and hold it
/// there until released, with continuations rather than sleeps.
@MainActor
private final class SynchronizationProbe {
    private(set) var operationCount = 0
    private var hasStarted = false
    private var isReleased = false
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func operationDidStart() {
        operationCount += 1
        hasStarted = true
        let waiting = startedContinuations
        startedContinuations.removeAll()
        waiting.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        guard !hasStarted else {
            return
        }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }

    func waitForRelease() async {
        guard !isReleased else {
            return
        }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waiting = releaseContinuations
        releaseContinuations.removeAll()
        waiting.forEach { $0.resume() }
    }
}

/// Ordered, main-actor-confined event recorder for the interleaving tests,
/// so a `@Sendable` operation closure can record without capturing a
/// mutable local.
@MainActor
private final class EventLog {
    private(set) var entries: [String] = []

    func append(_ entry: String) {
        entries.append(entry)
    }
}

/// Main-actor-confined mutable flag, used to make a caller's
/// `shouldStart` answer change while it waits.
@MainActor
private final class MutableFlag {
    var value: Bool

    init(_ value: Bool) {
        self.value = value
    }
}
