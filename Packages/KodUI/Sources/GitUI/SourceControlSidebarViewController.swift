import AppKit
import GitCore
import KodUIComponents
import SettingsCore
import ThemeCore

/// Read-only Source Control presentation matching VS Code's default groups:
/// Merge Changes, Staged Changes, and Changes (with untracked files mixed in).
@MainActor
public final class SourceControlSidebarViewController: NSViewController {
    public struct FileSelection: Equatable, Sendable {
        public let path: String
        public let originalPath: String?
        public let target: GitDiffTarget
        public let isUntracked: Bool
    }

    struct FileItem: Equatable {
        let entry: GitStatusEntry
        let sectionKind: Section.Kind
        let presentation: GitStatusPresentation
    }

    struct Section: Equatable {
        typealias Kind = GitSourceControlGroup

        let kind: Kind
        let title: String
        let items: [FileItem]

        var entries: [GitStatusEntry] {
            items.map(\.entry)
        }

        var diffTarget: GitDiffTarget {
            kind.diffTarget
        }
    }

    typealias StatusPresentation = GitStatusPresentation

    private let onSelectFile: (FileSelection) -> Void
    private let appearanceCenter: AppearanceCenter
    private var appearanceObservation: SettingsObservation?
    private let statusLabel = NSTextField(
        labelWithString: gitUIStrings.string(
            "No repository.",
            comment: "Status text shown in the Source Control sidebar when the workspace has no Git repository"
        )
    )
    private let outlineView = NSOutlineView()
    private var sections: [Section] = []
    private var collapsedSectionKinds: Set<Section.Kind> = []
    private var gitDecorationColors = BundledThemes.dark.git

    public init(
        appearanceCenter: AppearanceCenter,
        onSelectFile: @escaping (FileSelection) -> Void
    ) {
        self.appearanceCenter = appearanceCenter
        self.onSelectFile = onSelectFile
        super.init(nibName: nil, bundle: nil)
        gitDecorationColors = appearanceCenter.snapshot.theme.git
        appearanceObservation = appearanceCenter.observe {
            [weak self] snapshot in
            self?.applyAppearance(snapshot)
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func loadView() {
        let container = SourceControlRootView()
        container.onEffectiveAppearanceChanged = { [weak self] in
            self?.appearanceCenter.refresh()
        }

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.identifier = NSUserInterfaceItemIdentifier("sourceControl.status")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sourceControl.results"))
        column.title = gitUIStrings.string(
            "Source Control",
            comment: "Column title for the Source Control sidebar's outline view"
        )
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.identifier = NSUserInterfaceItemIdentifier("sourceControl.outline")
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(handleSelection)
        outlineView.rowSizeStyle = .default
        outlineView.indentationPerLevel = 12
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

    /// Replaces the displayed snapshot without changing Git state. Production
    /// passes the coordinator's already-built index; tests may omit it.
    public func update(
        snapshot: GitStatusSnapshot?,
        presentationIndex suppliedIndex: GitStatusPresentationIndex? = nil
    ) {
        captureCollapsedSectionState()

        guard let snapshot else {
            sections = []
            outlineView.reloadData()
            statusLabel.stringValue = gitUIStrings.string(
                "No repository.",
                comment: "Status text shown in the Source Control sidebar when the workspace has no Git repository"
            )
            return
        }

        let presentationIndex = suppliedIndex ?? GitStatusPresentationIndex(snapshot: snapshot)
        sections = GitSourceControlGroup.allCases.compactMap { group in
            let items = presentationIndex.sourceControlItems(in: group).map { item in
                FileItem(
                    entry: item.entry,
                    sectionKind: item.group,
                    presentation: item.presentation
                )
            }
            guard !items.isEmpty else {
                return nil
            }
            return Section(kind: group, title: Self.title(for: group), items: items)
        }
        outlineView.reloadData()
        restoreSectionExpansionState()

        let changeCount = presentationIndex.visibleChangeCount
        if changeCount == 0 {
            statusLabel.stringValue = gitUIStrings.string(
                "No changes.",
                comment: "Status text shown in the Source Control sidebar when there are no changes"
            )
        } else if changeCount == 1 {
            statusLabel.stringValue = gitUIStrings.string(
                "1 change.",
                comment: "Status text shown in the Source Control sidebar when there is exactly one changed file"
            )
        } else {
            statusLabel.stringValue = gitUIStrings.string(
                "\(changeCount) changes.",
                comment: "Status text shown in the Source Control sidebar with the number of changed files"
            )
        }
    }

    public func refreshAppearance() {
        applyAppearance(appearanceCenter.snapshot)
    }

    private func applyAppearance(_ snapshot: AppearanceCenter.Snapshot) {
        gitDecorationColors = snapshot.theme.git
        guard isViewLoaded, outlineView.numberOfRows > 0 else {
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

    static func statusPresentation(
        for entry: GitStatusEntry,
        in sectionKind: Section.Kind
    ) -> StatusPresentation? {
        GitStatusPresentationIndex.sourceControlPresentation(
            for: entry,
            in: sectionKind
        )
    }

    private static func title(for kind: Section.Kind) -> String {
        switch kind {
        case .mergeChanges:
            return gitUIStrings.string(
                "Merge Changes",
                comment: "Source Control sidebar section title for merge-conflicted files"
            )
        case .stagedChanges:
            return gitUIStrings.string(
                "Staged Changes",
                comment: "Source Control sidebar section title for staged changes"
            )
        case .changes:
            return gitUIStrings.string(
                "Changes",
                comment: "Source Control sidebar section title for unstaged and untracked changes"
            )
        }
    }

    private func captureCollapsedSectionState() {
        guard isViewLoaded else {
            return
        }
        for row in 0..<outlineView.numberOfRows {
            guard let section = outlineView.item(atRow: row) as? Section else {
                continue
            }
            if outlineView.isItemExpanded(section) {
                collapsedSectionKinds.remove(section.kind)
            } else {
                collapsedSectionKinds.insert(section.kind)
            }
        }
    }

    private func restoreSectionExpansionState() {
        for index in 0..<outlineView.numberOfChildren(ofItem: nil) {
            guard let section = outlineView.child(index, ofItem: nil) as? Section,
                  !collapsedSectionKinds.contains(section.kind) else {
                continue
            }
            outlineView.expandItem(section)
        }
    }

    @objc
    private func appearanceSettingsDidChange() {
        refreshAppearance()
    }

    @objc
    private func handleSelection(_ sender: Any?) {
        let row = outlineView.clickedRow >= 0
            ? outlineView.clickedRow
            : outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? FileItem else {
            return
        }
        onSelectFile(
            FileSelection(
                path: item.entry.path,
                originalPath: item.entry.originalPath,
                target: item.sectionKind.diffTarget,
                isUntracked: item.entry.isUntracked
            )
        )
    }
}

extension SourceControlSidebarViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else {
            return sections.count
        }
        guard let section = item as? Section else {
            return 0
        }
        return section.items.count
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is Section
    }

    public func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is Section
    }

    public func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is FileItem
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else {
            return sections[index]
        }
        guard let section = item as? Section, section.items.indices.contains(index) else {
            return NSObject()
        }
        return section.items[index]
    }

    public func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        if let section = item as? Section {
            return sectionCell(for: section, in: outlineView)
        }
        guard let item = item as? FileItem else {
            return nil
        }
        return fileCell(for: item, in: outlineView)
    }

    private func sectionCell(
        for section: Section,
        in outlineView: NSOutlineView
    ) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier("sourceControl.sectionCell")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.font = .boldSystemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.textField = label
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.textField?.stringValue = "\(section.title) (\(section.items.count))"
        cell.textField?.setAccessibilityLabel(
            "\(section.title), \(section.items.count)"
        )
        return cell
    }

    private func fileCell(
        for item: FileItem,
        in outlineView: NSOutlineView
    ) -> SourceControlFileCellView {
        let identifier = NSUserInterfaceItemIdentifier("sourceControl.fileCell")
        let cell: SourceControlFileCellView
        if let reused = outlineView.makeView(
            withIdentifier: identifier,
            owner: self
        ) as? SourceControlFileCellView {
            cell = reused
        } else {
            cell = SourceControlFileCellView(frame: .zero)
            cell.identifier = identifier
        }
        cell.configure(
            item: item,
            colors: gitDecorationColors
        )
        return cell
    }
}

@MainActor
private final class SourceControlRootView: NSView {
    var onEffectiveAppearanceChanged: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChanged?()
    }
}

@MainActor
private final class SourceControlFileCellView: NSTableCellView {
    private let fileIconView = MaterialFileIconView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let parentPathLabel = NSTextField(labelWithString: "")
    private let renameContextLabel = NSTextField(labelWithString: "")
    private let statusBadge = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        fileIconView.identifier = NSUserInterfaceItemIdentifier("sourceControl.fileIcon")
        fileIconView.imageScaling = .scaleProportionallyUpOrDown
        fileIconView.setAccessibilityElement(false)
        fileIconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.identifier = NSUserInterfaceItemIdentifier("sourceControl.fileName")
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        parentPathLabel.identifier = NSUserInterfaceItemIdentifier("sourceControl.parentPath")
        parentPathLabel.lineBreakMode = .byTruncatingMiddle
        parentPathLabel.font = .systemFont(ofSize: 11)
        parentPathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        parentPathLabel.setAccessibilityElement(false)

        renameContextLabel.identifier = NSUserInterfaceItemIdentifier("sourceControl.renameContext")
        renameContextLabel.lineBreakMode = .byTruncatingMiddle
        renameContextLabel.font = .systemFont(ofSize: 11)
        renameContextLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        renameContextLabel.setAccessibilityElement(false)

        statusBadge.identifier = NSUserInterfaceItemIdentifier("sourceControl.statusBadge")
        statusBadge.alignment = .right
        statusBadge.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        statusBadge.setAccessibilityElement(false)
        statusBadge.translatesAutoresizingMaskIntoConstraints = false

        let labels = NSStackView(views: [nameLabel, parentPathLabel, renameContextLabel])
        labels.orientation = .horizontal
        labels.alignment = .centerY
        labels.spacing = 5
        labels.translatesAutoresizingMaskIntoConstraints = false

        textField = nameLabel
        addSubview(fileIconView)
        addSubview(labels)
        addSubview(statusBadge)
        NSLayoutConstraint.activate([
            fileIconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            fileIconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            fileIconView.widthAnchor.constraint(equalToConstant: 16),
            fileIconView.heightAnchor.constraint(equalToConstant: 16),

            labels.leadingAnchor.constraint(equalTo: fileIconView.trailingAnchor, constant: 5),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: statusBadge.leadingAnchor, constant: -6),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),

            statusBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            statusBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusBadge.widthAnchor.constraint(equalToConstant: 18)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(
        item: SourceControlSidebarViewController.FileItem,
        colors: GitDecorationColors
    ) {
        let entry = item.entry
        let path = entry.path as NSString
        let parentPath = path.deletingLastPathComponent
        let isDeleted = item.presentation.isDeleted

        fileIconView.fileName = entry.path
        nameLabel.attributedStringValue = styledText(
            path.lastPathComponent,
            color: .labelColor,
            strikethrough: isDeleted,
            font: .systemFont(ofSize: 12)
        )

        parentPathLabel.isHidden = parentPath.isEmpty || parentPath == "."
        parentPathLabel.attributedStringValue = styledText(
            parentPath,
            color: .secondaryLabelColor,
            strikethrough: isDeleted,
            font: .systemFont(ofSize: 11)
        )

        if let originalPath = entry.originalPath {
            renameContextLabel.isHidden = false
            renameContextLabel.attributedStringValue = styledText(
                "\(originalPath) \u{2192} \(entry.path)",
                color: .secondaryLabelColor,
                strikethrough: isDeleted,
                font: .systemFont(ofSize: 11)
            )
        } else {
            renameContextLabel.isHidden = true
            renameContextLabel.stringValue = ""
        }

        statusBadge.stringValue = item.presentation.letter ?? ""
        statusBadge.textColor = ThemeColorAppKitBridge.nsColor(
            colors.color(for: item.presentation.colorRole)
        )
        toolTip = entry.path

        let renameDescription = entry.originalPath.map { "\($0) \u{2192} \(entry.path)" }
        nameLabel.setAccessibilityLabel(
            [item.presentation.accessibilityDescription, entry.path, renameDescription]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
    }

    private func styledText(
        _ string: String,
        color: NSColor,
        strikethrough: Bool,
        font: NSFont
    ) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: font
        ]
        if strikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return NSAttributedString(string: string, attributes: attributes)
    }
}
