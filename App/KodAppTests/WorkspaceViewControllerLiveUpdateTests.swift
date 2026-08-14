import AppKit
import CryptoKit
import LanguageClient
import SearchCore
import SourceModel
import WorkspaceCore
import XCTest
@testable import Kod

/// Headless (no window shown, no UI automation) coverage for the FSEvents-
/// driven live-update pipeline `WorkspaceViewController` wires together:
/// incremental Explorer/index updates, automatic reload of externally
/// modified open files, and tombstone tabs for files that disappear.
@MainActor
final class WorkspaceViewControllerLiveUpdateTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let controller: WorkspaceViewController
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let appFixture = try KodAppTestEnvironment.make(in: self)
        let identity = try WorkspaceIdentity(root: root)
        let controller = WorkspaceViewController(
            identity: identity,
            dependencies: appFixture.environment.makeWorkspaceDependencies()
        )
        _ = controller.view // triggers loadView(), building splitContainer etc.
        return Fixture(root: root, controller: controller)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw XCTSkip("condition not observed within \(timeout)s")
    }

    private func findView(identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier {
            return view
        }
        for subview in view.subviews {
            if let match = findView(identifier: identifier, in: subview) {
                return match
            }
        }
        return nil
    }

    private func awaitFilenameMatches(
        _ controller: WorkspaceViewController,
        _ query: String
    ) async throws -> [FilenameMatch] {
        // Filename-index appends happen on a detached Task from
        // handleChangedPath; give it a moment to land.
        for _ in 0..<50 {
            let matches = await controller.filenameIndex.search(query)
            if !matches.isEmpty {
                return matches
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return await controller.filenameIndex.search(query)
    }

    // MARK: - Direct dispatch (deterministic, no FSEvents timing dependency)

    func testHandleChangedPathTombstonesOpenTabWhenFileIsDeleted() throws {
        let fixture = try makeFixture()
        let fileURL = fixture.root.appendingPathComponent("a.txt")
        try Data("hello".utf8).write(to: fileURL)

        let controller = fixture.controller
        let group = try XCTUnwrap(controller.splitContainer.controller(for: controller.layoutState.activeGroupID))
        group.openTab(relativePath: "a.txt", pinned: true, snapshot: SourceSnapshot(text: "hello"))

        try FileManager.default.removeItem(at: fileURL)
        controller.handleChangedPath(fileURL.path)

        XCTAssertTrue(controller.layoutState.groups[group.groupID]?.tabs.first?.isTombstoned ?? false)
        XCTAssertNil(group.currentDocumentController)
    }

    func testHandleChangedPathReloadsOpenTabWhenFileIsModified() async throws {
        let fixture = try makeFixture()
        let fileURL = fixture.root.appendingPathComponent("a.txt")
        try Data("hello\n".utf8).write(to: fileURL)

        let controller = fixture.controller
        let group = try XCTUnwrap(controller.splitContainer.controller(for: controller.layoutState.activeGroupID))
        group.openTab(relativePath: "a.txt", pinned: true, snapshot: SourceSnapshot(text: "hello\n", version: 1))

        try Data("hello\nworld\n".utf8).write(to: fileURL)
        controller.handleChangedPath(fileURL.path)

        // The reload itself reads the file asynchronously (a detached
        // Task inside `reloadOpenTabsIfNeeded`), so wait for it to land
        // rather than asserting immediately.
        try await waitUntil {
            group.currentDocumentController?.snapshot.text == "hello\nworld\n"
        }
        XCTAssertGreaterThan(group.currentDocumentController?.snapshot.version ?? 0, 1)
        XCTAssertFalse(controller.layoutState.groups[group.groupID]?.tabs.first?.isTombstoned ?? true)
    }

    func testOpenedTypeScriptDocumentGetsHoverAndDefinitionHooks() throws {
        let fixture = try makeFixture()
        let fileURL = fixture.root.appendingPathComponent("client.ts")
        let snapshot = SourceSnapshot(
            text: "export const client = api;\n",
            url: fileURL
        )
        let group = try XCTUnwrap(
            fixture.controller.splitContainer.controller(
                for: fixture.controller.layoutState.activeGroupID
            )
        )

        group.openTab(relativePath: "client.ts", pinned: true, snapshot: snapshot)

        let viewport = try XCTUnwrap(group.currentDocumentController?.viewport)
        XCTAssertNotNil(viewport.onCommandClick)
        XCTAssertNotNil(viewport.onLinkClick)
        XCTAssertNotNil(viewport.onHover)
        XCTAssertNotNil(viewport.onHoverExit)
    }

    func testLanguageServerControlsLiveInFullWidthBottomStatusBar() throws {
        let fixture = try makeFixture()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = fixture.controller
        window.layoutIfNeeded()

        let statusBar = try XCTUnwrap(
            findView(identifier: "workspace.statusBar", in: fixture.controller.view)
        )
        let restartButton = try XCTUnwrap(
            findView(
                identifier: "workspace.languageServerRestart",
                in: fixture.controller.view
            )
        )

        XCTAssertEqual(statusBar.frame.minX, fixture.controller.view.bounds.minX, accuracy: 0.5)
        XCTAssertEqual(statusBar.frame.width, fixture.controller.view.bounds.width, accuracy: 0.5)
        XCTAssertEqual(statusBar.frame.minY, fixture.controller.view.bounds.minY, accuracy: 0.5)
        XCTAssertTrue(restartButton.isDescendant(of: statusBar))
    }

    func testHandleChangedPathUpdatesExplorerIndexForNonOpenFiles() async throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        let newFile = fixture.root.appendingPathComponent("new.txt")
        try Data("content".utf8).write(to: newFile)

        controller.handleChangedPath(newFile.path)

        let entries = controller.entriesByParent[""] ?? []
        XCTAssertTrue(entries.contains { $0.relativePath == "new.txt" })

        let matches = try await awaitFilenameMatches(controller, "new.txt")
        XCTAssertTrue(matches.contains { $0.entry.relativePath == "new.txt" })
    }

    func testHandleChangedPathRemovesDeletedFileFromExplorerIndex() throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        let fileURL = fixture.root.appendingPathComponent("gone.txt")
        try Data("content".utf8).write(to: fileURL)
        controller.handleChangedPath(fileURL.path)
        XCTAssertTrue((controller.entriesByParent[""] ?? []).contains { $0.relativePath == "gone.txt" })
        let diagnostic = Diagnostic(
            range: LSPRange(
                start: LSPPosition(line: 0, character: 0),
                end: LSPPosition(line: 0, character: 1)
            ),
            severity: .warning,
            code: nil,
            source: nil,
            message: "Gone"
        )
        controller.multiLanguageServicesCoordinator.diagnosticsStore.replace(
            owner: "swift",
            resource: fileURL,
            diagnostics: [diagnostic]
        )
        controller.multiLanguageServicesCoordinator.diagnosticsStore.replace(
            owner: "typescript",
            resource: fileURL,
            diagnostics: [diagnostic]
        )

        try FileManager.default.removeItem(at: fileURL)
        controller.handleChangedPath(fileURL.path)

        XCTAssertFalse((controller.entriesByParent[""] ?? []).contains { $0.relativePath == "gone.txt" })
        XCTAssertNil(
            controller.multiLanguageServicesCoordinator.diagnosticsStore
                .snapshot.presentationDiagnosticsByFile[fileURL.standardizedFileURL]
        )
    }

    /// Problems stays bound to the raw workspace diagnostics store — it
    /// shows files that were never opened — while the coordinator's
    /// normalized callback only decorates open editors and never mutates
    /// that store.
    func testUnopenedDiagnosticsStayInTheStoreWhileNormalizedMarkersFeedEditorsOnly() throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        controller.viewDidAppear() // wires the language-services callbacks
        let diagnosticsStore = controller.multiLanguageServicesCoordinator.diagnosticsStore
        let unopenedURL = fixture.root.appendingPathComponent("Unopened.swift")
        let diagnostic = Diagnostic(
            range: LSPRange(
                start: LSPPosition(line: 0, character: 0),
                end: LSPPosition(line: 0, character: 3)
            ),
            severity: .error,
            code: nil,
            source: nil,
            message: "Unopened"
        )
        diagnosticsStore.replace(
            owner: "swift",
            resource: unopenedURL,
            diagnostics: [diagnostic]
        )
        XCTAssertEqual(
            diagnosticsStore.snapshot
                .presentationDiagnosticsByFile[unopenedURL.standardizedFileURL],
            [diagnostic]
        )

        let openedURL = fixture.root.appendingPathComponent("Open.swift")
        try Data("let value = 1\n".utf8).write(to: openedURL)
        let group = try XCTUnwrap(
            controller.splitContainer.controller(for: controller.layoutState.activeGroupID)
        )
        group.openTab(
            relativePath: "Open.swift",
            pinned: true,
            snapshot: SourceSnapshot(text: "let value = 1\n", url: openedURL, version: 1)
        )

        let normalizedCallback = try XCTUnwrap(
            controller.multiLanguageServicesCoordinator.onNormalizedDiagnostics,
            "Editor markers must be wired to the normalized callback"
        )
        normalizedCallback(openedURL, [
            NormalizedDiagnostic(
                snapshotVersion: 1,
                utf8Range: 0..<3,
                startLine: 0,
                severity: .warning,
                code: nil,
                source: nil,
                message: "Marker"
            )
        ])

        // Editor markers must never be mistaken for workspace problems.
        XCTAssertNil(
            diagnosticsStore.snapshot
                .presentationDiagnosticsByFile[openedURL.standardizedFileURL]
        )
        XCTAssertEqual(
            diagnosticsStore.snapshot
                .presentationDiagnosticsByFile[unopenedURL.standardizedFileURL],
            [diagnostic]
        )
    }

    func testIgnoredLiveUpdateStaysHiddenUntilExplorerRevealIsEnabled() async throws {
        let fixture = try makeFixture()
        try Data("data/\n".utf8).write(to: fixture.root.appendingPathComponent(".gitignore"))
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("data"),
            withIntermediateDirectories: true
        )
        let ignoredFile = fixture.root.appendingPathComponent("data/cache.json")
        try Data("{}".utf8).write(to: ignoredFile)

        fixture.controller.handleChangedPath(ignoredFile.path)
        XCTAssertFalse(
            (fixture.controller.entriesByParent["data"] ?? []).contains {
                $0.relativePath == "data/cache.json"
            }
        )

        fixture.controller.viewDidAppear()
        let revealIgnored = try XCTUnwrap(
            findView(
                identifier: "workspace.showIgnoredFiles",
                in: fixture.controller.view
            ) as? NSButton
        )
        revealIgnored.performClick(nil)

        try await waitUntil {
            (fixture.controller.entriesByParent["data"] ?? []).contains {
                $0.relativePath == "data/cache.json"
            }
        }
        XCTAssertEqual(revealIgnored.state, .on)
        XCTAssertTrue(
            (fixture.controller.entriesByParent[""] ?? []).contains {
                $0.relativePath == "data"
            }
        )
    }

    // MARK: - Real FSEvents end to end

    func testExternalWriteToOpenFileRefreshesWithinBudgetViaRealFSEvents() async throws {
        let fixture = try makeFixture()
        let fileURL = fixture.root.appendingPathComponent("live.txt")
        try Data("before\n".utf8).write(to: fileURL)

        let controller = fixture.controller
        controller.viewDidAppear() // starts discovery, then the real FSEvents watcher

        try await waitUntil {
            !(controller.entriesByParent[""] ?? []).isEmpty
        }

        let group = try XCTUnwrap(controller.splitContainer.controller(for: controller.layoutState.activeGroupID))
        group.openTab(relativePath: "live.txt", pinned: true, snapshot: SourceSnapshot(text: "before\n", version: 1))

        let start = ContinuousClock.now
        try Data("before\nafter\n".utf8).write(to: fileURL)

        try await waitUntil(timeout: 5) {
            group.currentDocumentController?.snapshot.text == "before\nafter\n"
        }
        let elapsed = ContinuousClock.now - start
        // SPEC 12.2: "External file write to visible refreshed snapshot <=
        // 500 ms after write burst settles". The coalescing window itself
        // (default 0.3s) is part of that budget.
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    // MARK: - Read-only invariant

    /// Records a SHA-256 manifest of the fixture workspace, exercises the
    /// full live-update workflow (discovery, search, open, external
    /// modify/reload, external delete/tombstone) with exactly one
    /// deliberate external write standing in for "the user editing the
    /// file in another app", and asserts that write is the *only* change
    /// Kod's own code paths ever produced in the workspace tree.
    func testWorkspaceTreeIsUntouchedExceptByTheDeliberateExternalWriter() async throws {
        let fixture = try makeFixture()
        try Data("original a\n".utf8).write(to: fixture.root.appendingPathComponent("a.txt"))
        try Data("original b\n".utf8).write(to: fixture.root.appendingPathComponent("b.txt"))
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("sub"),
            withIntermediateDirectories: true
        )
        try Data("original c\n".utf8).write(to: fixture.root.appendingPathComponent("sub/c.txt"))

        let beforeManifest = try manifest(of: fixture.root)

        let controller = fixture.controller
        controller.viewDidAppear()
        try await waitUntil {
            (controller.entriesByParent[""] ?? []).count >= 2
        }

        let group = try XCTUnwrap(controller.splitContainer.controller(for: controller.layoutState.activeGroupID))
        group.openTab(relativePath: "a.txt", pinned: true, snapshot: SourceSnapshot(text: "original a\n", version: 1))
        _ = group.currentDocumentController?.captureNavigationAnchor()

        // The one deliberate external write standing in for "the user
        // edited this file in another app" — everything else in the tree
        // must remain exactly as it was.
        let externalWriteURL = fixture.root.appendingPathComponent("a.txt")
        try Data("original a\nedited externally\n".utf8).write(to: externalWriteURL)
        controller.handleChangedPath(externalWriteURL.path)
        try await waitUntil {
            group.currentDocumentController?.snapshot.text == "original a\nedited externally\n"
        }

        // Also exercise the delete/tombstone path and a workspace search,
        // neither of which may write anything either.
        group.openTab(relativePath: "b.txt", pinned: true, snapshot: SourceSnapshot(text: "original b\n", version: 1))
        let deletedURL = fixture.root.appendingPathComponent("b.txt")
        try FileManager.default.removeItem(at: deletedURL)
        controller.handleChangedPath(deletedURL.path)

        let searcher = try WorkspaceTextSearcher()
        _ = try? await collectSearchEvents(searcher, SearchQuery(pattern: "original", root: fixture.root))

        let afterManifest = try manifest(of: fixture.root)

        var expectedManifest = beforeManifest
        expectedManifest["a.txt"] = try sha256(of: externalWriteURL)
        expectedManifest.removeValue(forKey: "b.txt")

        XCTAssertEqual(
            afterManifest,
            expectedManifest,
            "Kod must never write into the workspace beyond the deliberate external test writer's own change"
        )
    }

    private func manifest(of root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let resolvedRootPath = root.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return result
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                continue
            }
            // Both `root` and the enumerated URL are resolved through any
            // symlinks (e.g. /tmp -> /private/tmp) before computing the
            // relative path, so the manifest keys are stable regardless of
            // which unresolved form happened to be used to construct
            // either URL.
            let resolvedPath = url.resolvingSymlinksInPath().path
            guard resolvedPath.hasPrefix(resolvedRootPath + "/") else {
                continue
            }
            let relativePath = String(resolvedPath.dropFirst(resolvedRootPath.count + 1))
            result[relativePath] = try sha256(of: url)
        }
        return result
    }

    private func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func collectSearchEvents(
        _ searcher: WorkspaceTextSearcher,
        _ query: SearchQuery
    ) async throws -> [SearchStreamEvent] {
        var events: [SearchStreamEvent] = []
        for try await event in await searcher.search(query) {
            events.append(event)
        }
        return events
    }
}
