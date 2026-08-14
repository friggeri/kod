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
        _ = controller.view // triggers loadView(), building the trust banner etc.
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

    func testTrustBannerStaysCompactAndLeavesHeightForWorkspaceContent() throws {
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

        let banner = try XCTUnwrap(
            findView(identifier: "workspace.trustBanner", in: controller.view) as? NSStackView
        )
        let button = try XCTUnwrap(
            findView(identifier: "workspace.trust", in: controller.view) as? NSButton
        )
        XCTAssertGreaterThan(banner.frame.height, button.frame.height)
        XCTAssertLessThan(banner.frame.height, 50)
        XCTAssertGreaterThan(controller.splitContainer.view.frame.height, 350)
    }

    func testTrustBannerCanBeDismissedAndSidebarDoesNotOwnWindowTitle() throws {
        let (controller, _, _, _) = try makeFixture()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.layoutIfNeeded()

        let banner = try XCTUnwrap(
            findView(identifier: "workspace.trustBanner", in: controller.view) as? NSStackView
        )
        let dismissButton = try XCTUnwrap(
            findView(identifier: "workspace.trustDismiss", in: controller.view) as? NSButton
        )
        let sidebar = try XCTUnwrap(
            findView(identifier: "workspace.sidebar", in: controller.view)
        )
        let initialContentHeight = controller.splitContainer.view.frame.height

        XCTAssertTrue(banner.arrangedSubviews.last === dismissButton)
        XCTAssertEqual(dismissButton.frame.maxX, banner.bounds.maxX - 6, accuracy: 1)

        dismissButton.sendAction(dismissButton.action, to: dismissButton.target)
        window.layoutIfNeeded()

        XCTAssertTrue(banner.isHidden)
        XCTAssertGreaterThan(controller.splitContainer.view.frame.height, initialContentHeight)
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

    func testSidebarOmitsSymbolsAndUsesReadableExplorerFont() throws {
        let (controller, _, _, _) = try makeFixture()
        let modeControl = try XCTUnwrap(
            findView(
                identifier: "workspace.sidebarMode",
                in: controller.view
            ) as? NSSegmentedControl
        )

        XCTAssertEqual(modeControl.segmentCount, 4)
        XCTAssertEqual(
            (0..<modeControl.segmentCount).compactMap { modeControl.label(forSegment: $0) },
            ["Explorer", "Search", "Problems", "Source Control"]
        )

        controller.showSourceControl(nil)
        XCTAssertEqual(modeControl.selectedSegment, 3)

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

    func testTrustBannerOnlyAppearsWhenWorkspaceIsFirstOpened() throws {
        let (firstController, _, _, repository) = try makeFixture()
        let firstBanner = try XCTUnwrap(
            findView(identifier: "workspace.trustBanner", in: firstController.view)
        )
        XCTAssertFalse(firstBanner.isHidden)

        let reopenedController = WorkspaceViewController(
            identity: firstController.identity,
            dependencies: try AppEnvironment.testing(
                settingsRepository: repository
            ).makeWorkspaceDependencies()
        )
        _ = reopenedController.view
        let reopenedBanner = try XCTUnwrap(
            findView(identifier: "workspace.trustBanner", in: reopenedController.view)
        )

        XCTAssertTrue(reopenedBanner.isHidden)
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
        XCTAssertEqual(trustButton.frame.maxX, statusBar.bounds.maxX - 6, accuracy: 0.5)
        XCTAssertNotNil(trustButton.image)
        XCTAssertEqual(
            trustButton.action,
            NSSelectorFromString("promptToToggleWorkspaceTrust:")
        )
        XCTAssertEqual(
            trustButton.accessibilityLabel(),
            "Restricted mode: language servers and repository tools are disabled."
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

    func testMissingServerPromptIsTrustGatedAndNotNowSuppressesItForTheSession() async throws {
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
        let banner = try XCTUnwrap(
            findView(
                identifier: "workspace.missingLanguageServerBanner",
                in: controller.view
            )
        )

        controller.multiLanguageServicesCoordinator.onMissingServer?(
            DefaultLanguageProfiles.shell
        )
        try await waitForPromptUpdate()
        XCTAssertTrue(banner.isHidden)

        try trustStore.trust(controller.identity)
        controller.multiLanguageServicesCoordinator.onMissingServer?(
            DefaultLanguageProfiles.shell
        )
        try await waitForPromptUpdate()
        XCTAssertFalse(banner.isHidden)

        service.beginEditingProfile(identifier: "shellscript")
        var unresolvedDraft = try XCTUnwrap(service.requestedProfileDraft)
        unresolvedDraft.displayName = "Shell Scripts"
        _ = try service.save(draft: unresolvedDraft)
        try await waitForPromptUpdate()
        XCTAssertFalse(
            banner.isHidden,
            "Editing a profile without resolving its missing server must keep the prompt visible"
        )

        let findServerButton = try XCTUnwrap(
            findView(
                identifier: "workspace.missingLanguageServer.findServer",
                in: controller.view
            ) as? NSButton
        )
        XCTAssertTrue(findServerButton.isEnabled)

        let notNowButton = try XCTUnwrap(
            findView(
                identifier: "workspace.missingLanguageServer.notNow",
                in: controller.view
            ) as? NSButton
        )
        notNowButton.performClick(nil)
        XCTAssertTrue(banner.isHidden)

        controller.multiLanguageServicesCoordinator.onMissingServer?(
            DefaultLanguageProfiles.shell
        )
        try await waitForPromptUpdate()
        XCTAssertTrue(banner.isHidden)
    }

    /// SPEC (implement-language-ui-refresh): after an external install and
    /// clicking Refresh, discovering a previously-missing executable must
    /// hide the currently displayed matching banner on its own — no
    /// profile edit or manual executable selection required.
    func testExecutableDiscoveryHidesTheMatchingBannerWithoutProfileEditOrManualSelection() async throws {
        let repository = makeRepository()
        let overrideStore = LanguageServerOverrideStore(
            repository: repository
        )
        let profileStore = try LanguageProfileStore(
            defaultProfiles: [DefaultLanguageProfiles.shell],
            repository: repository,
            overrideStore: overrideStore
        )
        let shouldSucceed = DiscoveryGate(false)
        let service = LanguageSupportService(
            profileStore: profileStore,
            overrideStore: overrideStore,
            discovery: { profile, _ in
                guard shouldSucceed.get() else {
                    throw LanguageServerDiscoveryError.notFound(
                        languageName: profile.displayName,
                        attemptedSources: []
                    )
                }
                return DiscoveredExecutable(
                    url: URL(fileURLWithPath: "/usr/local/bin/shellscript-lsp"),
                    arguments: [],
                    version: "1.0.0",
                    source: .loginShellPath
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
        try trustStore.trust(controller.identity)

        let banner = try XCTUnwrap(
            findView(
                identifier: "workspace.missingLanguageServerBanner",
                in: controller.view
            ) as? NSStackView
        )

        // Show the shellscript missing-server banner.
        controller.multiLanguageServicesCoordinator.onMissingServer?(
            DefaultLanguageProfiles.shell
        )
        try await waitForPromptUpdate()
        XCTAssertFalse(banner.isHidden)

        // Simulate an external install + Settings Refresh: discovery now
        // succeeds for shellscript. Nothing else is queued, so nothing
        // else contends for the banner afterward.
        shouldSucceed.set(true)
        await service.refresh()
        try await waitForPromptUpdate()

        // The matching banner must hide without any profile edit or
        // manual executable selection.
        XCTAssertTrue(
            banner.isHidden,
            "Discovering the executable must hide the matching banner on its own"
        )
    }

    /// SPEC (implement-language-ui-refresh): a discovery notification for
    /// one profile must leave a *different*, currently displayed
    /// missing-server prompt alone — only clearing that profile's own
    /// stale queue entry so it doesn't awkwardly resurface later.
    func testExecutableDiscoveryForOneProfileLeavesADifferentActivePromptUntouched() async throws {
        let repository = makeRepository()
        let overrideStore = LanguageServerOverrideStore(
            repository: repository
        )
        let profileStore = try LanguageProfileStore(
            defaultProfiles: [
                DefaultLanguageProfiles.shell,
                DefaultLanguageProfiles.markdown
            ],
            repository: repository,
            overrideStore: overrideStore
        )
        let shellShouldSucceed = DiscoveryGate(false)
        let service = LanguageSupportService(
            profileStore: profileStore,
            overrideStore: overrideStore,
            discovery: { profile, _ in
                guard profile.identifier == "shellscript",
                      shellShouldSucceed.get() else {
                    throw LanguageServerDiscoveryError.notFound(
                        languageName: profile.displayName,
                        attemptedSources: []
                    )
                }
                return DiscoveredExecutable(
                    url: URL(fileURLWithPath: "/usr/local/bin/shellscript-lsp"),
                    arguments: [],
                    version: "1.0.0",
                    source: .loginShellPath
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
        try trustStore.trust(controller.identity)

        let banner = try XCTUnwrap(
            findView(
                identifier: "workspace.missingLanguageServerBanner",
                in: controller.view
            ) as? NSStackView
        )
        let bannerLabel = try XCTUnwrap(
            banner.arrangedSubviews.compactMap { $0 as? NSTextField }.first
        )

        // Markdown's missing-server prompt is currently displayed (this
        // is the "unrelated ... prompt currently on screen").
        controller.multiLanguageServicesCoordinator.onMissingServer?(
            DefaultLanguageProfiles.markdown
        )
        try await waitForPromptUpdate()
        XCTAssertFalse(banner.isHidden)
        XCTAssertTrue(
            bannerLabel.stringValue.localizedCaseInsensitiveContains("markdown")
        )

        // Shellscript's own missing-server signal arrives behind it,
        // while a different profile's prompt is showing, so it is only
        // queued rather than displayed immediately.
        controller.multiLanguageServicesCoordinator.onMissingServer?(
            DefaultLanguageProfiles.shell
        )
        try await waitForPromptUpdate()
        XCTAssertFalse(banner.isHidden)
        XCTAssertTrue(
            bannerLabel.stringValue.localizedCaseInsensitiveContains("markdown"),
            "Queuing shellscript's missing-server signal must not replace the currently displayed unrelated (Markdown) banner"
        )

        // Simulate an external install + Settings Refresh: discovery now
        // succeeds for shellscript only. Markdown remains unresolved.
        shellShouldSucceed.set(true)
        await service.refresh()
        try await waitForPromptUpdate()

        // The Markdown prompt currently on screen must be left alone —
        // discovering a *different* profile's executable must not hide
        // or otherwise disturb it.
        XCTAssertFalse(
            banner.isHidden,
            "An unrelated prompt currently on screen must not be hidden by a different profile's discovery event"
        )
        XCTAssertTrue(
            bannerLabel.stringValue.localizedCaseInsensitiveContains("markdown"),
            "The unrelated prompt currently on screen must remain the one shown, untouched by shellscript's discovery"
        )

        // Dismiss Markdown's prompt; shellscript's stale queue entry
        // must have been cleared by the discovery handling, so it must
        // not resurface even though it was still technically "missing"
        // when originally queued.
        let notNowButton = try XCTUnwrap(
            findView(
                identifier: "workspace.missingLanguageServer.notNow",
                in: controller.view
            ) as? NSButton
        )
        notNowButton.performClick(nil)
        try await waitForPromptUpdate()
        XCTAssertTrue(
            banner.isHidden,
            "No prompt should resurface: Markdown was dismissed and shellscript's stale queue entry was already cleared by discovery"
        )
    }

    func testMissingServerBannerOffersInstallationHelpForAKnownDefaultProfile() async throws {
        let repository = makeRepository()
        let overrideStore = LanguageServerOverrideStore(
            repository: repository
        )
        let profileStore = try LanguageProfileStore(
            defaultProfiles: [DefaultLanguageProfiles.markdown],
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
        try trustStore.trust(controller.identity)

        controller.multiLanguageServicesCoordinator.onMissingServer?(
            DefaultLanguageProfiles.markdown
        )
        try await waitForPromptUpdate()

        let banner = try XCTUnwrap(
            findView(
                identifier: "workspace.missingLanguageServerBanner",
                in: controller.view
            )
        )
        XCTAssertFalse(banner.isHidden)

        // Markdown is a known default profile with shipped installation
        // guidance (`DefaultLanguageServerInstallationGuides`), so the
        // banner's find action must switch to "Installation Help..." and
        // point at Marksman's own documentation rather than the generic
        // public LSP directory.
        let findServerButton = try XCTUnwrap(
            findView(
                identifier: "workspace.missingLanguageServer.findServer",
                in: controller.view
            ) as? NSButton
        )
        XCTAssertEqual(findServerButton.title, "Installation Help...")
        let tooltip = try XCTUnwrap(findServerButton.toolTip)
        XCTAssertTrue(tooltip.contains("Markdown"))
    }

    func testMissingServerBannerFallsBackToTheDirectoryForACustomProfile() async throws {
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
            overrideStore: overrideStore,
            discovery: { profile, _ in
                throw LanguageServerDiscoveryError.notFound(
                    languageName: profile.displayName,
                    attemptedSources: []
                )
            }
        )
        var customProfile = LanguageProfile(
            identifier: "custom-widget",
            displayName: "Widget",
            origin: .custom,
            defaultRevision: 1,
            associations: [
                LanguageFileAssociation(
                    identifier: "files",
                    fileExtensions: ["widget"],
                    syntax: .plainText
                )
            ],
            languageServer: LanguageServerConfiguration(
                defaultLanguageID: "widget",
                executableCandidates: [
                    LanguageServerExecutableCandidate(
                        identifier: "widget-lsp",
                        executableNames: ["widget-lsp"],
                        arguments: []
                    )
                ]
            )
        )
        customProfile = try profileStore.createCustomProfile(customProfile)

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

        controller.multiLanguageServicesCoordinator.onMissingServer?(
            customProfile
        )
        try await waitForPromptUpdate()

        let banner = try XCTUnwrap(
            findView(
                identifier: "workspace.missingLanguageServerBanner",
                in: controller.view
            )
        )
        XCTAssertFalse(banner.isHidden)

        // A custom profile can never resolve shipped installation
        // guidance (even if it reused a default-sounding identifier), so
        // the banner keeps the generic public LSP directory fallback.
        let findServerButton = try XCTUnwrap(
            findView(
                identifier: "workspace.missingLanguageServer.findServer",
                in: controller.view
            ) as? NSButton
        )
        XCTAssertEqual(findServerButton.title, "Find a Server...")
    }

    func testRevokingTrustDuringServerDiscoveryDoesNotShowAStalePrompt() async throws {
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
                Thread.sleep(forTimeInterval: 0.15)
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
        try trustStore.trust(controller.identity)
        controller.multiLanguageServicesCoordinator.onMissingServer?(
            DefaultLanguageProfiles.shell
        )

        try await Task.sleep(for: .milliseconds(30))
        controller.revokeTrust(nil)
        try await Task.sleep(for: .milliseconds(250))

        let banner = try XCTUnwrap(
            findView(
                identifier: "workspace.missingLanguageServerBanner",
                in: controller.view
            )
        )
        XCTAssertTrue(banner.isHidden)
    }

    func testUnknownExtensionPromptCreatesAPrefilledCustomProfile() async throws {
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
                identifier: "workspace.missingLanguageServerBanner",
                in: controller.view
            )
        )

        let chooseButton = try XCTUnwrap(
            findView(
                identifier: "workspace.missingLanguageServer.chooseExisting",
                in: controller.view
            ) as? NSButton
        )
        XCTAssertEqual(chooseButton.title, "Add Profile...")

        // An unknown file extension has no profile at all (default or
        // custom), so it must always keep the generic public LSP
        // directory fallback rather than "Installation Help...".
        let findServerButton = try XCTUnwrap(
            findView(
                identifier: "workspace.missingLanguageServer.findServer",
                in: controller.view
            ) as? NSButton
        )
        XCTAssertEqual(findServerButton.title, "Find a Server...")

        chooseButton.performClick(nil)

        let draft = try XCTUnwrap(service.requestedProfileDraft)
        XCTAssertEqual(draft.displayName, "WIDGET")
        XCTAssertEqual(draft.associations.count, 1)
        XCTAssertEqual(draft.associations[0].fileExtensions, "widget")
        XCTAssertNil(draft.associations[0].syntaxLanguage)
        XCTAssertFalse(draft.languageServerEnabled)
        XCTAssertFalse(
            banner.isHidden,
            "Opening Settings must not dismiss an unresolved prompt"
        )

        _ = try service.save(draft: draft)
        try await waitForPromptUpdate()
        XCTAssertTrue(
            banner.isHidden,
            "Saving a matching profile resolves the unknown-file prompt"
        )
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

/// Thread-safe boolean gate for toggling an injected discovery closure's
/// behavior mid-test (e.g. simulating an external install becoming
/// available between two `refresh()` calls).
private final class DiscoveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ initial: Bool) {
        self.value = initial
    }

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
