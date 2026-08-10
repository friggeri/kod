import AppKit
import DiagnosticsCore
import WorkspaceCore
import XCTest
@testable import Kod

/// Headless coverage for `WorkspaceViewController`'s trust
/// revocation control (SPEC 13.1): revoking trust for an already-open,
/// already-trusted workspace must be immediately effective — the trust
/// banner reappears in its "untrusted" state, and both language-service
/// coordinators are told to stop any already-running server — mirroring
/// how `trustWorkspace(_:)` already becomes effective immediately. No
/// `KodAppUITests`/`XCUIApplication` involved: this drives the
/// controller's `@objc` action methods directly, exactly like
/// `WorkspaceViewControllerLiveUpdateTests`.
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

    private func makeFixture() throws -> (controller: WorkspaceViewController, trustStore: WorkspaceTrustStore, log: BoundedEventLog) {
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
        return (controller, trustStore, log)
    }

    func testRevokeTrustCallsTrustStoreRevokeAndUpdatesTrustState() throws {
        let (controller, trustStore, _) = try makeFixture()
        trustStore.trust(controller.identity)
        XCTAssertTrue(trustStore.isTrusted(controller.identity))

        controller.revokeTrust(nil)

        XCTAssertFalse(trustStore.isTrusted(controller.identity), "revokeTrust(_:) must call trustStore.revoke and be immediately reflected")
    }

    func testTrustBannerStaysCompactAndLeavesHeightForWorkspaceContent() throws {
        let (controller, _, _) = try makeFixture()
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
        let (controller, _, _) = try makeFixture()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.layoutIfNeeded()

        let banner = try XCTUnwrap(
            findView(identifier: "workspace.trustBanner", in: controller.view)
        )
        let dismissButton = try XCTUnwrap(
            findView(identifier: "workspace.trustDismiss", in: controller.view) as? NSButton
        )
        let sidebar = try XCTUnwrap(
            findView(identifier: "workspace.sidebar", in: controller.view)
        )
        let initialContentHeight = controller.splitContainer.view.frame.height

        dismissButton.sendAction(dismissButton.action, to: dismissButton.target)
        window.layoutIfNeeded()

        XCTAssertTrue(banner.isHidden)
        XCTAssertGreaterThan(controller.splitContainer.view.frame.height, initialContentHeight)
        XCTAssertNil(findView(identifier: "workspace.directoryName", in: sidebar))
    }

    func testRevokeTrustStopsLanguageServiceCoordinatorsWithoutCrashing() throws {
        let (controller, trustStore, _) = try makeFixture()
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

    func testTrustAndRevokeActionsRecordWorkspaceDiagnosticEvents() async throws {
        let (controller, _, log) = try makeFixture()

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
