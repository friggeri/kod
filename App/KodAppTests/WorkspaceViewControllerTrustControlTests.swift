import AppKit
import DiagnosticsCore
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

    private func makeFixture() throws -> (
        controller: WorkspaceViewController,
        trustStore: WorkspaceTrustStore,
        log: BoundedEventLog,
        defaults: UserDefaults
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceViewControllerTrustControlTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let suiteName = "WorkspaceViewControllerTrustControlTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }

        let identity = try WorkspaceIdentity(root: root)
        let trustStore = WorkspaceTrustStore(defaults: defaults)
        let log = BoundedEventLog()
        let controller = WorkspaceViewController(
            identity: identity,
            trustStore: trustStore,
            layoutStore: WorkspaceLayoutStore(defaults: defaults),
            diagnosticsLog: log
        )
        _ = controller.view // triggers loadView(), building the trust banner etc.
        return (controller, trustStore, log, defaults)
    }

    func testRevokeTrustCallsTrustStoreRevokeAndUpdatesTrustState() throws {
        let (controller, trustStore, _, _) = try makeFixture()
        trustStore.trust(controller.identity)
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

    func testTrustBannerOnlyAppearsWhenWorkspaceIsFirstOpened() throws {
        let (firstController, _, _, defaults) = try makeFixture()
        let firstBanner = try XCTUnwrap(
            findView(identifier: "workspace.trustBanner", in: firstController.view)
        )
        XCTAssertFalse(firstBanner.isHidden)

        let reopenedController = WorkspaceViewController(
            identity: firstController.identity,
            trustStore: WorkspaceTrustStore(defaults: defaults),
            layoutStore: WorkspaceLayoutStore(defaults: defaults)
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
        trustStore.trust(controller.identity)

        // No document has been opened, so no real language-server
        // process is running yet; this asserts `handleTrustRevoked()`
        // on both coordinators is safe to call unconditionally (a
        // no-op when nothing was started) and does not throw/crash,
        // exactly mirroring how `trustWorkspace(_:)` is safe to call
        // regardless of whether anything is currently degraded.
        controller.revokeTrust(nil)
        XCTAssertNil(controller.multiLanguageServicesCoordinator.service(forURL: controller.identity.root.appendingPathComponent("main.ts")))
    }

    func testPreviewSourceControlLivesInFixedWindowToolbarSlot() async throws {
        let (controller, _, _, _) = try makeFixture()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        controller.viewDidAppear()
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
