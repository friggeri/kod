import AppKit

/// One entry in the Command Palette: a stable identifier (used as its
/// accessibility identifier), a display title, and the action it runs.
struct PaletteCommand {
    let id: String
    let title: String
    let action: @MainActor () -> Void
}

/// A fuzzy-filterable list of every implemented Phase 3 command, modeled on
/// `QuickOpenPanelController`'s search-field + table-view sheet pattern.
@MainActor
final class CommandPaletteController: NSWindowController {
    private static let contentSize = NSSize(width: 480, height: 320)

    private let commands: [PaletteCommand]
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private var filtered: [PaletteCommand] = []

    init(commands: [PaletteCommand]) {
        self.commands = commands
        self.filtered = commands

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = Localized.string("Command Palette", comment: "Title of the Command Palette panel window")
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = Self.contentSize

        super.init(window: panel)
        let contentViewController = makeContentViewController()
        contentViewController.preferredContentSize = Self.contentSize
        panel.contentViewController = contentViewController
        panel.setContentSize(Self.contentSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show(asSheetFor parent: NSWindow) {
        guard let window else {
            return
        }
        window.setContentSize(Self.contentSize)
        window.contentView?.layoutSubtreeIfNeeded()
        parent.beginSheet(window)
        window.makeFirstResponder(searchField)
        updateResults(for: "")
    }

    private func makeContentViewController() -> NSViewController {
        let controller = NSViewController()
        let container = NSView(frame: NSRect(origin: .zero, size: Self.contentSize))

        searchField.placeholderString = Localized.string("Type a command", comment: "Placeholder text for the Command Palette's search field")
        searchField.identifier = NSUserInterfaceItemIdentifier("commandPalette.search")
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("commandPalette.title"))
        column.title = Localized.string("Command", comment: "Column title for the Command Palette's results table")
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowSizeStyle = .medium
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(selectCurrentResult(_:))
        tableView.identifier = NSUserInterfaceItemIdentifier("commandPalette.results")

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
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: Self.contentSize.width),
            container.heightAnchor.constraint(equalToConstant: Self.contentSize.height)
        ])

        controller.view = container
        return controller
    }

    private func updateResults(for query: String) {
        if query.isEmpty {
            filtered = commands
        } else {
            filtered = commands.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }
        tableView.reloadData()
        if !filtered.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    @objc
    private func selectCurrentResult(_ sender: Any?) {
        guard filtered.indices.contains(tableView.selectedRow),
              let window,
              let parent = window.sheetParent else {
            return
        }

        let command = filtered[tableView.selectedRow]
        parent.endSheet(window)
        command.action()
    }
}

extension CommandPaletteController: NSSearchFieldDelegate {
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
            let next = min(filtered.count - 1, tableView.selectedRow + 1)
            if next >= 0 {
                tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
                tableView.scrollRowToVisible(next)
            }
            return true
        case #selector(NSResponder.moveUp(_:)):
            let previous = max(0, tableView.selectedRow - 1)
            if !filtered.isEmpty {
                tableView.selectRowIndexes(IndexSet(integer: previous), byExtendingSelection: false)
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

extension CommandPaletteController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        filtered.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard filtered.indices.contains(row) else {
            return nil
        }

        let identifier = NSUserInterfaceItemIdentifier("commandPalette.result")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
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

        cell.textField?.stringValue = filtered[row].title
        cell.setAccessibilityIdentifier(filtered[row].id)
        return cell
    }
}
