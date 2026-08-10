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

    struct FileItem: Equatable {
        let entry: GitStatusEntry
        let sectionKind: Section.Kind
    }

    /// One section of the sidebar, in fixed display order.
    struct Section: Equatable {
        enum Kind: Equatable {
            case conflicted
            case staged
            case unstaged
            case untracked
            case ignored

            var diffTarget: GitDiffTarget {
                switch self {
                case .conflicted, .unstaged, .untracked:
                    return .workingTreeVsIndex
                case .staged:
                    return .indexVsHead
                case .ignored:
                    return .workingTreeVsIndex
                }
            }
        }

        let kind: Kind
        let title: String
        let entries: [GitStatusEntry]

        var diffTarget: GitDiffTarget {
            kind.diffTarget
        }
    }

    struct StatusPresentation: Equatable {
        enum ColorRole: Equatable {
            case added
            case modified
            case deleted
            case untracked
            case conflicted
            case renamed
            case ignored
        }

        let letter: String
        let colorRole: ColorRole
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
        outlineView.backgroundColor = .clear

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
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
        sections.forEach { outlineView.expandItem($0) }

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
        guard row >= 0, let item = outlineView.item(atRow: row) as? FileItem else {
            return
        }
        let entry = item.entry
        onSelectFile(
            FileSelection(
                path: entry.path,
                originalPath: entry.originalPath,
                target: item.sectionKind.diffTarget,
                isUntracked: entry.isUntracked
            )
        )
    }

    static func statusPresentation(
        for entry: GitStatusEntry,
        in sectionKind: Section.Kind
    ) -> StatusPresentation? {
        switch entry.shape {
        case .untracked:
            return StatusPresentation(letter: "U", colorRole: .untracked)
        case .ignored:
            return StatusPresentation(letter: "I", colorRole: .ignored)
        case .unmerged:
            return StatusPresentation(letter: "U", colorRole: .conflicted)
        case .ordinary(let indexStatus, let worktreeStatus),
             .renameOrCopy(let indexStatus, let worktreeStatus, _, _):
            let code = sectionKind == .staged ? indexStatus : worktreeStatus
            guard code != .unmodified else {
                return nil
            }
            let colorRole: StatusPresentation.ColorRole
            switch code {
            case .added:
                colorRole = .added
            case .modified, .typeChanged:
                colorRole = .modified
            case .deleted:
                colorRole = .deleted
            case .renamed, .copied:
                colorRole = .renamed
            case .updatedButUnmerged:
                colorRole = .conflicted
            case .unmodified:
                return nil
            }
            return StatusPresentation(letter: String(code.rawValue), colorRole: colorRole)
        }
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
        return FileItem(entry: section.entries[index], sectionKind: section.kind)
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("sourceControl.cell")
        let cell: SourceControlCellView
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? SourceControlCellView {
            cell = reused
        } else {
            cell = SourceControlCellView(frame: .zero)
            cell.identifier = identifier
        }

        if let section = item as? Section {
            cell.textField?.stringValue = "\(section.title) (\(section.entries.count))"
            cell.textField?.font = .boldSystemFont(ofSize: 12)
            cell.statusBadge.isHidden = true
        } else if let item = item as? FileItem {
            let entry = item.entry
            let renameSuffix = entry.originalPath.map { " ← \($0)" } ?? ""
            cell.textField?.stringValue = "\(entry.path)\(renameSuffix)"
            cell.textField?.font = .systemFont(ofSize: 12)
            if let presentation = Self.statusPresentation(for: entry, in: item.sectionKind) {
                cell.statusBadge.stringValue = presentation.letter
                cell.statusBadge.textColor = presentation.color
                cell.statusBadge.isHidden = false
            } else {
                cell.statusBadge.isHidden = true
            }
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

private final class SourceControlCellView: NSTableCellView {
    let statusBadge = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let pathLabel = NSTextField(labelWithString: "")
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.font = .systemFont(ofSize: 12)
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        textField = pathLabel

        statusBadge.identifier = NSUserInterfaceItemIdentifier("sourceControl.statusBadge")
        statusBadge.alignment = .right
        statusBadge.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        statusBadge.translatesAutoresizingMaskIntoConstraints = false

        addSubview(pathLabel)
        addSubview(statusBadge)
        NSLayoutConstraint.activate([
            pathLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusBadge.leadingAnchor, constant: -6),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            statusBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusBadge.widthAnchor.constraint(equalToConstant: 16)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

private extension SourceControlSidebarViewController.StatusPresentation {
    var color: NSColor {
        switch colorRole {
        case .added, .untracked:
            return .systemGreen
        case .modified:
            return .systemOrange
        case .deleted, .conflicted:
            return .systemRed
        case .renamed:
            return .systemBlue
        case .ignored:
            return .secondaryLabelColor
        }
    }
}
