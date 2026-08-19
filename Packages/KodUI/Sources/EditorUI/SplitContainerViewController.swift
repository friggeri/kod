import AppKit
import WorkspaceCore

/// Keeps the native thin divider while providing a forgiving drag target.
@MainActor
final class EditorSplitView: NSSplitView, NSSplitViewDelegate {
    static let minimumDividerHitThickness: CGFloat = 12

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func splitView(
        _ splitView: NSSplitView,
        effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        var effectiveRect = proposedEffectiveRect
        if splitView.isVertical,
           effectiveRect.width < Self.minimumDividerHitThickness {
            effectiveRect.origin.x =
                drawnRect.midX - Self.minimumDividerHitThickness / 2
            effectiveRect.size.width = Self.minimumDividerHitThickness
        } else if !splitView.isVertical,
                  effectiveRect.height < Self.minimumDividerHitThickness {
            effectiveRect.origin.y =
                drawnRect.midY - Self.minimumDividerHitThickness / 2
            effectiveRect.size.height = Self.minimumDividerHitThickness
        }
        return effectiveRect
    }
}

/// Builds and rebuilds a recursive `NSSplitView` tree from a
/// `SplitLayoutNode`, reusing existing `EditorGroupViewController`s across
/// rebuilds so live tab/document state survives further splits or closes.
///
/// AppKit's `NSSplitView.isVertical == true` means side-by-side panes
/// (a vertical divider line), which is the opposite of the intuition its name
/// suggests. `SplitOrientation.horizontal` in `WorkspaceCore` means
/// "side-by-side," so it maps to `isVertical = true` here.
@MainActor
public final class SplitContainerViewController: NSViewController {
    private(set) var root: SplitLayoutNode
    private let makeGroupController: (EditorGroupID) -> EditorGroupViewController
    private var groupControllers: [EditorGroupID: EditorGroupViewController] = [:]
    private weak var builtRootView: NSView?

    public init(
        root: SplitLayoutNode,
        makeGroupController: @escaping (EditorGroupID) -> EditorGroupViewController
    ) {
        self.root = root
        self.makeGroupController = makeGroupController
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func loadView() {
        view = NSView()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        rebuild(root: root)
    }

    public func controller(for groupID: EditorGroupID) -> EditorGroupViewController? {
        groupControllers[groupID]
    }

    public var allGroupControllers: [EditorGroupViewController] {
        Array(groupControllers.values)
    }

    /// Rebuilds the split view hierarchy for a new tree, reusing group view
    /// controllers whose ID survives so their tabs/documents are preserved.
    public func rebuild(root: SplitLayoutNode) {
        self.root = root

        let survivingIDs = Set(root.groupIDs)
        for (id, controller) in groupControllers where !survivingIDs.contains(id) {
            controller.removeFromParent()
            groupControllers.removeValue(forKey: id)
        }

        children.forEach { $0.removeFromParent() }
        view.subviews.forEach { $0.removeFromSuperview() }

        let builtView = buildView(for: root)
        builtRootView = builtView
        builtView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(builtView)
        NSLayoutConstraint.activate([
            builtView.topAnchor.constraint(equalTo: view.topAnchor),
            builtView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            builtView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            builtView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    public func captureLayout() -> SplitLayoutNode {
        guard let builtRootView else {
            return root
        }
        view.layoutSubtreeIfNeeded()
        let capturedRoot = capture(node: root, from: builtRootView)
        root = capturedRoot
        return capturedRoot
    }

    private func groupController(for id: EditorGroupID) -> EditorGroupViewController {
        if let existing = groupControllers[id] {
            return existing
        }
        let controller = makeGroupController(id)
        groupControllers[id] = controller
        return controller
    }

    private func buildView(for node: SplitLayoutNode) -> NSView {
        switch node {
        case .leaf(let id):
            let controller = groupController(for: id)
            if controller.parent !== self {
                addChild(controller)
            }
            return controller.view

        case .split(let orientation, let ratio, let first, let second):
            let splitView = EditorSplitView(frame: .zero)
            splitView.isVertical = orientation == .horizontal
            splitView.dividerStyle = .thin

            let firstView = buildView(for: first)
            let secondView = buildView(for: second)
            let splitAxis: NSLayoutConstraint.Orientation = splitView.isVertical
                ? .horizontal
                : .vertical
            for paneView in [firstView, secondView] {
                paneView.setContentHuggingPriority(.defaultLow, for: splitAxis)
                paneView.setContentCompressionResistancePriority(.defaultLow, for: splitAxis)
            }
            splitView.addArrangedSubview(firstView)
            splitView.addArrangedSubview(secondView)
            splitView.setHoldingPriority(.defaultLow - 1, forSubviewAt: 0)
            splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

            DispatchQueue.main.async { [weak splitView] in
                guard let splitView, splitView.subviews.count == 2 else {
                    return
                }
                let total = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
                guard total > 0 else {
                    return
                }
                splitView.setPosition(total * ratio, ofDividerAt: 0)
            }

            return splitView
        }
    }

    private func capture(node: SplitLayoutNode, from builtView: NSView) -> SplitLayoutNode {
        switch node {
        case .leaf:
            return node

        case .split(let orientation, let savedRatio, let first, let second):
            guard let splitView = builtView as? NSSplitView,
                  splitView.arrangedSubviews.count == 2 else {
                return node
            }

            let total = splitView.isVertical
                ? splitView.bounds.width
                : splitView.bounds.height
            let firstExtent = splitView.isVertical
                ? splitView.arrangedSubviews[0].frame.width
                : splitView.arrangedSubviews[0].frame.height
            let ratio = total > 0
                ? min(max(Double(firstExtent / total), 0), 1)
                : savedRatio

            return .split(
                orientation: orientation,
                ratio: ratio,
                first: capture(node: first, from: splitView.arrangedSubviews[0]),
                second: capture(node: second, from: splitView.arrangedSubviews[1])
            )
        }
    }
}
