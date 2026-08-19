import AppKit
import LanguageClient

/// One expandable outline node wrapping a `ValidatedHierarchyItem`.
/// Reference type (unlike `ValidatedHierarchyItem` itself) purely so
/// `NSOutlineView` has stable per-node identity to expand/reload against,
/// and so children can be filled in lazily after an async fetch without
/// needing `ValidatedHierarchyItem` to be `Hashable`.
final class HierarchyNode {
    let item: ValidatedHierarchyItem
    /// `nil` until this node's children have been fetched at least once
    /// (including a legitimate empty result, `[]`).
    fileprivate(set) var children: [HierarchyNode]?

    init(item: ValidatedHierarchyItem) {
        self.item = item
    }
}

/// A durable Call Hierarchy / Type Hierarchy surface (SPEC 6.1): one
/// root item with two lazily-expandable directions (e.g. "Callers"/
/// "Callees" for call hierarchy, "Supertypes"/"Subtypes" for type
/// hierarchy). The same controller implements both — only the two
/// `Mode`s passed to `init` differ — since the underlying shape
/// (an item with two direction-dependent child-fetching relations) is
/// identical.
@MainActor
final class HierarchyViewController: NSViewController {
    struct Mode {
        let title: String
        let fetchChildren: (ValidatedHierarchyItem) async throws -> [ValidatedHierarchyItem]
    }

    private let modes: [Mode]
    private let onSelectItem: (ValidatedHierarchyItem) -> Void

    private let modeControl = NSSegmentedControl()
    private let statusLabel = NSTextField(labelWithString: "")
    private let outlineView = NSOutlineView()
    private var selectedModeIndex = 0
    private var rootNodes: [HierarchyNode] = []
    private var inFlightFetches: Set<ObjectIdentifier> = []

    init(root: ValidatedHierarchyItem, modes: [Mode], onSelectItem: @escaping (ValidatedHierarchyItem) -> Void) {
        precondition(!modes.isEmpty, "HierarchyViewController requires at least one Mode")
        self.modes = modes
        self.onSelectItem = onSelectItem
        super.init(nibName: nil, bundle: nil)
        rootNodes = [HierarchyNode(item: root)]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let container = NSView()

        modeControl.segmentStyle = .texturedRounded
        modeControl.segmentCount = modes.count
        for (index, mode) in modes.enumerated() {
            modeControl.setLabel(mode.title, forSegment: index)
            modeControl.setWidth(0, forSegment: index)
        }
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.identifier = NSUserInterfaceItemIdentifier("hierarchy.modeControl")
        modeControl.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.identifier = NSUserInterfaceItemIdentifier("hierarchy.status")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hierarchy.results"))
        column.title = Localized.string("Hierarchy", comment: "Column title for the call/type hierarchy outline view")
        outlineView.addTableColumn(column)
        outlineView.headerView = nil
        outlineView.identifier = NSUserInterfaceItemIdentifier("hierarchy.outline")
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(handleSelection)

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(modeControl)
        container.addSubview(statusLabel)
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            modeControl.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            modeControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),

            statusLabel.centerYAnchor.constraint(equalTo: modeControl.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: modeControl.trailingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        view = container
        outlineView.reloadData()
        outlineView.expandItem(rootNodes.first)
    }

    @objc
    private func modeChanged(_ sender: Any?) {
        selectedModeIndex = modeControl.selectedSegment
        // Switching direction invalidates every previously-fetched
        // child, since "Callers" and "Callees" (or "Supertypes"/
        // "Subtypes") are entirely different relations for the same
        // root item.
        for node in rootNodes {
            resetChildrenRecursively(node)
        }
        outlineView.reloadData()
        outlineView.expandItem(rootNodes.first)
    }

    private func resetChildrenRecursively(_ node: HierarchyNode) {
        node.children?.forEach(resetChildrenRecursively)
        node.children = nil
    }

    @objc
    private func handleSelection(_ sender: Any?) {
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? HierarchyNode else {
            return
        }
        onSelectItem(node.item)
    }

    /// Kicks off (if not already in flight) an async fetch of `node`'s
    /// children under the currently-selected mode, then reloads just
    /// that node once the result arrives. Safe to call repeatedly (a
    /// second call while one is already running for the same node is a
    /// no-op) — used both by the outline view's own lazy-expansion path
    /// and directly by tests.
    func fetchChildrenIfNeeded(_ node: HierarchyNode) {
        guard node.children == nil else {
            return
        }
        let key = ObjectIdentifier(node)
        guard !inFlightFetches.contains(key) else {
            return
        }
        inFlightFetches.insert(key)
        let mode = modes[selectedModeIndex]
        Task { [weak self] in
            guard let self else {
                return
            }
            let fetched = (try? await mode.fetchChildren(node.item)) ?? []
            self.inFlightFetches.remove(key)
            node.children = fetched.map(HierarchyNode.init)
            self.outlineView.reloadItem(node, reloadChildren: true)
        }
    }
}

extension HierarchyViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? HierarchyNode else {
            return rootNodes.count
        }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? HierarchyNode else {
            return false
        }
        // Not-yet-fetched nodes are optimistically expandable so the
        // disclosure triangle shows up before the first fetch completes.
        return node.children == nil || !(node.children ?? []).isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? HierarchyNode else {
            return rootNodes[index]
        }
        return node.children?[index] ?? HierarchyNode(item: node.item)
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? HierarchyNode else {
            return
        }
        fetchChildrenIfNeeded(node)
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("hierarchy.cell")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingMiddle
            textField.font = .systemFont(ofSize: 12)
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.textField = textField
            cell.addSubview(textField)
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        guard let node = item as? HierarchyNode else {
            return cell
        }
        let detail = node.item.detail.map { " — \($0)" } ?? ""
        cell.textField?.stringValue = "\(node.item.name)\(detail)"
        // A distinct accessibility label naming the node's symbol kind as
        // a word ("function", "class", ...), matching the vocabulary
        // `CodeAccessibilityAnnotation` uses, so
        // VoiceOver announces what kind of hierarchy node this is rather
        // than only its bare name (SPEC 14).
        cell.textField?.setAccessibilityLabel(
            "\(node.item.kind.displayName) \(node.item.name)\(detail)"
        )
        return cell
    }
}

/// Presents a `HierarchyViewController` as a sheet (mirroring
/// `CommandPaletteController`'s `NSPanel`/`show(asSheetFor:)` pattern),
/// so "Show Call Hierarchy"/"Show Type Hierarchy" are genuinely
/// reachable from the Command Palette rather than existing only as an
/// untriggerable class.
@MainActor
final class HierarchyPanelController: NSWindowController {
    init(title: String, root: ValidatedHierarchyItem, modes: [HierarchyViewController.Mode], onSelectItem: @escaping (ValidatedHierarchyItem) -> Void) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isReleasedWhenClosed = false

        let controller = HierarchyViewController(root: root, modes: modes, onSelectItem: { [weak panel] item in
            onSelectItem(item)
            if let panel, let sheetParent = panel.sheetParent {
                sheetParent.endSheet(panel)
            }
        })
        panel.contentViewController = controller

        super.init(window: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show(asSheetFor parent: NSWindow) {
        guard let window else {
            return
        }
        parent.beginSheet(window)
    }
}
