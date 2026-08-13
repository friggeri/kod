import CodeViewport
import LanguageAdapters
import LanguageClient
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
    private func makeTrustedIdentity() throws -> (WorkspaceIdentity, WorkspaceTrustStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let identity = try WorkspaceIdentity(root: root)
        let suiteName = "MultiLanguageServicesCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        let store = WorkspaceTrustStore(defaults: defaults)
        store.trust(identity)
        return (identity, store)
    }

    private func makeRegistry() throws -> LanguageProfileRegistry {
        let suiteName =
            "MultiLanguageServicesCoordinatorTests.Profiles.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(
                forName: suiteName
            )
        }
        return LanguageProfileRegistry(
            store: try LanguageProfileStore(defaults: defaults)
        )
    }

    func testLanguageServerProfilesIncludeSwiftAndFirstWaveLanguages() throws {
        let (identity, store) = try makeTrustedIdentity()
        let coordinator = MultiLanguageServicesCoordinator(
            identity: identity,
            trustStore: store,
            profileRegistry: try makeRegistry()
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
            profileRegistry: try makeRegistry()
        )
        XCTAssertNil(coordinator.service(forURL: URL(fileURLWithPath: "/workspace/main.ts")))
    }

    func testServiceForURLReturnsNilForAnUnrecognizedExtension() throws {
        let (identity, store) = try makeTrustedIdentity()
        let coordinator = MultiLanguageServicesCoordinator(
            identity: identity,
            trustStore: store,
            profileRegistry: try makeRegistry()
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

        store.revoke(identity)
        coordinator.handleTrustRevoked()

        XCTAssertTrue(diagnosticsStore.snapshot.diagnosticsByOwner.isEmpty)
    }

    func testTrustRevocationClearsNormalizedMarkersForTrackedDocuments() throws {
        let (identity, store) = try makeTrustedIdentity()
        store.revoke(identity)
        let coordinator = MultiLanguageServicesCoordinator(
            identity: identity,
            trustStore: store,
            profileRegistry: try makeRegistry()
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
            profileRegistry: try makeRegistry()
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
        let suiteName = "MultiLanguageServicesCoordinatorTests.Untrusted.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        let untrustedStore = WorkspaceTrustStore(defaults: defaults)
        let coordinator = MultiLanguageServicesCoordinator(
            identity: identity,
            trustStore: untrustedStore,
            profileRegistry: try makeRegistry()
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

        untrustedStore.trust(identity)
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
        let defaults = try XCTUnwrap(
            UserDefaults(
                suiteName: "MultiLanguageServicesCoordinatorTests.Shebang.\(UUID().uuidString)"
            )
        )
        let coordinator = MultiLanguageServicesCoordinator(
            identity: identity,
            trustStore: WorkspaceTrustStore(defaults: defaults),
            profileRegistry: try makeRegistry()
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
        let suiteName =
            "MultiLanguageServicesCoordinatorTests.ExecutableAvailable.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(
                forName: suiteName
            )
        }
        let trustStore = WorkspaceTrustStore(defaults: defaults)
        trustStore.trust(identity)
        let overrideStore = LanguageServerOverrideStore(defaults: defaults)
        let profileStore = try LanguageProfileStore(
            defaultProfiles: [],
            defaults: defaults,
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
            overrideStore: overrideStore
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
        overrideStore.setWorkspaceOverride(
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
}
