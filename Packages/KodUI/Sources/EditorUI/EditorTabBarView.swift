import AppKit
import QuartzCore
import WorkspaceCore

/// The editor tab rail: an `NSCollectionView` with a custom layout that
/// keeps every tab inside the rail, plus the in-rail reordering and
/// cross-pane drag state machine. Split out of
/// `EditorGroupViewController` so the group file owns tab *content* state
/// (`EditorTabRuntime`) and this file owns tab *bar* interaction state.

@MainActor
private final class EditorTabReorderLayout: NSCollectionViewLayout {
    private let itemHeight: CGFloat = 32
    private var sourceIndex: Int?
    private var draggedFrame: NSRect?

    var isReordering: Bool {
        sourceIndex != nil
    }

    func beginReordering(sourceIndex: Int, frame: NSRect) {
        self.sourceIndex = sourceIndex
        draggedFrame = frame
        invalidateLayout()
    }

    func update(targetIndex _: Int, draggedFrame: NSRect) {
        self.draggedFrame = draggedFrame
        invalidateLayout()
    }

    func updateDraggedFrame(_ frame: NSRect) {
        draggedFrame = frame
    }

    func endReordering() {
        sourceIndex = nil
        draggedFrame = nil
        invalidateLayout()
    }

    func restingFrame(at index: Int) -> NSRect? {
        baseFrame(at: index)
    }

    override var collectionViewContentSize: NSSize {
        guard let collectionView else {
            return .zero
        }
        return NSSize(width: collectionView.bounds.width, height: itemHeight)
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard let collectionView else {
            return []
        }

        return (0..<collectionView.numberOfItems(inSection: 0)).compactMap { index in
            guard let attributes = layoutAttributesForItem(
                at: IndexPath(item: index, section: 0)
            ), attributes.frame.intersects(rect) else {
                return nil
            }
            return attributes
        }
    }

    override func layoutAttributesForItem(
        at indexPath: IndexPath
    ) -> NSCollectionViewLayoutAttributes? {
        guard let frame = baseFrame(at: indexPath.item) else {
            return nil
        }
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        attributes.frame = frame

        if indexPath.item == sourceIndex {
            if let draggedFrame {
                attributes.frame = draggedFrame
            }
            attributes.zIndex = 1_000
        }
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        guard let collectionView else {
            return false
        }
        return abs(collectionView.bounds.width - newBounds.width) > 0.5
    }

    private func baseFrame(at index: Int) -> NSRect? {
        guard let collectionView else {
            return nil
        }
        let count = collectionView.numberOfItems(inSection: 0)
        guard count > 0, (0..<count).contains(index) else {
            return nil
        }
        let width = max(collectionView.bounds.width / CGFloat(count), 1)
        return NSRect(
            x: CGFloat(index) * width,
            y: 0,
            width: width,
            height: itemHeight
        )
    }
}

private final class EditorTabClipView: NSClipView {
    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: .zero)
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)
        constrained.origin = .zero
        return constrained
    }

    override func layout() {
        super.layout()
        guard let documentView else {
            return
        }
        documentView.frame = bounds
    }
}

private final class EditorTabCollectionView: NSCollectionView {
    override func setFrameSize(_ newSize: NSSize) {
        guard let clipView = superview as? EditorTabClipView else {
            super.setFrameSize(newSize)
            return
        }
        super.setFrameSize(clipView.bounds.size)
    }
}

private final class EditorTabDragProxyView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

/// A fixed-width AppKit collection view keeps every tab inside the rail while
/// a custom flow layout provides in-rail, interactive reordering.
@MainActor
final class EditorTabBarView: NSView {
    private static let itemIdentifier = NSUserInterfaceItemIdentifier("editorGroup.tabItem")
    private static let horizontalRailInset: CGFloat = 0
    private static var reorderAnimationDuration: TimeInterval {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
    }

    private final class DragSession {
        let tabID: EditorTabID
        let sourceIndex: Int
        let sourceItemView: EditorTabItemView
        let pointerDownLocation: NSPoint
        let sourceFrame: NSRect
        var targetIndex: Int
        var draggedFrame: NSRect
        var latestWindowLocation: NSPoint
        var isDragging = false
        var isSettling = false
        var externalTarget: EditorTabDropPreview?
        var dragProxy: EditorTabDragProxyView?
        var pendingCommit: EditorTabDropAnchors?

        init(
            tabID: EditorTabID,
            sourceIndex: Int,
            sourceItemView: EditorTabItemView,
            pointerDownLocation: NSPoint,
            sourceFrame: NSRect,
            latestWindowLocation: NSPoint
        ) {
            self.tabID = tabID
            self.sourceIndex = sourceIndex
            self.sourceItemView = sourceItemView
            self.pointerDownLocation = pointerDownLocation
            self.sourceFrame = sourceFrame
            targetIndex = sourceIndex
            draggedFrame = sourceFrame
            self.latestWindowLocation = latestWindowLocation
        }
    }

    private let railBackgroundView = NSView()
    private let collectionView = EditorTabCollectionView()
    private let reorderLayout = EditorTabReorderLayout()
    private let clipView = EditorTabClipView()
    private var tabs: [EditorTab] = []
    private var selectedTabID: EditorTabID?
    private var onSelect: (EditorTabID) -> Void = { _ in }
    private var onClose: (EditorTabID) -> Void = { _ in }
    private var onPin: (EditorTabID) -> Void = { _ in }
    private var onMove: (EditorTabID, Int) -> Void = { _, _ in }
    private var onExternalDragUpdate: (EditorTabID, NSPoint) -> EditorTabDropPreview? = { _, _ in nil }
    private var onExternalDrop: (EditorTabID, EditorTabDropPreview) -> Bool = { _, _ in false }
    private var onDragEnd: () -> Void = {}
    private var isApplyingSelection = false
    private var lastLayoutWidth: CGFloat = 0
    private var dragSession: DragSession?
    private var dragCancellationMonitor: LocalEventMonitor?
    private var externalInsertionIndex: Int?
    var isActive = true {
        didSet {
            guard oldValue != isActive else {
                return
            }
            updateBarAppearance()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        railBackgroundView.wantsLayer = true
        railBackgroundView.identifier = NSUserInterfaceItemIdentifier("editorGroup.tabRail")
        railBackgroundView.layer?.cornerRadius = 16
        railBackgroundView.layer?.cornerCurve = .continuous
        railBackgroundView.layer?.masksToBounds = true
        railBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        updateBarAppearance()

        collectionView.collectionViewLayout = reorderLayout
        collectionView.identifier = NSUserInterfaceItemIdentifier("editorGroup.tabCollection")
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.wantsLayer = true
        collectionView.layer?.cornerRadius = 16
        collectionView.layer?.cornerCurve = .continuous
        collectionView.layer?.masksToBounds = true
        collectionView.autoresizingMask = [.width, .height]
        collectionView.register(
            EditorTabCollectionItem.self,
            forItemWithIdentifier: Self.itemIdentifier
        )

        clipView.identifier = NSUserInterfaceItemIdentifier("editorGroup.tabClip")
        clipView.drawsBackground = false
        clipView.wantsLayer = true
        clipView.layer?.cornerRadius = 16
        clipView.layer?.cornerCurve = .continuous
        clipView.layer?.masksToBounds = true
        clipView.documentView = collectionView
        clipView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(railBackgroundView)
        addSubview(clipView)
        NSLayoutConstraint.activate([
            railBackgroundView.topAnchor.constraint(equalTo: topAnchor),
            railBackgroundView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            railBackgroundView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            railBackgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            clipView.topAnchor.constraint(equalTo: topAnchor),
            clipView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            clipView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            clipView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        let layoutWidth = clipView.bounds.width
        guard abs(layoutWidth - lastLayoutWidth) > 0.5 else {
            return
        }
        cancelCurrentDrag(animated: false)
        lastLayoutWidth = layoutWidth
        updateCollectionLayout()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            cancelCurrentDrag(animated: false)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        cancelCurrentDrag(animated: false)
        updateBarAppearance()
        collectionView.reloadData()
    }

    private func updateBarAppearance() {
        let isDark = effectiveAppearance.bestMatch(
            from: [.aqua, .darkAqua]
        ) == .darkAqua
        let opacity: CGFloat
        if isDark {
            opacity = isActive ? 0.16 : 0.22
        } else {
            opacity = isActive ? 0.09 : 0.13
        }
        railBackgroundView.layer?.backgroundColor = NSColor.black
            .withAlphaComponent(opacity)
            .cgColor
        railBackgroundView.layer?.borderWidth = 0
    }

    func update(
        tabs: [EditorTab],
        selectedTabID: EditorTabID?,
        onSelect: @escaping (EditorTabID) -> Void,
        onClose: @escaping (EditorTabID) -> Void,
        onPin: @escaping (EditorTabID) -> Void,
        onMove: @escaping (EditorTabID, Int) -> Void,
        onExternalDragUpdate: @escaping (EditorTabID, NSPoint) -> EditorTabDropPreview?,
        onExternalDrop: @escaping (EditorTabID, EditorTabDropPreview) -> Bool,
        onDragEnd: @escaping () -> Void
    ) {
        if cancelCurrentDrag(animated: false, resolvingAgainst: tabs) {
            return
        }
        externalInsertionIndex = nil
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        self.onSelect = onSelect
        self.onClose = onClose
        self.onPin = onPin
        self.onMove = onMove
        self.onExternalDragUpdate = onExternalDragUpdate
        self.onExternalDrop = onExternalDrop
        self.onDragEnd = onDragEnd
        collectionView.reloadData()
        updateCollectionLayout()

        isApplyingSelection = true
        defer { isApplyingSelection = false }
        if let selectedTabID,
           let index = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            collectionView.selectionIndexPaths = [IndexPath(item: index, section: 0)]
        } else {
            collectionView.selectionIndexPaths = []
        }
    }

    func insertionIndex(at windowLocation: NSPoint) -> Int? {
        guard window != nil else {
            return nil
        }
        let localLocation = convert(windowLocation, from: nil)
        let hitBounds = railBackgroundView.frame.insetBy(dx: 0, dy: -6)
        guard hitBounds.contains(localLocation) else {
            return nil
        }
        guard !tabs.isEmpty, clipView.bounds.width > 0 else {
            return 0
        }
        let collectionLocation = collectionView.convert(windowLocation, from: nil)
        let tabWidth = clipView.bounds.width / CGFloat(tabs.count + 1)
        let rawIndex = Int(floor(collectionLocation.x / tabWidth))
        return max(0, min(rawIndex, tabs.count))
    }

    @discardableResult
    func showExternalDropPreview(at windowLocation: NSPoint) -> EditorTabExternalDropGeometry? {
        guard let insertionIndex = insertionIndex(at: windowLocation) else {
            clearExternalDropPreview()
            return nil
        }
        if externalInsertionIndex != insertionIndex {
            externalInsertionIndex = insertionIndex
            applyExternalInsertionLayout(at: insertionIndex, animated: true)
            refreshSeparatorSuppression()
        }
        let finalCount = tabs.count + 1
        let tabWidth = clipView.bounds.width / CGFloat(finalCount)
        let gapFrame = NSRect(
            x: CGFloat(insertionIndex) * tabWidth,
            y: 0,
            width: tabWidth,
            height: clipView.bounds.height
        )
        return EditorTabExternalDropGeometry(
            insertionIndex: insertionIndex,
            gapFrameInWindow: collectionView.convert(gapFrame, to: nil),
            railFrameInWindow: collectionView.convert(collectionView.bounds, to: nil)
        )
    }

    func clearExternalDropPreview() {
        guard externalInsertionIndex != nil else {
            return
        }
        externalInsertionIndex = nil
        restoreExternalInsertionLayout(animated: true)
        refreshSeparatorSuppression()
    }

    func consumeExternalDropPreview() {
        externalInsertionIndex = nil
        refreshSeparatorSuppression()
    }

    private func applyExternalInsertionLayout(at insertionIndex: Int, animated: Bool) {
        collectionView.layoutSubtreeIfNeeded()
        let finalCount = tabs.count + 1
        guard finalCount > 0 else {
            return
        }
        let tabWidth = clipView.bounds.width / CGFloat(finalCount)
        animateItemFrames(animated: animated) {
            tabs.indices.map { itemIndex in
                let slot = itemIndex < insertionIndex ? itemIndex : itemIndex + 1
                return NSRect(
                    x: CGFloat(slot) * tabWidth,
                    y: 0,
                    width: tabWidth,
                    height: clipView.bounds.height
                )
            }
        }
    }

    private func restoreExternalInsertionLayout(animated: Bool) {
        animateItemFrames(animated: animated) {
            tabs.indices.map { itemIndex in
                reorderLayout.restingFrame(at: itemIndex) ?? .zero
            }
        }
    }

    private func animateItemFrames(
        animated: Bool,
        frames: () -> [NSRect]
    ) {
        let targetFrames = frames()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? Self.reorderAnimationDuration : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for itemIndex in tabs.indices {
                guard targetFrames.indices.contains(itemIndex),
                      let item = currentItemView(at: itemIndex) else {
                    continue
                }
                item.animator().frame = targetFrames[itemIndex]
            }
        }
    }

    private func updateCollectionLayout() {
        reorderLayout.invalidateLayout()
        collectionView.needsLayout = true
        collectionView.layoutSubtreeIfNeeded()
    }

    private func handleMouseDown(on tabID: EditorTabID, event: NSEvent) {
        cancelCurrentDrag(animated: false)

        if selectedTabID != tabID {
            onSelect(tabID)
        }
        window?.layoutIfNeeded()
        layoutSubtreeIfNeeded()
        collectionView.layoutSubtreeIfNeeded()

        guard let sourceIndex = tabs.firstIndex(where: { $0.id == tabID }),
              let sourceItemView = currentItemView(at: sourceIndex),
              let sourceFrame = reorderLayout.restingFrame(at: sourceIndex) else {
            return
        }
        let pointerLocation = collectionView.convert(event.locationInWindow, from: nil)
        dragSession = DragSession(
            tabID: tabID,
            sourceIndex: sourceIndex,
            sourceItemView: sourceItemView,
            pointerDownLocation: pointerLocation,
            sourceFrame: sourceFrame,
            latestWindowLocation: event.locationInWindow
        )
    }

    private func handleMouseDragged(on tabID: EditorTabID, event: NSEvent) {
        guard let session = dragSession,
              session.tabID == tabID,
              !session.isSettling else {
            return
        }

        session.latestWindowLocation = event.locationInWindow
        let pointerLocation = collectionView.convert(event.locationInWindow, from: nil)
        if !session.isDragging {
            guard EditorTabDragGeometry.hasExceededActivationDistance(
                from: session.pointerDownLocation,
                to: pointerLocation
            ) else {
                return
            }
            beginDrag(session)
        }
        updateDragTracking(session, windowLocation: event.locationInWindow)
    }

    private func handleMouseUp(on tabID: EditorTabID, event: NSEvent) {
        guard let session = dragSession,
              session.tabID == tabID,
              !session.isSettling else {
            return
        }
        guard session.isDragging else {
            dragSession = nil
            return
        }

        session.latestWindowLocation = event.locationInWindow
        updateDragTracking(session, windowLocation: event.locationInWindow)
        if let externalTarget = session.externalTarget {
            settleExternalDrag(session, into: externalTarget)
            return
        }
        settleDrag(session, at: session.targetIndex, commit: true, animated: true)
    }

    private func beginDrag(_ session: DragSession) {
        session.isDragging = true
        reorderLayout.beginReordering(
            sourceIndex: session.sourceIndex,
            frame: session.sourceFrame
        )
        setSourceDraggingAppearance(true, for: session)
        refreshSeparatorSuppression()

        dragCancellationMonitor = LocalEventMonitor(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, self?.dragSession?.isDragging == true else {
                return event
            }
            self?.cancelCurrentDrag(animated: true)
            return nil
        }
    }

    private func updateDragTracking(_ session: DragSession, windowLocation: NSPoint) {
        guard dragSession === session, session.isDragging, !session.isSettling else {
            return
        }
        if let externalTarget = onExternalDragUpdate(session.tabID, windowLocation) {
            let isBeginningExternalDrag = session.externalTarget == nil
            session.externalTarget = externalTarget
            if isBeginningExternalDrag {
                beginExternalDrag(session)
            }
            updateExternalDragProxy(
                session,
                target: externalTarget,
                windowLocation: windowLocation
            )
            return
        }

        if session.externalTarget != nil {
            endExternalDragPreview(session)
        }
        updateActiveDrag(session, windowLocation: windowLocation)
    }

    private func beginExternalDrag(_ session: DragSession) {
        guard session.dragProxy == nil,
              let overlay = window?.contentView,
              let image = dragSnapshot(of: displayedSourceItemView(for: session)) else {
            return
        }

        session.targetIndex = session.sourceIndex
        resetVisibleItemTranslations()
        let sourceItem = displayedSourceItemView(for: session)
        let proxy = EditorTabDragProxyView(frame: sourceItem.convert(sourceItem.bounds, to: overlay))
        proxy.identifier = NSUserInterfaceItemIdentifier("editorGroup.tabDragProxy")
        proxy.image = image
        proxy.imageScaling = .scaleAxesIndependently
        proxy.wantsLayer = true
        proxy.layer?.zPosition = 10_000
        overlay.addSubview(proxy, positioned: .above, relativeTo: nil)
        session.dragProxy = proxy
        sourceItem.alphaValue = 0
        applyExternalRemovalLayout(session, animated: true)
        refreshSeparatorSuppression()
    }

    private func updateExternalDragProxy(
        _ session: DragSession,
        target: EditorTabDropPreview,
        windowLocation: NSPoint
    ) {
        guard let proxy = session.dragProxy,
              let overlay = proxy.superview else {
            return
        }
        let railFrame = overlay.convert(target.railFrameInWindow, from: nil)
        let gapFrame = overlay.convert(target.gapFrameInWindow, from: nil)
        let grabFraction = max(
            0,
            min(
                (session.pointerDownLocation.x - session.sourceFrame.minX)
                    / max(session.sourceFrame.width, 1),
                1
            )
        )
        let pointer = overlay.convert(windowLocation, from: nil)
        let width = session.sourceFrame.width
        let minimumX = railFrame.minX
        let maximumX = max(minimumX, railFrame.maxX - width)
        proxy.frame = NSRect(
            x: min(max(pointer.x - grabFraction * width, minimumX), maximumX),
            y: gapFrame.minY,
            width: width,
            height: gapFrame.height
        )
    }

    private func endExternalDragPreview(_ session: DragSession) {
        session.externalTarget = nil
        session.dragProxy?.removeFromSuperview()
        session.dragProxy = nil
        restoreSourceLayout(session, animated: false)
        displayedSourceItemView(for: session).alphaValue = 1
        refreshSeparatorSuppression()
    }

    private func applyExternalRemovalLayout(_ session: DragSession, animated: Bool) {
        let remainingCount = tabs.count - 1
        guard remainingCount > 0 else {
            return
        }
        let tabWidth = clipView.bounds.width / CGFloat(remainingCount)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? Self.reorderAnimationDuration : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for itemIndex in tabs.indices where itemIndex != session.sourceIndex {
                guard let item = currentItemView(at: itemIndex) else {
                    continue
                }
                let slot = itemIndex < session.sourceIndex ? itemIndex : itemIndex - 1
                item.animator().frame = NSRect(
                    x: CGFloat(slot) * tabWidth,
                    y: 0,
                    width: tabWidth,
                    height: clipView.bounds.height
                )
            }
        }
    }

    private func restoreSourceLayout(_ session: DragSession, animated: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? Self.reorderAnimationDuration : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for itemIndex in tabs.indices {
                guard let item = currentItemView(at: itemIndex),
                      let frame = reorderLayout.restingFrame(at: itemIndex) else {
                    continue
                }
                item.animator().frame = frame
            }
        }
        session.draggedFrame = session.sourceFrame
        reorderLayout.update(targetIndex: session.sourceIndex, draggedFrame: session.sourceFrame)
    }

    private func dragSnapshot(of view: NSView) -> NSImage? {
        guard view.bounds.width > 0,
              view.bounds.height > 0,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(representation)
        return image
    }

    private func updateActiveDrag(_ session: DragSession, windowLocation: NSPoint) {
        guard dragSession === session, session.isDragging, !session.isSettling else {
            return
        }

        let pointerLocation = collectionView.convert(windowLocation, from: nil)
        let proposedOriginX = session.sourceFrame.minX
            + pointerLocation.x
            - session.pointerDownLocation.x
        let originX = EditorTabDragGeometry.clampedOriginX(
            proposedOriginX,
            itemWidth: session.sourceFrame.width,
            visibleBounds: collectionView.visibleRect,
            horizontalInset: Self.horizontalRailInset
        )
        let draggedFrame = NSRect(
            x: originX,
            y: session.sourceFrame.minY,
            width: session.sourceFrame.width,
            height: session.sourceFrame.height
        )
        session.draggedFrame = draggedFrame
        reorderLayout.updateDraggedFrame(draggedFrame)

        let slotCenters = tabs.indices.map {
            session.sourceFrame.midX
                + CGFloat($0 - session.sourceIndex) * session.sourceFrame.width
        }
        var targetIndex = EditorTabDragGeometry.updatedTargetIndex(
            currentTargetIndex: session.targetIndex,
            draggedCenterX: draggedFrame.midX,
            slotCenters: slotCenters
        )
        if draggedFrame.minX <= collectionView.visibleRect.minX + Self.horizontalRailInset + 0.5 {
            targetIndex = 0
        } else if draggedFrame.maxX >= collectionView.visibleRect.maxX - Self.horizontalRailInset - 0.5 {
            targetIndex = tabs.count - 1
        }
        if targetIndex != session.targetIndex {
            animateGapTransition(session, to: targetIndex)
        }

        setSourceFrame(draggedFrame, for: session)
        refreshSeparatorSuppression()
    }

    private func animateGapTransition(_ session: DragSession, to targetIndex: Int) {
        session.targetIndex = targetIndex
        reorderLayout.update(targetIndex: targetIndex, draggedFrame: session.draggedFrame)
        for itemIndex in tabs.indices where itemIndex != session.sourceIndex {
            let visualSlot = EditorTabDragGeometry.visualSlot(
                forItemAt: itemIndex,
                sourceIndex: session.sourceIndex,
                targetIndex: targetIndex
            )
            guard let item = currentItemView(at: itemIndex) else {
                continue
            }
            item.setDisplacement(
                x: CGFloat(visualSlot - itemIndex) * session.sourceFrame.width,
                duration: Self.reorderAnimationDuration
            )
        }
        setSourceFrame(session.draggedFrame, for: session)
        refreshSeparatorSuppression()
    }

    private func settleExternalDrag(
        _ session: DragSession,
        into target: EditorTabDropPreview
    ) {
        guard dragSession === session, !session.isSettling else {
            return
        }
        session.isSettling = true
        stopDragInfrastructure()

        let completion: @MainActor @Sendable () -> Void = { [weak self, weak session] in
            guard let self, let session, self.dragSession === session else {
                return
            }
            self.commitExternalDrag(session, into: target)
        }
        guard let proxy = session.dragProxy,
              let overlay = proxy.superview else {
            completion()
            return
        }
        let destinationFrame = overlay.convert(target.gapFrameInWindow, from: nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.reorderAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            proxy.animator().frame = destinationFrame
        } completionHandler: {
            MainActor.assumeIsolated {
                completion()
            }
        }
    }

    private func commitExternalDrag(
        _ session: DragSession,
        into target: EditorTabDropPreview
    ) {
        guard dragSession === session else {
            return
        }
        stopDragInfrastructure()
        setSourceDraggingAppearance(false, for: session)
        reorderLayout.endReordering()
        dragSession = nil

        let committed = onExternalDrop(session.tabID, target)
        session.dragProxy?.removeFromSuperview()
        session.dragProxy = nil
        if !committed {
            restoreSourceLayout(session, animated: false)
            displayedSourceItemView(for: session).alphaValue = 1
            collectionView.layoutSubtreeIfNeeded()
        }
        refreshSeparatorSuppression()
        onDragEnd()
    }

    private func settleDrag(
        _ session: DragSession,
        at destinationIndex: Int,
        commit: Bool,
        animated: Bool
    ) {
        guard dragSession === session, !session.isSettling else {
            return
        }
        session.isSettling = true
        session.pendingCommit = commit && destinationIndex != session.sourceIndex
            ? EditorTabDropAnchors(
                tabIDs: tabs.map(\.id),
                sourceTabID: session.tabID,
                destination: destinationIndex
            )
            : nil
        stopDragInfrastructure()

        let destinationFrame = session.sourceFrame.offsetBy(
            dx: CGFloat(destinationIndex - session.sourceIndex) * session.sourceFrame.width,
            dy: 0
        )
        reorderLayout.update(
            targetIndex: destinationIndex,
            draggedFrame: destinationFrame
        )
        for itemIndex in tabs.indices where itemIndex != session.sourceIndex {
            let visualSlot = EditorTabDragGeometry.visualSlot(
                forItemAt: itemIndex,
                sourceIndex: session.sourceIndex,
                targetIndex: destinationIndex
            )
            guard let item = currentItemView(at: itemIndex) else {
                continue
            }
            item.setDisplacement(
                x: CGFloat(visualSlot - itemIndex) * session.sourceFrame.width,
                duration: Self.reorderAnimationDuration
            )
        }

        let completion: @MainActor @Sendable () -> Void = { [weak self, weak session] in
            if let self, let session {
                self.finishDrag(session)
            }
        }

        guard animated else {
            setSourceFrame(destinationFrame, for: session)
            completion()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.reorderAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let sourceItem = displayedSourceItemView(for: session)
            sourceItem.frame = session.draggedFrame
            sourceItem.animator().frame = destinationFrame
        } completionHandler: {
            MainActor.assumeIsolated {
                completion()
            }
        }
    }

    @discardableResult
    private func cancelCurrentDrag(
        animated: Bool,
        resolvingAgainst latestTabs: [EditorTab]? = nil
    ) -> Bool {
        guard let session = dragSession else {
            return false
        }
        if session.externalTarget != nil {
            cancelExternalDrag(session, animated: animated)
            return false
        }
        if session.isSettling {
            return finishDrag(session, resolvingAgainst: latestTabs)
        }
        guard session.isDragging, animated else {
            return finishDrag(session, resolvingAgainst: latestTabs)
        }
        settleDrag(session, at: session.sourceIndex, commit: false, animated: true)
        return false
    }

    private func cancelExternalDrag(_ session: DragSession, animated: Bool) {
        guard dragSession === session else {
            return
        }
        session.isSettling = true
        stopDragInfrastructure()
        onDragEnd()
        restoreSourceLayout(session, animated: animated)

        let completion: @MainActor @Sendable () -> Void = { [weak self, weak session] in
            guard let self, let session, self.dragSession === session else {
                return
            }
            session.dragProxy?.removeFromSuperview()
            session.dragProxy = nil
            self.setSourceDraggingAppearance(false, for: session)
            self.displayedSourceItemView(for: session).alphaValue = 1
            self.reorderLayout.endReordering()
            self.dragSession = nil
            self.refreshSeparatorSuppression()
            self.collectionView.layoutSubtreeIfNeeded()
        }
        guard animated,
              let proxy = session.dragProxy,
              let overlay = proxy.superview else {
            completion()
            return
        }
        let sourceFrame = overlay.convert(
            collectionView.convert(session.sourceFrame, to: nil),
            from: nil
        )
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.reorderAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            proxy.animator().frame = sourceFrame
        } completionHandler: {
            MainActor.assumeIsolated {
                completion()
            }
        }
    }

    @discardableResult
    private func finishDrag(
        _ session: DragSession,
        resolvingAgainst latestTabs: [EditorTab]? = nil
    ) -> Bool {
        guard dragSession === session else {
            return false
        }
        let currentTabs = latestTabs ?? tabs
        let destinationIndex = session.pendingCommit?.destination(
            in: currentTabs.map(\.id)
        )
        stopDragInfrastructure()
        session.sourceItemView.layer?.removeAllAnimations()
        displayedSourceItemView(for: session).layer?.removeAllAnimations()
        setSourceDraggingAppearance(false, for: session)
        resetVisibleItemTranslations()
        reorderLayout.endReordering()
        dragSession = nil
        refreshSeparatorSuppression()
        onDragEnd()

        if let destinationIndex {
            onMove(session.tabID, destinationIndex)
            return true
        }
        collectionView.layoutSubtreeIfNeeded()
        return false
    }

    private func stopDragInfrastructure() {
        dragCancellationMonitor = nil
    }

    private func currentItemView(at index: Int) -> EditorTabItemView? {
        guard tabs.indices.contains(index) else {
            return nil
        }
        return findItemView(for: tabs[index].id, in: collectionView)
    }

    private func displayedSourceItemView(for session: DragSession) -> EditorTabItemView {
        currentItemView(at: session.sourceIndex) ?? session.sourceItemView
    }

    private func setSourceFrame(_ frame: NSRect, for session: DragSession) {
        session.sourceItemView.frame = frame
        let displayedItemView = displayedSourceItemView(for: session)
        if displayedItemView !== session.sourceItemView {
            displayedItemView.frame = frame
        }
    }

    private func setSourceDraggingAppearance(
        _ isDragging: Bool,
        for session: DragSession
    ) {
        session.sourceItemView.setDraggingAppearance(isDragging)
        let displayedItemView = displayedSourceItemView(for: session)
        if displayedItemView !== session.sourceItemView {
            displayedItemView.setDraggingAppearance(isDragging)
        }
    }

    private func findItemView(
        for tabID: EditorTabID,
        in view: NSView
    ) -> EditorTabItemView? {
        if let itemView = view as? EditorTabItemView,
           itemView.tabID == tabID {
            return itemView
        }
        for subview in view.subviews {
            if let match = findItemView(for: tabID, in: subview) {
                return match
            }
        }
        return nil
    }

    private func resetVisibleItemTranslations() {
        for itemIndex in tabs.indices {
            guard let item = currentItemView(at: itemIndex) else {
                continue
            }
            item.resetDisplacement()
        }
    }

    private func refreshSeparatorSuppression() {
        for itemIndex in tabs.indices {
            currentItemView(at: itemIndex)?.setSeparatorSuppressedForDrag(
                shouldSuppressSeparator(at: itemIndex)
            )
        }
    }

    private func shouldSuppressSeparator(at itemIndex: Int) -> Bool {
        if let session = dragSession, session.isDragging {
            if itemIndex == session.sourceIndex {
                return true
            }
            if session.externalTarget != nil {
                return false
            }
            let visualSlot = EditorTabDragGeometry.visualSlot(
                forItemAt: itemIndex,
                sourceIndex: session.sourceIndex,
                targetIndex: session.targetIndex
            )
            if visualSlot == session.targetIndex - 1 {
                return true
            }
        }
        return externalInsertionIndex.map { itemIndex == $0 - 1 } ?? false
    }
}

@MainActor
extension EditorTabBarView: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        tabs.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        guard tabs.indices.contains(indexPath.item),
              let item = collectionView.makeItem(
                withIdentifier: Self.itemIdentifier,
                for: indexPath
              ) as? EditorTabCollectionItem else {
            return NSCollectionViewItem()
        }
        let tab = tabs[indexPath.item]
        let nextTabIsSelected = tabs.indices.contains(indexPath.item + 1)
            && tabs[indexPath.item + 1].id == selectedTabID
        item.configure(
            tab: tab,
            isSelected: tab.id == selectedTabID,
            showsTrailingSeparator: indexPath.item < tabs.count - 1
                && tab.id != selectedTabID
                && !nextTabIsSelected,
            onSelect: { [weak self] in self?.onSelect(tab.id) },
            onClose: { [weak self] in self?.onClose(tab.id) },
            onPin: { [weak self] in self?.onPin(tab.id) },
            onMouseDown: { [weak self] event in
                self?.handleMouseDown(on: tab.id, event: event)
            },
            onMouseDragged: { [weak self] event in
                self?.handleMouseDragged(on: tab.id, event: event)
            },
            onMouseUp: { [weak self] event in
                self?.handleMouseUp(on: tab.id, event: event)
            }
        )
        if let session = dragSession, session.isDragging {
            if indexPath.item == session.sourceIndex {
                item.setDraggingAppearance(true)
            } else {
                let visualSlot = EditorTabDragGeometry.visualSlot(
                    forItemAt: indexPath.item,
                    sourceIndex: session.sourceIndex,
                    targetIndex: session.targetIndex
                )
                item.setDisplacement(
                    x: CGFloat(visualSlot - indexPath.item) * session.sourceFrame.width,
                    duration: 0
                )
            }
        }
        item.setSeparatorSuppressedForDrag(shouldSuppressSeparator(at: indexPath.item))
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        didSelectItemsAt indexPaths: Set<IndexPath>
    ) {
        guard !isApplyingSelection else {
            return
        }
        guard let index = indexPaths.first?.item, tabs.indices.contains(index) else {
            return
        }
        onSelect(tabs[index].id)
    }

}
