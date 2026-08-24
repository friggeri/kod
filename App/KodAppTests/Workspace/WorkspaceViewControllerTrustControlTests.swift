import AppKit
import DiagnosticsCore
import LanguageAdapters
import SettingsCore
import SourceModel
import WorkspaceCore
import XCTest
@testable import Kod

/// Headless coverage for `WorkspaceViewController`'s one-time trust
/// banner and persistent status-bar trust control (SPEC 13.1). Trust
/// changes must update the visible status immediately, and revocation
/// must stop any running language-service coordinators.
@MainActor
final class WorkspaceViewControllerTrustControlTests: XCTestCase {
    private func makeRepository() -> CodableSettingsRepository {
        CodableSettingsRepository(
            store: InMemorySettingsKeyValueStore()
        )
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

    private func makeFixture(
        languageSupportService: LanguageSupportService? = nil
    ) throws -> (
        controller: WorkspaceViewController,
        trustStore: WorkspaceTrustStore,
        log: BoundedEventLog,
        repository: CodableSettingsRepository
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceViewControllerTrustControlTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let repository = CodableSettingsRepository(
            store: InMemorySettingsKeyValueStore()
        )

        let identity = try WorkspaceIdentity(root: root)
        let log = BoundedEventLog()
        let appEnvironment = try AppEnvironment.testing(
            settingsRepository: repository,
            diagnosticsLog: log,
            languageSupportService: languageSupportService
        )
        let dependencies = appEnvironment.makeWorkspaceDependencies()
        let trustStore = dependencies.trustStore
        let controller = WorkspaceViewController(
            identity: identity,
            dependencies: dependencies
        )
        _ = controller.view // triggers loadView(), building workspace controls.
        return (controller, trustStore, log, repository)
    }

    private func waitForPromptUpdate() async throws {
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testRevokeTrustCallsTrustStoreRevokeAndUpdatesTrustState() throws {
        let (controller, trustStore, _, _) = try makeFixture()
        try trustStore.trust(controller.identity)
        XCTAssertTrue(trustStore.isTrusted(controller.identity))

        controller.revokeTrust(nil)

        XCTAssertFalse(trustStore.isTrusted(controller.identity), "revokeTrust(_:) must call trustStore.revoke and be immediately reflected")
    }

    func testWorkspaceDoesNotInstallATrustBanner() throws {
        let (controller, _, _, _) = try makeFixture()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 720, height: 480))
        window.layoutIfNeeded()

        XCTAssertNil(
            findView(identifier: "workspace.trustBanner", in: controller.view)
        )
        XCTAssertGreaterThan(controller.splitContainer.view.frame.height, 350)
    }

    func testSidebarDoesNotOwnWindowTitle() throws {
        let (controller, _, _, _) = try makeFixture()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.layoutIfNeeded()

        let sidebar = try XCTUnwrap(
            findView(identifier: "workspace.sidebar", in: controller.view)
        )

        XCTAssertNil(findView(identifier: "workspace.directoryName", in: sidebar))
    }

    func testSidebarLetsSplitViewItemProvideTheSystemMaterial() throws {
        let (controller, _, _, _) = try makeFixture()
        let splitController = try XCTUnwrap(
            controller.children.compactMap { $0 as? NSSplitViewController }.first
        )
        let sidebarItem = try XCTUnwrap(splitController.splitViewItems.first)
        let sidebar = try XCTUnwrap(
            findView(identifier: "workspace.sidebar", in: controller.view)
        )

        XCTAssertEqual(sidebarItem.behavior, .sidebar)
        XCTAssertFalse(sidebar is NSVisualEffectView)
    }

    func testActivityBarIsOrderedAboveExplorerAndUsesReadableFont() throws {
        let (controller, _, _, _) = try makeFixture()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.layoutIfNeeded()
        let activityBar = try XCTUnwrap(
            findView(identifier: "workspace.activityBar", in: controller.view)
                as? WorkspaceActivityBarView
        )
        XCTAssertEqual(
            WorkspaceActivityBarView.orderedSurfaces,
            [.explorer, .search, .sourceControl, .problems]
        )
        XCTAssertEqual(activityBar.frame.height, 40, accuracy: 0.5)

        controller.showSourceControl(nil)
        XCTAssertEqual(activityBar.selectedSurface, .sourceControl)
        controller.searchWorkspace(nil)
        XCTAssertEqual(activityBar.selectedSurface, .search)
        controller.showProblems(nil)
        XCTAssertEqual(activityBar.selectedSurface, .problems)

        let sidebar = try XCTUnwrap(
            findView(identifier: "workspace.sidebar", in: controller.view)
        )
        let sidebarContent = try XCTUnwrap(
            findView(identifier: "workspace.sidebarContent", in: controller.view)
        )
        XCTAssertEqual(
            activityBar.frame.minY,
            sidebarContent.frame.maxY,
            accuracy: 1
        )
        XCTAssertFalse(
            sidebar.subviews.contains { $0 is NSBox },
            "the activity bar should flow directly into sidebar content"
        )

        let outline = try XCTUnwrap(
            findView(identifier: "workspace.explorer", in: controller.view) as? NSOutlineView
        )
        XCTAssertEqual(outline.rowSizeStyle, .medium)
        controller.entriesByParent[""] = [
            WorkspaceFileEntry(
                url: controller.identity.root.appendingPathComponent("Example.swift"),
                relativePath: "Example.swift",
                kind: .file,
                isHidden: false,
                isIgnored: false
            )
        ]
        let item = controller.explorer.outlineView(outline, child: 0, ofItem: nil)
        let cell = try XCTUnwrap(
            controller.explorer.outlineView(
                outline,
                viewFor: outline.outlineTableColumn,
                item: item
            ) as? NSTableCellView
        )

        XCTAssertEqual(cell.textField?.font?.pointSize, NSFont.systemFontSize + 3)
    }

    func testStatusBarTrustControlIsTrailingAndReflectsCurrentState() throws {
        let (controller, trustStore, _, _) = try makeFixture()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.layoutIfNeeded()

        let statusBar = try XCTUnwrap(
            findView(identifier: "workspace.statusBar", in: controller.view)
        )
        let trustButton = try XCTUnwrap(
            findView(identifier: "workspace.trustStatus", in: controller.view) as? NSButton
        )

        XCTAssertTrue(trustButton.isDescendant(of: statusBar))
        let trustFrame = trustButton.convert(trustButton.bounds, to: statusBar)
        XCTAssertEqual(trustFrame.maxX, statusBar.bounds.maxX - 6, accuracy: 0.5)
        XCTAssertNotNil(trustButton.image)
        XCTAssertEqual(
            trustButton.action,
            NSSelectorFromString("promptToToggleWorkspaceTrust:")
        )
        XCTAssertEqual(
            trustButton.accessibilityLabel(),
            "Restricted mode: language servers and repository tools are disabled."
        )
        XCTAssertTrue(
            trustButton.toolTip?.contains("Trust this workspace") == true
        )

        controller.trustWorkspace(nil)

        XCTAssertTrue(trustStore.isTrusted(controller.identity))
        XCTAssertEqual(
            trustButton.accessibilityLabel(),
            "This workspace is trusted: language servers and repository tools are enabled."
        )
    }

    func testStatusBarTrustControlRequiresConfirmation() async throws {
        let (controller, trustStore, _, _) = try makeFixture()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.layoutIfNeeded()
        let trustButton = try XCTUnwrap(
            findView(identifier: "workspace.trustStatus", in: controller.view) as? NSButton
        )

        trustButton.performClick(nil)
        let cancelledSheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertFalse(trustStore.isTrusted(controller.identity))
        window.endSheet(cancelledSheet, returnCode: .alertSecondButtonReturn)
        await Task.yield()
        XCTAssertFalse(trustStore.isTrusted(controller.identity))

        trustButton.performClick(nil)
        let confirmedSheet = try XCTUnwrap(window.attachedSheet)
        window.endSheet(confirmedSheet, returnCode: .alertFirstButtonReturn)
        await Task.yield()

        XCTAssertTrue(trustStore.isTrusted(controller.identity))

        trustButton.performClick(nil)
        let revokeSheet = try XCTUnwrap(window.attachedSheet)
        window.endSheet(revokeSheet, returnCode: .alertFirstButtonReturn)
        await Task.yield()

        XCTAssertFalse(trustStore.isTrusted(controller.identity))
    }

    func testRevokeTrustStopsLanguageServiceCoordinatorsWithoutCrashing() throws {
        let (controller, trustStore, _, _) = try makeFixture()
        try trustStore.trust(controller.identity)

        // No document has been opened, so no real language-server
        // process is running yet; this asserts `handleTrustRevoked()`
        // on the profile coordinator is safe to call unconditionally (a
        // no-op when nothing was started) and does not throw/crash,
        // exactly mirroring how `trustWorkspace(_:)` is safe to call
        // regardless of whether anything is currently degraded.
        controller.revokeTrust(nil)
        XCTAssertNil(controller.multiLanguageServicesCoordinator.service(forURL: controller.identity.root.appendingPathComponent("main.ts")))
    }

    func testUnavailableLanguageServerUsesOnlyStatusIconAndOpensMatchingSettings() async throws {
        let repository = makeRepository()
        let overrideStore = LanguageServerOverrideStore(
            repository: repository
        )
        let profileStore = try LanguageProfileStore(
            defaultProfiles: [DefaultLanguageProfiles.shell],
            repository: repository,
            overrideStore: overrideStore
        )
        let service = LanguageSupportService(
            profileStore: profileStore,
            overrideStore: overrideStore,
            discovery: { profile, _ in
                throw LanguageServerDiscoveryError.notFound(
                    languageName: profile.displayName,
                    attemptedSources: []
                )
            }
        )
        let (controller, trustStore, _, _) = try makeFixture(
            languageSupportService: service
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        controller.viewDidAppear()
        controller.trustWorkspace(nil)
        let group = try XCTUnwrap(
            controller.splitContainer.controller(
                for: controller.layoutState.activeGroupID
            )
        )
        let fileURL = controller.identity.root.appendingPathComponent("script.sh")
        group.openTab(
            relativePath: "script.sh",
            pinned: true,
            snapshot: SourceSnapshot(text: "echo ok\n", url: fileURL)
        )
        try await waitForPromptUpdate()

        let languageServerButton = try XCTUnwrap(
            findView(
                identifier: "workspace.languageServerStatus",
                in: controller.view
            ) as? NSButton
        )
        let unknownLanguageBanner = try XCTUnwrap(
            findView(
                identifier: "workspace.unknownLanguageBanner",
                in: controller.view
            )
        )
        let healthBanner = try XCTUnwrap(
            findView(identifier: "workspace.healthBanner", in: controller.view)
        )
        var selectedProfileIdentifier: String?
        controller.onShowLanguageSupportSettings = {
            selectedProfileIdentifier = $0
        }

        XCTAssertTrue(languageServerButton.isEnabled)
        XCTAssertTrue(
            languageServerButton.toolTip?.contains("Shell") == true
        )
        XCTAssertTrue(unknownLanguageBanner.isHidden)
        XCTAssertTrue(healthBanner.isHidden)
        XCTAssertNil(
            findView(
                identifier: "workspace.missingLanguageServerBanner",
                in: controller.view
            )
        )

        languageServerButton.performClick(nil)

        XCTAssertEqual(selectedProfileIdentifier, "shellscript")
        XCTAssertTrue(trustStore.isTrusted(controller.identity))
    }

    func testUnknownExtensionPromptOffersAContextualLanguageRequest() async throws {
        let repository = makeRepository()
        let overrideStore = LanguageServerOverrideStore(
            repository: repository
        )
        let profileStore = try LanguageProfileStore(
            defaultProfiles: [],
            repository: repository,
            overrideStore: overrideStore
        )
        let service = LanguageSupportService(
            profileStore: profileStore,
            overrideStore: overrideStore
        )
        let (controller, trustStore, _, _) = try makeFixture(
            languageSupportService: service
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        controller.viewDidAppear()
        try trustStore.trust(controller.identity)

        let unknownURL = controller.identity.root.appendingPathComponent(
            "example.widget"
        )
        let secondUnknownURL = controller.identity.root.appendingPathComponent(
            "other.widget"
        )
        controller.multiLanguageServicesCoordinator.onUnknownFileType?(
            unknownURL
        )
        controller.multiLanguageServicesCoordinator.onUnknownFileType?(
            secondUnknownURL
        )
        try await waitForPromptUpdate()
        let banner = try XCTUnwrap(
            findView(
                identifier: "workspace.unknownLanguageBanner",
                in: controller.view
            )
        )

        let requestButton = try XCTUnwrap(
            findView(
                identifier: "workspace.unknownLanguage.request",
                in: controller.view
            ) as? NSButton
        )
        XCTAssertEqual(requestButton.title, "Request Language...")

        XCTAssertNil(
            findView(
                identifier: "workspace.missingLanguageServer.findServer",
                in: controller.view
            )
        )
        XCTAssertNil(
            findView(
                identifier: "workspace.missingLanguageServer.openSettings",
                in: controller.view
            )
        )
        XCTAssertFalse(banner.isHidden)
    }

    func testPreviewSourceControlLivesInFixedWindowToolbarSlot() async throws {
        let (controller, _, _, _) = try makeFixture()
        let services = WorkspaceWindowController.Services(
            makeWindow: { contentViewController in
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                    styleMask: [.titled, .closable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                window.contentViewController = contentViewController
                return window
            },
            present: { _ in },
            focus: { _ in },
            activate: {},
            beginSession: { _ in },
            shutdownSession: { _ in }
        )
        let windowController = WorkspaceWindowController(
            identity: controller.identity,
            session: controller.session,
            workspaceViewController: controller,
            services: services
        )
        windowController.showSessionWindow()
        let window = try XCTUnwrap(windowController.window)
        window.layoutIfNeeded()

        let item = try XCTUnwrap(
            window.toolbar?.items.first {
                $0.itemIdentifier.rawValue == "workspace.previewSource"
            }
        )
        let controlView = try XCTUnwrap(item.view)
        let button = try XCTUnwrap(
            findView(
                identifier: "workspace.previewSourceToggle",
                in: controlView
            ) as? NSButton
        )
        let fixedWidth = controlView.frame.width
        XCTAssertEqual(button.alphaValue, 0)
        XCTAssertFalse(button.isAccessibilityElement())
        XCTAssertNil(
            findView(
                identifier: "editorGroup.previewSourceToggle",
                in: controller.splitContainer.view
            )
        )

        let group = try XCTUnwrap(
            controller.splitContainer.controller(for: controller.layoutState.activeGroupID)
        )
        group.openTab(
            relativePath: "README.md",
            pinned: true,
            snapshot: SourceSnapshot(
                text: "# Title",
                url: controller.identity.root.appendingPathComponent("README.md")
            )
        )
        for _ in 0..<200 where group.previewSourceControlState != .showingPreview {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(button.alphaValue, 1)
        XCTAssertTrue(button.isAccessibilityElement())
        XCTAssertEqual(button.accessibilityLabel(), "View Source")
        XCTAssertEqual(controlView.frame.width, fixedWidth, accuracy: 0.5)

        controller.togglePreviewSource(nil)

        XCTAssertEqual(button.accessibilityLabel(), "View Preview")
        XCTAssertEqual(controlView.frame.width, fixedWidth, accuracy: 0.5)
    }

    func testTrustAndRevokeActionsRecordWorkspaceDiagnosticEvents() async throws {
        let (controller, _, log, _) = try makeFixture()

        controller.trustWorkspace(nil)
        controller.revokeTrust(nil)

        // Diagnostic recording happens inside a `Task { await ... }`
        // hop off the calling actor; give it a moment to land, exactly
        // like `WorkspaceViewControllerLiveUpdateTests`'s
        // `awaitFilenameMatches` helper does for its own detached Task.
        var workspaceEvents: [DiagnosticEvent] = []
        for _ in 0..<50 {
            workspaceEvents = await log.redactedSnapshot().filter { $0.subsystem == .workspace }
            if workspaceEvents.count >= 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertGreaterThanOrEqual(workspaceEvents.count, 2, "Both trusting and revoking a workspace should record a .workspace diagnostic event")
        XCTAssertTrue(workspaceEvents.contains { $0.message.contains("trust granted") })
        XCTAssertTrue(workspaceEvents.contains { $0.message.contains("trust revoked") })
    }
}
