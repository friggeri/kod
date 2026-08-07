import AppKit
import WorkspaceCore

@MainActor
final class QuickOpenPanelController: NSWindowController {
    private let filenameIndex: FilenameIndex
    private let onSelect: @MainActor (WorkspaceFileEntry) -> Void
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private var results: [FilenameMatch] = []
    private var searchTask: Task<Void, Never>?

    init(
        filenameIndex: FilenameIndex,
        onSelect: @escaping @MainActor (WorkspaceFileEntry) -> Void
    ) {
        self.filenameIndex = filenameIndex
        self.onSelect = onSelect

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 360),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = Localized.string("Quick Open", comment: "Title of the Quick Open panel window")
        panel.isReleasedWhenClosed = false

        super.init(window: panel)
        panel.contentViewController = makeContentViewController()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        searchTask?.cancel()
    }

    func show(asSheetFor parent: NSWindow) {
        guard let window else {
            return
        }
        parent.beginSheet(window)
        window.makeFirstResponder(searchField)
        updateResults(for: "")
    }

    private func makeContentViewController() -> NSViewController {
        let controller = NSViewController()
        let container = NSView()

        searchField.placeholderString = Localized.string("Type a file name or path", comment: "Placeholder text for the Quick Open panel's search field")
        searchField.identifier = NSUserInterfaceItemIdentifier("quickOpen.search")
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("quickOpen.path"))
        column.title = Localized.string("Path", comment: "Column title for the Quick Open panel's results table")
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowSizeStyle = .medium
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(selectCurrentResult(_:))
        tableView.identifier = NSUserInterfaceItemIdentifier("quickOpen.results")

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(searchField)
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        controller.view = container
        return controller
    }

    private func updateResults(for query: String) {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            guard let self else {
                return
            }
            let matches = await filenameIndex.search(query)
            guard !Task.isCancelled else {
                return
            }
            results = matches
            tableView.reloadData()
            if !results.isEmpty {
                tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
        }
    }

    @objc
    private func selectCurrentResult(_ sender: Any?) {
        guard results.indices.contains(tableView.selectedRow),
              let window,
              let parent = window.sheetParent else {
            return
        }

        let entry = results[tableView.selectedRow].entry
        parent.endSheet(window)
        onSelect(entry)
    }
}

extension QuickOpenPanelController: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        updateResults(for: searchField.stringValue)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            selectCurrentResult(nil)
            return true
        case #selector(NSResponder.moveDown(_:)):
            let next = min(results.count - 1, tableView.selectedRow + 1)
            if next >= 0 {
                tableView.selectRowIndexes(
                    IndexSet(integer: next),
                    byExtendingSelection: false
                )
                tableView.scrollRowToVisible(next)
            }
            return true
        case #selector(NSResponder.moveUp(_:)):
            let previous = max(0, tableView.selectedRow - 1)
            if !results.isEmpty {
                tableView.selectRowIndexes(
                    IndexSet(integer: previous),
                    byExtendingSelection: false
                )
                tableView.scrollRowToVisible(previous)
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if let window, let parent = window.sheetParent {
                parent.endSheet(window)
            }
            return true
        default:
            return false
        }
    }
}

extension QuickOpenPanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        results.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard results.indices.contains(row) else {
            return nil
        }

        let identifier = NSUserInterfaceItemIdentifier("quickOpen.result")
        let cell: NSTableCellView
        if let reused = tableView.makeView(
            withIdentifier: identifier,
            owner: self
        ) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingMiddle
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.textField = textField
            cell.addSubview(textField)
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        cell.textField?.stringValue = results[row].entry.relativePath
        return cell
    }
}
