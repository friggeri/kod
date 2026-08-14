import AppKit
import WorkspaceCore
import XCTest
@testable import EditorUI

/// Headless split-tree layout capture coverage owned by EditorUI.
@MainActor
final class SplitContainerViewControllerTests: XCTestCase {
    private var windows: [NSWindow] = []

    @discardableResult
    private func host(
        _ controller: NSViewController,
        frame: NSRect = NSRect(x: 120, y: 100, width: 1_100, height: 720)
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 640, height: 420)
        window.contentViewController = controller
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        windows.append(window)
        return window
    }

    func testSplitContainerCapturesEveryNestedDividerRatio() throws {
        let firstID = EditorGroupID()
        let secondID = EditorGroupID()
        let thirdID = EditorGroupID()
        let root = SplitLayoutNode.split(
            orientation: .horizontal,
            ratio: 0.5,
            first: .leaf(firstID),
            second: .split(
                orientation: .vertical,
                ratio: 0.5,
                first: .leaf(secondID),
                second: .leaf(thirdID)
            )
        )
        let controller = SplitContainerViewController(root: root) { id in
            EditorGroupViewController(
                groupID: id,
                state: EditorGroupState(id: id)
            )
        }
        _ = host(controller)

        let rootSplit = try XCTUnwrap(controller.view.subviews.first as? NSSplitView)
        let nestedSplit = try XCTUnwrap(rootSplit.arrangedSubviews[1] as? NSSplitView)
        rootSplit.setPosition(rootSplit.bounds.width * 0.32, ofDividerAt: 0)
        controller.view.layoutSubtreeIfNeeded()
        nestedSplit.setPosition(nestedSplit.bounds.height * 0.68, ofDividerAt: 0)
        controller.view.layoutSubtreeIfNeeded()

        let expectedRootRatio = rootSplit.arrangedSubviews[0].frame.width / rootSplit.bounds.width
        let expectedNestedRatio = nestedSplit.arrangedSubviews[0].frame.height / nestedSplit.bounds.height
        let captured = controller.captureLayout()

        guard case .split(let rootOrientation, let rootRatio, _, let capturedSecond) = captured,
              case .split(let nestedOrientation, let nestedRatio, _, _) = capturedSecond else {
            return XCTFail("Expected the nested split tree to be preserved")
        }
        XCTAssertEqual(rootOrientation, .horizontal)
        XCTAssertEqual(nestedOrientation, .vertical)
        XCTAssertEqual(rootRatio, Double(expectedRootRatio), accuracy: 0.001)
        XCTAssertEqual(nestedRatio, Double(expectedNestedRatio), accuracy: 0.001)
    }
}
