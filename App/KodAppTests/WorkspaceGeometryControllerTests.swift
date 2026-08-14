import AppKit
import WorkspaceCore
import XCTest
@testable import Kod

/// Headless coverage for `WorkspaceGeometryController`'s pure geometry
/// policy: constraining a persisted window frame back onto a currently
/// attached screen, choosing what "normal" frame to persist while
/// fullscreen, and clamping a restored sidebar width. None of these
/// require a window, a split view, or the workspace controller.
@MainActor
final class WorkspaceGeometryControllerTests: XCTestCase {
    func testWindowFrameConstraintMovesStaleFrameOntoFallbackScreen() throws {
        let screen = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let restored = try XCTUnwrap(
            WorkspaceGeometryController.constrainedWindowFrame(
                WorkspaceWindowFrame(x: 5_000, y: -300, width: 100, height: 100),
                minimumSize: NSSize(width: 640, height: 420),
                visibleScreenFrames: [screen],
                fallbackVisibleFrame: screen
            )
        )

        XCTAssertEqual(restored, NSRect(x: 800, y: 0, width: 640, height: 420))
    }

    func testWindowFrameConstraintPrefersTheScreenWithTheLargestOverlap() throws {
        let leftScreen = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let rightScreen = NSRect(x: 1_000, y: 0, width: 1_000, height: 800)
        let restored = try XCTUnwrap(
            WorkspaceGeometryController.constrainedWindowFrame(
                WorkspaceWindowFrame(x: 1_200, y: 100, width: 700, height: 500),
                minimumSize: NSSize(width: 640, height: 420),
                visibleScreenFrames: [leftScreen, rightScreen],
                fallbackVisibleFrame: leftScreen
            )
        )

        XCTAssertEqual(restored, NSRect(x: 1_200, y: 100, width: 700, height: 500))
    }

    func testWindowFrameConstraintRejectsNonFiniteOrEmptySavedFrames() {
        let screen = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        XCTAssertNil(
            WorkspaceGeometryController.constrainedWindowFrame(
                WorkspaceWindowFrame(x: .nan, y: 0, width: 800, height: 600),
                minimumSize: NSSize(width: 640, height: 420),
                visibleScreenFrames: [screen],
                fallbackVisibleFrame: screen
            )
        )
        XCTAssertNil(
            WorkspaceGeometryController.constrainedWindowFrame(
                WorkspaceWindowFrame(x: 0, y: 0, width: 0, height: 600),
                minimumSize: NSSize(width: 640, height: 420),
                visibleScreenFrames: [screen],
                fallbackVisibleFrame: screen
            )
        )
    }

    func testWindowFrameConstraintReturnsNilWithoutAnyValidScreen() {
        XCTAssertNil(
            WorkspaceGeometryController.constrainedWindowFrame(
                WorkspaceWindowFrame(x: 0, y: 0, width: 800, height: 600),
                minimumSize: NSSize(width: 640, height: 420),
                visibleScreenFrames: [NSRect(x: 0, y: 0, width: 0, height: 0)],
                fallbackVisibleFrame: nil
            )
        )
    }

    func testFullscreenPersistenceSelectsLastNormalWindowFrame() throws {
        let normalFrame = NSRect(x: 120, y: 100, width: 1_100, height: 720)
        let fullscreenFrame = NSRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let selectedFrame = try XCTUnwrap(
            WorkspaceGeometryController.normalWindowFrame(
                currentFrame: fullscreenFrame,
                isFullScreen: true,
                lastNormalFrame: normalFrame,
                persistedFrame: nil
            )
        )

        XCTAssertEqual(selectedFrame, normalFrame)
    }

    func testFullscreenPersistenceFallsBackToThePersistedFrame() throws {
        let persisted = WorkspaceWindowFrame(x: 40, y: 60, width: 900, height: 700)
        let selectedFrame = try XCTUnwrap(
            WorkspaceGeometryController.normalWindowFrame(
                currentFrame: NSRect(x: 0, y: 0, width: 1_920, height: 1_080),
                isFullScreen: true,
                lastNormalFrame: nil,
                persistedFrame: persisted
            )
        )

        XCTAssertEqual(selectedFrame, NSRect(x: 40, y: 60, width: 900, height: 700))
    }

    func testNonFullscreenPersistenceAlwaysUsesTheCurrentFrame() {
        let current = NSRect(x: 10, y: 20, width: 800, height: 600)
        XCTAssertEqual(
            WorkspaceGeometryController.normalWindowFrame(
                currentFrame: current,
                isFullScreen: false,
                lastNormalFrame: NSRect(x: 0, y: 0, width: 1, height: 1),
                persistedFrame: nil
            ),
            current
        )
    }

    func testSidebarWidthIsClampedIntoTheSupportedRange() {
        XCTAssertEqual(
            WorkspaceGeometryController.clampedSidebarWidth(nil),
            WorkspaceGeometryController.defaultSidebarWidth
        )
        XCTAssertEqual(
            WorkspaceGeometryController.clampedSidebarWidth(.nan),
            WorkspaceGeometryController.defaultSidebarWidth
        )
        XCTAssertEqual(
            WorkspaceGeometryController.clampedSidebarWidth(10),
            WorkspaceGeometryController.minimumSidebarWidth
        )
        XCTAssertEqual(
            WorkspaceGeometryController.clampedSidebarWidth(10_000),
            WorkspaceGeometryController.maximumSidebarWidth
        )
        XCTAssertEqual(WorkspaceGeometryController.clampedSidebarWidth(300), 300)
    }

    func testRestoredSidebarWidthIsClampedAtConstruction() {
        XCTAssertEqual(
            WorkspaceGeometryController(restoredSidebarWidth: 10_000)
                .lastExpandedSidebarWidth,
            WorkspaceGeometryController.maximumSidebarWidth
        )
    }

    /// Without a window there is nothing to capture, and the restore pass
    /// must stay un-consumed so it can still run once one exists.
    func testCaptureAndRestoreAreNoOpsWithoutAWindow() {
        let controller = WorkspaceGeometryController(restoredSidebarWidth: 300)
        XCTAssertNil(controller.captureGeometry(persistedFrame: nil))
        controller.restoreIfNeeded(geometry: nil)
        XCTAssertFalse(controller.hasRestoredGeometry)
    }

    func testCapturedGeometryReportsTheWindowFrameAndSidebarWidth() throws {
        let controller = WorkspaceGeometryController(restoredSidebarWidth: 300)
        let window = NSWindow(
            contentRect: NSRect(x: 30, y: 40, width: 900, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        controller.windowProvider = { window }

        let captured = try XCTUnwrap(controller.captureGeometry(persistedFrame: nil))

        XCTAssertEqual(captured.windowFrame.x, Double(window.frame.origin.x), accuracy: 0.5)
        XCTAssertEqual(captured.windowFrame.width, Double(window.frame.width), accuracy: 0.5)
        XCTAssertEqual(captured.sidebarWidth, 300, accuracy: 0.001)
        // No split view is attached, so the sidebar cannot be collapsed.
        XCTAssertFalse(captured.isSidebarCollapsed)
    }

    /// Entering fullscreen records the frame that must be persisted; the
    /// restore performed while fullscreen is applied on the way out.
    func testFullscreenTransitionsKeepTheNormalFrameForPersistence() throws {
        let controller = WorkspaceGeometryController(restoredSidebarWidth: 240)
        let window = NSWindow(
            contentRect: NSRect(x: 15, y: 25, width: 820, height: 540),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        controller.windowProvider = { window }

        controller.windowWillEnterFullScreen(
            Notification(name: NSWindow.willEnterFullScreenNotification, object: window)
        )
        let captured = try XCTUnwrap(controller.captureGeometry(persistedFrame: nil))

        XCTAssertEqual(captured.windowFrame.width, Double(window.frame.width), accuracy: 0.5)
        XCTAssertEqual(captured.windowFrame.height, Double(window.frame.height), accuracy: 0.5)
    }
}
