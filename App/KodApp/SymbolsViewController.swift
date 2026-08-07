import AppKit
import LanguageClient

/// The Symbols sidebar surface (SPEC 6.1: "Document symbols and workspace
/// symbols"): a workspace-wide symbol search backed by
/// `workspace/symbol`, capability-gated by whatever the active language
/// server supports. Empty and inert whenever no language server is
/// running or the workspace has no Swift files — syntax viewing and text
/// search never depend on this (SPEC 6.2).
@MainActor
final class SymbolsViewController: NSViewController {
    private let search: (String) async throws -> [WorkspaceSymbolLocation]
    private let onSelectSymbol: (WorkspaceSymbolLocation) -> Void

    private let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let outlineView = NSOutlineView()

    private var results: [WorkspaceSymbolLocation] = []
    private var searchTask: Task<Void, Never>?
    private var queryVersion = 0

    init(
        search: @escaping (String) async throws -> [WorkspaceSymbolLocation],
        onSelectSymbol: @escaping (WorkspaceSymbolLocation) -> Void
    ) {
        self.search = search
        self.onSelectSymbol = onSelectSymbol
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        searchTask?.cancel()
    }

    override func loadView() {
        let container = NSView()

        searchField.placeholderString = Localized.string("Search Symbols", comment: "Placeholder text for the Symbols sidebar's search field")
        searchField.identifier = NSUserInterfaceItemIdentifier("symbols.field")
        searchField.target = self
        searchField.action = #selector(runSearch)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.identifier = NSUserInterfaceItemIdentifier("symbols.status")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("symbols.results"))
        column.title = Localized.string("Symbols", comment: "Column title for the Symbols sidebar's outline view")
        outlineView.addTableColumn(column)
        outlineView.headerView = nil
        outlineView.identifier = NSUserInterfaceItemIdentifier("symbols.outline")
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

        container.addSubview(searchField)
        container.addSubview(statusLabel)
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            statusLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        view = container
    }

    func focusSearchField() {
        view.window?.makeFirstResponder(searchField)
    }

    @objc
    private func runSearch() {
        queryVersion += 1
        let version = queryVersion
        let query = searchField.stringValue

        searchTask?.cancel()
        guard !query.isEmpty else {
            results = []
            outlineView.reloadData()
            statusLabel.stringValue = ""
            return
        }

        statusLabel.stringValue = Localized.string("Searching…", comment: "Status label shown while a symbol search is in progress")
        searchTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let found = try await self.search(query)
                guard version == self.queryVersion else {
                    return
                }
                self.results = found
                self.outlineView.reloadData()
                self.statusLabel.stringValue = found.isEmpty
                    ? Localized.string("No results.", comment: "Status label shown when a symbol search finds no matches")
                    : Localized.string("\(found.count) symbols.", comment: "Status label summarizing the number of symbols found")
            } catch is CancellationError {
                return
            } catch {
                guard version == self.queryVersion else {
                    return
                }
                self.results = []
                self.outlineView.reloadData()
                self.statusLabel.stringValue = Localized.string(
                    "Symbols unavailable: \(String(describing: error)).",
                    comment: "Status label shown when a symbol search fails"
                )
            }
        }
    }

    @objc
    private func handleSelection(_ sender: Any?) {
        let row = outlineView.selectedRow
        guard row >= 0, let symbol = outlineView.item(atRow: row) as? WorkspaceSymbolLocation else {
            return
        }
        onSelectSymbol(symbol)
    }
}

extension SymbolsViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? results.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        results[index]
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("symbols.cell")
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

        guard let symbol = item as? WorkspaceSymbolLocation else {
            return cell
        }
        let container = symbol.containerName.map { "\($0)." } ?? ""
        cell.textField?.stringValue = "\(container)\(symbol.name) — \(symbol.url.lastPathComponent)"
        // A distinct accessibility label spelling out the symbol's kind
        // as a word ("function", "class", ...) rather than only via the
        // visually-displayed name/path, per SPEC 14's "Symbols sidebar
        // ... symbol kind" requirement.
        let containerPhrase = symbol.containerName.map { " in \($0)" } ?? ""
        cell.textField?.setAccessibilityLabel(
            "\(symbol.kind.displayName) \(symbol.name)\(containerPhrase), \(symbol.url.lastPathComponent)"
        )
        return cell
    }
}
