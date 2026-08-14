import AppKit
import WorkspaceCore

/// Pure drag/drop arithmetic for the editor tab rail — activation
/// distance, clamping, target-slot resolution and reorder anchors — kept
/// out of `EditorTabBarView` so the rules a drag actually follows can be
/// tested directly, with no view, window or synthesized mouse event.

struct EditorTabDragGeometry {
    static let activationDistance: CGFloat = 3

    static func hasExceededActivationDistance(from start: NSPoint, to current: NSPoint) -> Bool {
        let deltaX = current.x - start.x
        let deltaY = current.y - start.y
        return deltaX * deltaX + deltaY * deltaY >= activationDistance * activationDistance
    }

    static func clampedOriginX(
        _ proposedOriginX: CGFloat,
        itemWidth: CGFloat,
        visibleBounds: NSRect,
        horizontalInset: CGFloat
    ) -> CGFloat {
        let minimum = visibleBounds.minX + horizontalInset
        let maximum = max(minimum, visibleBounds.maxX - horizontalInset - itemWidth)
        return min(max(proposedOriginX, minimum), maximum)
    }

    static func updatedTargetIndex(
        currentTargetIndex: Int,
        draggedCenterX: CGFloat,
        slotCenters: [CGFloat]
    ) -> Int {
        guard slotCenters.indices.contains(currentTargetIndex) else {
            return currentTargetIndex
        }

        var targetIndex = currentTargetIndex
        while targetIndex < slotCenters.count - 1,
              draggedCenterX >= slotCenters[targetIndex + 1] - 0.5 {
            targetIndex += 1
        }
        while targetIndex > 0,
              draggedCenterX <= slotCenters[targetIndex - 1] + 0.5 {
            targetIndex -= 1
        }
        return targetIndex
    }

    static func visualSlot(
        forItemAt itemIndex: Int,
        sourceIndex: Int,
        targetIndex: Int
    ) -> Int {
        if sourceIndex < targetIndex,
           itemIndex > sourceIndex,
           itemIndex <= targetIndex {
            return itemIndex - 1
        }
        if targetIndex < sourceIndex,
           itemIndex >= targetIndex,
           itemIndex < sourceIndex {
            return itemIndex + 1
        }
        return itemIndex
    }
}

struct EditorTabExternalDropGeometry {
    let insertionIndex: Int
    let gapFrameInWindow: NSRect
    let railFrameInWindow: NSRect
}

struct EditorTabDropAnchors {
    let sourceTabID: EditorTabID
    let previousTabID: EditorTabID?
    let nextTabID: EditorTabID?
    let fallbackDestination: Int

    init?(
        tabIDs: [EditorTabID],
        sourceTabID: EditorTabID,
        destination: Int
    ) {
        guard let sourceIndex = tabIDs.firstIndex(of: sourceTabID) else {
            return nil
        }
        var finalOrder = tabIDs
        finalOrder.remove(at: sourceIndex)
        let destination = max(0, min(destination, finalOrder.count))
        finalOrder.insert(sourceTabID, at: destination)

        self.sourceTabID = sourceTabID
        previousTabID = destination > 0 ? finalOrder[destination - 1] : nil
        nextTabID = destination + 1 < finalOrder.count
            ? finalOrder[destination + 1]
            : nil
        fallbackDestination = destination
    }

    func destination(in currentTabIDs: [EditorTabID]) -> Int? {
        guard currentTabIDs.contains(sourceTabID) else {
            return nil
        }
        let remainingTabIDs = currentTabIDs.filter { $0 != sourceTabID }
        if let nextTabID,
           let nextIndex = remainingTabIDs.firstIndex(of: nextTabID) {
            return nextIndex
        }
        if let previousTabID,
           let previousIndex = remainingTabIDs.firstIndex(of: previousTabID) {
            return previousIndex + 1
        }
        return max(0, min(fallbackDestination, remainingTabIDs.count))
    }
}
