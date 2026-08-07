import AppKit
import XCTest
@testable import Kod

/// Headless coverage for `GitBlamePanelController`'s Reduce Motion
/// wiring (SPEC 14): the commit-metadata popover's default open/close
/// animation must be disabled when the system's Reduce Motion setting is
/// on. This never reads the live system setting or shows a real
/// popover/window — it only asserts the pure decision function used at
/// the real call site in `presentPopover(for:)`.
@MainActor
final class GitBlamePanelControllerTests: XCTestCase {
    func testAnimatesWhenReduceMotionIsOff() {
        XCTAssertTrue(GitBlamePanelController.shouldAnimatePopover(reduceMotionEnabled: false))
    }

    func testDoesNotAnimateWhenReduceMotionIsOn() {
        XCTAssertFalse(GitBlamePanelController.shouldAnimatePopover(reduceMotionEnabled: true))
    }
}
