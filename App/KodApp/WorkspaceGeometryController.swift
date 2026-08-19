import AppKit
import WorkspaceCore

/// Owns everything about a workspace window's *geometry*: validating and
/// clamping a persisted frame back onto a currently attached screen,
/// capturing/restoring the sidebar's expanded width, and the
/// fullscreen "last normal frame" bookkeeping that decides what gets
/// persisted while the window is fullscreen.
///
/// The window controller drives the window-level events (fullscreen
/// transitions, first presentation); the workspace view controller owns
/// the split view this reads and writes, and hands it over once its view
/// hierarchy is loaded. Nothing here knows about Explorer, Git, trust or
/// language services — it is pure window/split geometry.
@MainActor
final class WorkspaceGeometryController {
    static let defaultSidebarWidth: CGFloat = 240
    static let minimumSidebarWidth: CGFloat = 180
    static let maximumSidebarWidth: CGFloat = 420

    /// Resolves the window this geometry belongs to. Kept as a closure so
    /// the controller never retains a window and always observes the
    /// *current* one (a view controller can be re-hosted).
    var windowProvider: () -> NSWindow? = { nil }
    private weak var splitViewController: NSSplitViewController?

    private(set) var hasRestoredGeometry = false
    private(set) var lastExpandedSidebarWidth: CGFloat
    private var lastNormalWindowFrame: NSRect?
    private var pendingNormalWindowFrame: NSRect?
    private var isApplyingSidebarGeometry = false
    private var pendingExpandedSidebarWidth: CGFloat?

    init(restoredSidebarWidth: Double?) {
        self.lastExpandedSidebarWidth = Self.clampedSidebarWidth(
            restoredSidebarWidth
        )
    }

    /// Hands the outer split view controller over once the workspace's
    /// view hierarchy exists. Held weakly: the view controller owns it.
    func attach(splitViewController: NSSplitViewController) {
        self.splitViewController = splitViewController
    }

    // MARK: - Sidebar

    func toggleSidebar(_ sender: Any?) {
        guard let splitViewController else {
            return
        }
        let sidebarItem = splitViewController.splitViewItems.first
        let wasCollapsed = sidebarItem?.isCollapsed == true
        let widthToRestore = lastExpandedSidebarWidth
        if !wasCollapsed {
            pendingExpandedSidebarWidth = nil
            isApplyingSidebarGeometry = false
            captureExpandedSidebarWidth()
        }
        if wasCollapsed {
            isApplyingSidebarGeometry = true
            pendingExpandedSidebarWidth = widthToRestore
            prepareSidebarWidth(widthToRestore)
        }
        splitViewController.toggleSidebar(sender)
        if wasCollapsed {
            DispatchQueue.main.async { [weak self] in
                self?.applyPendingExpandedSidebarWidthIfPossible()
            }
        }
    }

    func revealSidebar(_ sender: Any?) {
        guard splitViewController?.splitViewItems.first?.isCollapsed == true else {
            return
        }
        toggleSidebar(sender)
    }

    /// Called for every `NSSplitView.didResizeSubviewsNotification` on the
    /// workspace's outer split view: a resize the *user* performed updates
    /// the remembered expanded width, while one this controller itself is
    /// applying must not feed back into it.
    func splitViewDidResize() {
        guard hasRestoredGeometry else {
            return
        }
        if pendingExpandedSidebarWidth != nil {
            applyPendingExpandedSidebarWidthIfPossible()
            return
        }
        guard !isApplyingSidebarGeometry else {
            return
        }
        captureExpandedSidebarWidth()
    }

    // MARK: - Restore / capture

    func restoreIfNeeded(geometry: WorkspaceGeometryState?) {
        guard !hasRestoredGeometry, let window = windowProvider() else {
            return
        }
        hasRestoredGeometry = true

        guard let geometry else {
            if !window.styleMask.contains(.fullScreen) {
                lastNormalWindowFrame = window.frame
            }
            isApplyingSidebarGeometry = true
            window.layoutIfNeeded()
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self else {
                    return
                }
                guard let window, self.windowProvider() === window else {
                    self.isApplyingSidebarGeometry = false
                    return
                }
                window.layoutIfNeeded()
                self.restoreDefaultSidebarGeometry()
            }
            return
        }

        let restoredFrame = Self.constrainedWindowFrame(
            geometry.windowFrame,
            minimumSize: window.minSize,
            visibleScreenFrames: NSScreen.screens.map(\.visibleFrame),
            fallbackVisibleFrame: window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        )
        if let restoredFrame {
            if window.styleMask.contains(.fullScreen) {
                pendingNormalWindowFrame = restoredFrame
            } else {
                window.setFrame(restoredFrame, display: true)
            }
            lastNormalWindowFrame = restoredFrame
        }

        window.layoutIfNeeded()
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.windowProvider() === window else {
                return
            }
            window.layoutIfNeeded()
            self.restoreSidebarGeometry(geometry)
        }
    }

    /// Produces the geometry that should be persisted for this workspace,
    /// or `nil` when there is nothing meaningful to save (no window, or a
    /// fullscreen window that never had a normal frame).
    func captureGeometry(
        persistedFrame: WorkspaceWindowFrame?
    ) -> WorkspaceGeometryState? {
        guard let window = windowProvider() else {
            return nil
        }

        let isFullScreen = window.styleMask.contains(.fullScreen)
        let normalFrame = Self.normalWindowFrame(
            currentFrame: window.frame,
            isFullScreen: isFullScreen,
            lastNormalFrame: lastNormalWindowFrame,
            persistedFrame: persistedFrame
        )
        if !isFullScreen {
            lastNormalWindowFrame = window.frame
        }
        guard let normalFrame else {
            return nil
        }

        captureExpandedSidebarWidth()
        let isSidebarCollapsed = splitViewController?.splitViewItems.first?.isCollapsed ?? false
        return WorkspaceGeometryState(
            windowFrame: WorkspaceWindowFrame(
                x: Double(normalFrame.origin.x),
                y: Double(normalFrame.origin.y),
                width: Double(normalFrame.width),
                height: Double(normalFrame.height)
            ),
            sidebarWidth: Double(lastExpandedSidebarWidth),
            isSidebarCollapsed: isSidebarCollapsed
        )
    }

    // MARK: - Fullscreen bookkeeping

    func windowWillEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }
        lastNormalWindowFrame = window.frame
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }
        if let pendingNormalWindowFrame {
            window.setFrame(pendingNormalWindowFrame, display: true)
            lastNormalWindowFrame = pendingNormalWindowFrame
            self.pendingNormalWindowFrame = nil
        } else {
            lastNormalWindowFrame = window.frame
        }
    }

    // MARK: - Private sidebar plumbing

    private func restoreSidebarGeometry(_ geometry: WorkspaceGeometryState) {
        guard let sidebarItem = splitViewController?.splitViewItems.first else {
            return
        }

        let width = Self.clampedSidebarWidth(geometry.sidebarWidth)
        isApplyingSidebarGeometry = true
        defer {
            isApplyingSidebarGeometry = false
        }
        lastExpandedSidebarWidth = width
        sidebarItem.isCollapsed = false
        applySidebarWidth(width)
        sidebarItem.isCollapsed = geometry.isSidebarCollapsed
        lastExpandedSidebarWidth = width
    }

    private func restoreDefaultSidebarGeometry() {
        guard let sidebarItem = splitViewController?.splitViewItems.first else {
            return
        }
        isApplyingSidebarGeometry = true
        defer {
            isApplyingSidebarGeometry = false
        }
        sidebarItem.isCollapsed = false
        applySidebarWidth(lastExpandedSidebarWidth)
    }

    private func applySidebarWidth(_ width: CGFloat) {
        prepareSidebarWidth(width)
        guard let splitViewController,
              let sidebarItem = splitViewController.splitViewItems.first else {
            return
        }
        guard !sidebarItem.isCollapsed else {
            return
        }
        let splitView = splitViewController.splitView
        splitViewController.view.layoutSubtreeIfNeeded()
        splitView.adjustSubviews()
        if splitView.arrangedSubviews.count >= 2 {
            splitView.setPosition(width, ofDividerAt: 0)
        }
        lastExpandedSidebarWidth = width
    }

    private func prepareSidebarWidth(_ width: CGFloat) {
        lastExpandedSidebarWidth = width
        guard let splitViewController else {
            return
        }
        let splitView = splitViewController.splitView
        guard splitView.bounds.width > 0 else {
            return
        }
        splitViewController.splitViewItems.first?.preferredThicknessFraction =
            min(max(width / splitView.bounds.width, 0), 1)
    }

    private func applyPendingExpandedSidebarWidthIfPossible() {
        guard let width = pendingExpandedSidebarWidth,
              splitViewController?.splitViewItems.first?.isCollapsed == false else {
            return
        }
        pendingExpandedSidebarWidth = nil
        applySidebarWidth(width)
        isApplyingSidebarGeometry = false
    }

    private func captureExpandedSidebarWidth() {
        guard let splitViewController,
              let sidebarItem = splitViewController.splitViewItems.first,
              !sidebarItem.isCollapsed else {
            return
        }
        let width = sidebarPaneWidth(for: sidebarItem)
        guard width.isFinite, width > 0 else {
            return
        }
        lastExpandedSidebarWidth = Self.clampedSidebarWidth(Double(width))
        let totalWidth = splitViewController.splitView.bounds.width
        if totalWidth > 0 {
            sidebarItem.preferredThicknessFraction = min(
                max(lastExpandedSidebarWidth / totalWidth, 0),
                1
            )
        }
    }

    private func sidebarPaneWidth(for sidebarItem: NSSplitViewItem) -> CGFloat {
        splitViewController?.splitView.arrangedSubviews.first?.frame.width
            ?? sidebarItem.viewController.view.frame.width
    }

    // MARK: - Pure helpers

    static func normalWindowFrame(
        currentFrame: NSRect,
        isFullScreen: Bool,
        lastNormalFrame: NSRect?,
        persistedFrame: WorkspaceWindowFrame?
    ) -> NSRect? {
        if !isFullScreen {
            return currentFrame
        }
        return lastNormalFrame ?? persistedFrame.flatMap(rect(from:))
    }

    static func constrainedWindowFrame(
        _ savedFrame: WorkspaceWindowFrame,
        minimumSize: NSSize,
        visibleScreenFrames: [NSRect],
        fallbackVisibleFrame: NSRect?
    ) -> NSRect? {
        guard let candidate = rect(from: savedFrame) else {
            return nil
        }
        let screens = visibleScreenFrames.filter(isValidScreenFrame)
        guard !screens.isEmpty else {
            return nil
        }

        let bestIntersectingScreen = screens.max {
            intersectionArea(candidate, $0) < intersectionArea(candidate, $1)
        }
        let targetScreen: NSRect
        if let bestIntersectingScreen,
           intersectionArea(candidate, bestIntersectingScreen) > 0 {
            targetScreen = bestIntersectingScreen
        } else if let fallbackVisibleFrame,
                  isValidScreenFrame(fallbackVisibleFrame) {
            targetScreen = fallbackVisibleFrame
        } else {
            targetScreen = screens[0]
        }

        let width = min(max(candidate.width, minimumSize.width), targetScreen.width)
        let height = min(max(candidate.height, minimumSize.height), targetScreen.height)
        let x = min(
            max(candidate.minX, targetScreen.minX),
            targetScreen.maxX - width
        )
        let y = min(
            max(candidate.minY, targetScreen.minY),
            targetScreen.maxY - height
        )
        return NSRect(x: x, y: y, width: width, height: height)
    }

    static func clampedSidebarWidth(_ width: Double?) -> CGFloat {
        guard let width, width.isFinite else {
            return defaultSidebarWidth
        }
        return min(max(CGFloat(width), minimumSidebarWidth), maximumSidebarWidth)
    }

    private static func rect(from frame: WorkspaceWindowFrame) -> NSRect? {
        let values = [frame.x, frame.y, frame.width, frame.height]
        guard values.allSatisfy(\.isFinite), frame.width > 0, frame.height > 0 else {
            return nil
        }
        return NSRect(
            x: frame.x,
            y: frame.y,
            width: frame.width,
            height: frame.height
        )
    }

    private static func isValidScreenFrame(_ frame: NSRect) -> Bool {
        let values = [
            frame.origin.x,
            frame.origin.y,
            frame.width,
            frame.height
        ]
        return values.allSatisfy(\.isFinite) && frame.width > 0 && frame.height > 0
    }

    private static func intersectionArea(_ first: NSRect, _ second: NSRect) -> CGFloat {
        let intersection = first.intersection(second)
        guard !intersection.isNull else {
            return 0
        }
        return max(0, intersection.width) * max(0, intersection.height)
    }
}
