import AppKit
import WorkspaceCore

/// Builds and rebuilds a recursive `NSSplitView` tree from a
/// `SplitLayoutNode`, reusing existing `EditorGroupViewController`s across
/// rebuilds so live tab/document state survives further splits or closes.
///
/// AppKit's `NSSplitView.isVertical == true` means side-by-side panes
/// (a vertical divider line), which is the opposite of the intuition its name
/// suggests. `SplitOrientation.horizontal` in `WorkspaceCore` means
/// "side-by-side," so it maps to `isVertical = true` here.
@MainActor
final class SplitContainerViewController: NSViewController {
    private(set) var root: SplitLayoutNode
    private let makeGroupController: (EditorGroupID) -> EditorGroupViewController
    private var groupControllers: [EditorGroupID: EditorGroupViewController] = [:]

    init(root: SplitLayoutNode, makeGroupController: @escaping (EditorGroupID) -> EditorGroupViewController) {
        self.root = root
        self.makeGroupController = makeGroupController
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        rebuild(root: root)
    }

    func controller(for groupID: EditorGroupID) -> EditorGroupViewController? {
        groupControllers[groupID]
    }

    var allGroupControllers: [EditorGroupViewController] {
        Array(groupControllers.values)
    }

    /// Rebuilds the split view hierarchy for a new tree, reusing group view
    /// controllers whose ID survives so their tabs/documents are preserved.
    func rebuild(root: SplitLayoutNode) {
        self.root = root

        let survivingIDs = Set(root.groupIDs)
        for (id, controller) in groupControllers where !survivingIDs.contains(id) {
            controller.removeFromParent()
            groupControllers.removeValue(forKey: id)
        }

        children.forEach { $0.removeFromParent() }
        view.subviews.forEach { $0.removeFromSuperview() }

        let builtView = buildView(for: root)
        builtView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(builtView)
        NSLayoutConstraint.activate([
            builtView.topAnchor.constraint(equalTo: view.topAnchor),
            builtView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            builtView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            builtView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
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
            let splitView = NSSplitView()
            splitView.isVertical = orientation == .horizontal
            splitView.dividerStyle = .thin

            let firstView = buildView(for: first)
            let secondView = buildView(for: second)
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
}
