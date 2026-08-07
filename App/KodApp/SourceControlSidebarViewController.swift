import AppKit
import GitCore

/// The Source Control sidebar surface (SPEC 9.1): file status grouped
/// into conflicted, staged, unstaged, untracked, and ignored sections.
/// Selecting a file requests a diff (unified against whichever of
/// HEAD/index/working-tree applies to that group) without changing Git
/// state — this sidebar only ever reads a `GitStatusSnapshot` handed to
/// it by `GitWorkspaceCoordinator`. Structurally mirrors
/// `ProblemsViewController`: an `NSOutlineView` grouping leaf rows under
/// section headers, entirely headlessly testable via its public API.
@MainActor
final class SourceControlSidebarViewController: NSViewController {
    struct FileSelection: Equatable {
        let path: String
        let originalPath: String?
        let target: GitDiffTarget
        let isUntracked: Bool
    }

    /// One section of the sidebar, in fixed display order.
    struct Section: Equatable {
        enum Kind: Equatable {
            case conflicted
            case staged
            case unstaged
            case untracked
            case ignored
        }

        let kind: Kind
        let title: String
        let entries: [GitStatusEntry]

        var diffTarget: GitDiffTarget {
            switch kind {
            case .conflicted, .unstaged, .untracked:
                return .workingTreeVsIndex
            case .staged:
                return .indexVsHead
            case .ignored:
                return .workingTreeVsIndex
            }
        }
    }

    private let onSelectFile: (FileSelection) -> Void
    private let statusLabel = NSTextField(labelWithString: Localized.string("No repository.", comment: "Status text shown in the Source Control sidebar when the workspace has no Git repository"))
    private let outlineView = NSOutlineView()
    private var sections: [Section] = []

    init(onSelectFile: @escaping (FileSelection) -> Void) {
        self.onSelectFile = onSelectFile
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let container = NSView()

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.identifier = NSUserInterfaceItemIdentifier("sourceControl.status")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sourceControl.results"))
        column.title = Localized.string("Source Control", comment: "Column title for the Source Control sidebar's outline view")
        outlineView.addTableColumn(column)
        outlineView.headerView = nil
        outlineView.identifier = NSUserInterfaceItemIdentifier("sourceControl.outline")
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(handleSelection)
        outlineView.rowSizeStyle = .default

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(statusLabel)
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        view = container
    }

    /// Replaces the displayed snapshot. `nil` means either "not yet
    /// loaded" or "this workspace is not a Git repository" — both render
    /// as an empty, inert sidebar (SPEC 9: Git integration is optional).
    func update(snapshot: GitStatusSnapshot?) {
        guard let snapshot else {
            sections = []
            outlineView.reloadData()
            statusLabel.stringValue = Localized.string("No repository.", comment: "Status text shown in the Source Control sidebar when the workspace has no Git repository")
            return
        }

        var builtSections: [Section] = []
        if !snapshot.conflicted.isEmpty {
            builtSections.append(
                Section(
                    kind: .conflicted,
                    title: Localized.string("Merge Conflicts", comment: "Source Control sidebar section title for merge-conflicted files"),
                    entries: snapshot.conflicted
                )
            )
        }
        if !snapshot.staged.isEmpty {
            builtSections.append(
                Section(
                    kind: .staged,
                    title: Localized.string("Staged Changes", comment: "Source Control sidebar section title for staged changes"),
                    entries: snapshot.staged
                )
            )
        }
        if !snapshot.unstaged.isEmpty {
            builtSections.append(
                Section(
                    kind: .unstaged,
                    title: Localized.string("Changes", comment: "Source Control sidebar section title for unstaged changes"),
                    entries: snapshot.unstaged
                )
            )
        }
        if !snapshot.untracked.isEmpty {
            builtSections.append(
                Section(
                    kind: .untracked,
                    title: Localized.string("Untracked Files", comment: "Source Control sidebar section title for untracked files"),
                    entries: snapshot.untracked
                )
            )
        }
        if !snapshot.ignored.isEmpty {
            builtSections.append(
                Section(
                    kind: .ignored,
                    title: Localized.string("Ignored Files", comment: "Source Control sidebar section title for ignored files"),
                    entries: snapshot.ignored
                )
            )
        }
        sections = builtSections
        outlineView.reloadData()

        let changeCount = snapshot.entries.count
        statusLabel.stringValue = changeCount == 0
            ? Localized.string("No changes.", comment: "Status text shown in the Source Control sidebar when there are no changes")
            : Localized.string(
                "\(changeCount) change\(changeCount == 1 ? "" : "s").",
                comment: "Status text summarizing the number of changes in the Source Control sidebar"
            )
    }

    @objc
    private func handleSelection(_ sender: Any?) {
        let row = outlineView.selectedRow
        guard row >= 0, let entry = outlineView.item(atRow: row) as? GitStatusEntry else {
            return
        }
        guard let section = sections.first(where: { $0.entries.contains(entry) }) else {
            return
        }
        onSelectFile(
            FileSelection(
                path: entry.path,
                originalPath: entry.originalPath,
                target: section.diffTarget,
                isUntracked: entry.isUntracked
            )
        )
    }
}

extension SourceControlSidebarViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else {
            return sections.count
        }
        guard let section = item as? Section else {
            return 0
        }
        return section.entries.count
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is Section
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else {
            return sections[index]
        }
        guard let section = item as? Section, section.entries.indices.contains(index) else {
            return NSObject()
        }
        return section.entries[index]
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("sourceControl.cell")
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

        if let section = item as? Section {
            cell.textField?.stringValue = "\(section.title) (\(section.entries.count))"
            cell.textField?.font = .boldSystemFont(ofSize: 12)
        } else if let entry = item as? GitStatusEntry {
            let renameSuffix = entry.originalPath.map { " ← \($0)" } ?? ""
            cell.textField?.stringValue = "\(entry.path)\(renameSuffix)"
            cell.textField?.font = .systemFont(ofSize: 12)
            // A dedicated accessibility label spelling the change kind
            // out as a full word ("Added"/"Modified"/"Deleted"/
            // "Renamed"/"Copied"/"Conflicted"/...) rather than relying on
            // the section grouping or any color alone (SPEC 14).
            cell.textField?.setAccessibilityLabel(
                "\(entry.changeDescription): \(entry.path)\(renameSuffix)"
            )
        }
        return cell
    }
}
