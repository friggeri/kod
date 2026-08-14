import AppKit
import CodeViewport
import GitCore
import GitUI
import KodUIComponents
import ThemeCore
import WorkspaceCore

/// Owns the workspace Explorer: the outline view, its tree-node cache and
/// entries-by-parent model, the hidden/ignored visibility toggles, the
/// data source/delegate, the contextual menu, and the icon + Git status
/// decoration presentation for every row.
///
/// It consumes the workspace session's discovery and file-change results
/// (already classified elsewhere) and emits typed intents; it starts no
/// scan, owns no watcher, and knows nothing about editor groups, language
/// services or trust.
@MainActor
final class WorkspaceExplorerController: NSObject {
    /// Everything the Explorer can ask the workspace shell to do. The
    /// Explorer never performs these itself — it has no session, no
    /// editor groups and no Git process.
    enum Intent {
        /// A file row was clicked and should be opened in the active
        /// editor group.
        case openFile(WorkspaceFileEntry)
        /// The hidden/ignored reveal toggles changed; discovery must be
        /// restarted with these options.
        case changeVisibility(WorkspaceDiscoveryOptions)
    }

    var onIntent: ((Intent) -> Void)?

    /// Live tree model: children keyed by their parent's relative path
    /// (`""` for the workspace root).
    var entriesByParent: [String: [WorkspaceFileEntry]] = [:]

    let outlineView = NSOutlineView()

    private var nodeCache: [String: WorkspaceTreeNode] = [:]
    private let statusLabel = NSTextField(
        labelWithString: Localized.string(
            "Discovering files...",
            comment: "Status label shown in the workspace Explorer while the initial file scan is in progress"
        )
    )
    private let showHiddenFilesButton = NSButton(
        checkboxWithTitle: Localized.string("Hidden", comment: "Explorer checkbox that reveals hidden files"),
        target: nil,
        action: nil
    )
    private let showIgnoredFilesButton = NSButton(
        checkboxWithTitle: Localized.string("Ignored", comment: "Explorer checkbox that reveals Git-ignored files"),
        target: nil,
        action: nil
    )

    /// Resolves the Git decoration for a row. Supplied by the workspace
    /// shell so the Explorer never reaches into the Git coordinator's
    /// lifetime.
    private let gitDecoration: (String, Bool) -> GitExplorerDecoration?
    /// Current discovery options, read (never written) to decide whether a
    /// live-updated entry belongs in the tree.
    private let discoveryOptions: () -> WorkspaceDiscoveryOptions
    private var gitDecorationColors = BundledThemes.dark.git

    init(
        discoveryOptions: @escaping () -> WorkspaceDiscoveryOptions,
        gitDecoration: @escaping (String, Bool) -> GitExplorerDecoration?
    ) {
        self.discoveryOptions = discoveryOptions
        self.gitDecoration = gitDecoration
        super.init()
    }

    // MARK: - View

    func makeView() -> NSView {
        let container = NSView()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("workspace.name"))
        column.title = Localized.string("Files", comment: "Column title for the workspace Explorer's file tree (header is hidden but title remains accessible)")
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .medium
        outlineView.indentationPerLevel = 14
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(handleOutlineClick(_:))
        outlineView.identifier = NSUserInterfaceItemIdentifier("workspace.explorer")
        outlineView.menu = makeContextMenu()
        outlineView.backgroundColor = .clear

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.identifier = NSUserInterfaceItemIdentifier("workspace.discoveryStatus")
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let options = discoveryOptions()
        showHiddenFilesButton.identifier = NSUserInterfaceItemIdentifier("workspace.showHiddenFiles")
        showHiddenFilesButton.target = self
        showHiddenFilesButton.action = #selector(visibilityChanged(_:))
        showHiddenFilesButton.state = options.includeHidden ? .on : .off
        showHiddenFilesButton.controlSize = .small

        showIgnoredFilesButton.identifier = NSUserInterfaceItemIdentifier("workspace.showIgnoredFiles")
        showIgnoredFilesButton.target = self
        showIgnoredFilesButton.action = #selector(visibilityChanged(_:))
        showIgnoredFilesButton.state = options.includeIgnored ? .on : .off
        showIgnoredFilesButton.controlSize = .small

        let footer = NSStackView(views: [statusLabel, showHiddenFilesButton, showIgnoredFilesButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scrollView)
        container.addSubview(footer)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -4),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5)
        ])
        return container
    }

    /// The contextual menu deliberately leaves its items target-less so
    /// they travel the responder chain to the workspace controller, which
    /// owns the Git/blame surface (and is reached identically from the
    /// main menu).
    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(
            withTitle: Localized.string("Show Git Blame", comment: "Explorer context menu item that shows Git blame for the selected file"),
            action: #selector(WorkspaceViewController.showGitBlameForSelectedFile(_:)),
            keyEquivalent: ""
        )
        return menu
    }

    // MARK: - Discovery / live updates

    func applyDiscoveryStatus(_ status: WorkspaceDiscoveryStatus) {
        switch status {
        case .scanning:
            entriesByParent.removeAll()
            nodeCache.removeAll()
            outlineView.reloadData()
            statusLabel.stringValue = Localized.string("Discovering files...", comment: "Status label shown in the workspace Explorer while a file scan is in progress")
        case .completed(let fileCount):
            statusLabel.stringValue = Localized.string("\(fileCount) files", comment: "Status label reporting the total number of discovered files in the workspace Explorer")
        case .failed(let reason):
            statusLabel.stringValue = Localized.string(
                "Discovery failed: \(reason)",
                comment: "Status label shown in the workspace Explorer when the initial file scan fails"
            )
        }
    }

    func apply(_ batch: WorkspaceDiscoveryBatch) {
        for entry in batch.entries {
            let key = Self.parentKey(forRelativePath: entry.relativePath)
            entriesByParent[key, default: []].append(entry)
            nodeCache.removeValue(forKey: entry.relativePath)
        }
        statusLabel.stringValue = "\(batch.discoveredCount) items discovered"
        outlineView.reloadData()
    }

    func addOrUpdate(_ entry: WorkspaceFileEntry) {
        let key = Self.parentKey(forRelativePath: entry.relativePath)
        entriesByParent[key, default: []].removeAll { $0.relativePath == entry.relativePath }
        entriesByParent[key, default: []].append(entry)
        nodeCache.removeValue(forKey: entry.relativePath)
        outlineView.reloadData()
    }

    func removeEntry(relativePath: String) {
        let key = Self.parentKey(forRelativePath: relativePath)
        entriesByParent[key]?.removeAll { $0.relativePath == relativePath }
        nodeCache.removeValue(forKey: relativePath)
        outlineView.reloadData()
    }

    /// Whether a live-updated entry is visible under the *current* reveal
    /// options — a hidden/ignored file only joins the tree once the user
    /// asks for it.
    func shouldInclude(_ entry: WorkspaceFileEntry) -> Bool {
        let options = discoveryOptions()
        return (!entry.isHidden || options.includeHidden)
            && (!entry.isIgnored || options.includeIgnored)
    }

    static func parentKey(forRelativePath relativePath: String) -> String {
        let parent = (relativePath as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent
    }

    // MARK: - Presentation

    func setDecorationColors(_ colors: GitDecorationColors) {
        gitDecorationColors = colors
    }

    /// Repaints only the rows currently on screen: Git status and theme
    /// changes never require rebuilding the tree model.
    func reloadVisibleDecorations() {
        guard outlineView.numberOfRows > 0 else {
            return
        }
        let visibleRows = outlineView.rows(in: outlineView.visibleRect)
        guard visibleRows.location != NSNotFound, visibleRows.length > 0 else {
            return
        }
        outlineView.reloadData(
            forRowIndexes: IndexSet(
                integersIn: visibleRows.location..<(visibleRows.location + visibleRows.length)
            ),
            columnIndexes: IndexSet(integer: 0)
        )
    }

    /// The file a contextual/main-menu command should act on: the
    /// right-clicked row when there is one, otherwise the selected row.
    var actionTargetFileRelativePath: String? {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard let node = outlineView.item(atRow: row) as? WorkspaceTreeNode,
              node.entry.kind == .file else {
            return nil
        }
        return node.entry.relativePath
    }

    func children(of relativePath: String) -> [WorkspaceTreeNode] {
        (entriesByParent[relativePath] ?? [])
            .sorted {
                if $0.kind == .directory, $1.kind != .directory {
                    return true
                }
                if $0.kind != .directory, $1.kind == .directory {
                    return false
                }
                return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
            .map { entry in
                if let cached = nodeCache[entry.relativePath] {
                    return cached
                }
                let node = WorkspaceTreeNode(entry: entry)
                nodeCache[entry.relativePath] = node
                return node
            }
    }

    // MARK: - Actions

    @objc
    private func handleOutlineClick(_ sender: Any?) {
        guard outlineView.clickedRow >= 0,
              let node = outlineView.item(atRow: outlineView.clickedRow) as? WorkspaceTreeNode,
              node.entry.kind != .directory else {
            return
        }
        onIntent?(.openFile(node.entry))
    }

    @objc
    private func visibilityChanged(_ sender: Any?) {
        onIntent?(
            .changeVisibility(
                WorkspaceDiscoveryOptions(
                    includeHidden: showHiddenFilesButton.state == .on,
                    includeIgnored: showIgnoredFilesButton.state == .on
                )
            )
        )
    }
}

extension WorkspaceExplorerController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(
        _ outlineView: NSOutlineView,
        numberOfChildrenOfItem item: Any?
    ) -> Int {
        let relativePath = (item as? WorkspaceTreeNode)?.entry.relativePath ?? ""
        return children(of: relativePath).count
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        child index: Int,
        ofItem item: Any?
    ) -> Any {
        let relativePath = (item as? WorkspaceTreeNode)?.entry.relativePath ?? ""
        return children(of: relativePath)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? WorkspaceTreeNode)?.entry.kind == .directory
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? WorkspaceTreeNode else {
            return nil
        }

        let identifier = NSUserInterfaceItemIdentifier("workspace.fileCell")
        let cell: WorkspaceExplorerCellView
        if let reused = outlineView.makeView(
            withIdentifier: identifier,
            owner: self
        ) as? WorkspaceExplorerCellView {
            cell = reused
        } else {
            cell = WorkspaceExplorerCellView(frame: .zero)
            cell.identifier = identifier
        }

        let displayName = node.entry.url.lastPathComponent
        cell.textField?.stringValue = displayName
        cell.textField?.toolTip = node.entry.relativePath
        cell.textField?.textColor = .labelColor
        cell.statusBadge.stringValue = ""
        cell.statusBadge.isHidden = true

        let decoration = gitDecoration(
            node.entry.relativePath,
            node.entry.kind == .directory
        ) ?? (node.entry.isIgnored ? .ignored : nil)
        if let decoration {
            let color = gitDecorationColors
                .color(for: decoration.presentation.colorRole)
                .nsColor
            cell.textField?.textColor = color
            if let badgeText = decoration.badgeText {
                cell.statusBadge.stringValue = badgeText
                cell.statusBadge.textColor = decoration.indicator == .descendant
                    ? color.withAlphaComponent(color.alphaComponent * 0.65)
                    : color
                cell.statusBadge.isHidden = false
            }
        }
        let materialIconView = cell.imageView as? MaterialFileIconView
        var symbolName: String?
        let kindDescription: String
        switch node.entry.kind {
        case .directory:
            materialIconView?.fileName = nil
            symbolName = "folder"
            kindDescription = Localized.string("folder", comment: "Accessibility kind description for a directory row in the workspace Explorer")
        case .file:
            materialIconView?.fileName = node.entry.relativePath
            if materialIconView == nil {
                cell.imageView?.image = MaterialFileIconProvider.shared.image(
                    forFileName: node.entry.relativePath,
                    appearance: outlineView.effectiveAppearance
                )
            }
            symbolName = nil
            kindDescription = Localized.string("file", comment: "Accessibility kind description for a file row in the workspace Explorer")
        case .symbolicLink:
            materialIconView?.fileName = nil
            symbolName = "link"
            kindDescription = Localized.string("symbolic link", comment: "Accessibility kind description for a symbolic-link row in the workspace Explorer")
        }
        if let symbolName {
            cell.imageView?.image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: nil
            )
        }
        cell.textField?.setAccessibilityLabel(
            [displayName, kindDescription, decoration?.accessibilityDescription]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
        return cell
    }
}

@MainActor
private final class WorkspaceExplorerCellView: NSTableCellView {
    let statusBadge = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let imageView = MaterialFileIconView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setAccessibilityElement(false)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        self.imageView = imageView

        let textField = NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingMiddle
        textField.font = .systemFont(ofSize: NSFont.systemFontSize + 3, weight: .medium)
        textField.translatesAutoresizingMaskIntoConstraints = false
        self.textField = textField

        statusBadge.identifier = NSUserInterfaceItemIdentifier("workspace.gitStatusBadge")
        statusBadge.alignment = .right
        statusBadge.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        statusBadge.setAccessibilityElement(false)
        statusBadge.translatesAutoresizingMaskIntoConstraints = false

        addSubview(imageView)
        addSubview(textField)
        addSubview(statusBadge)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 5),
            textField.trailingAnchor.constraint(lessThanOrEqualTo: statusBadge.leadingAnchor, constant: -5),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            statusBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusBadge.widthAnchor.constraint(equalToConstant: 16)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

final class WorkspaceTreeNode: NSObject {
    let entry: WorkspaceFileEntry

    init(entry: WorkspaceFileEntry) {
        self.entry = entry
    }
}
