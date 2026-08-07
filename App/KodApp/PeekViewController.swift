import AppKit
import LanguageClient

/// One durable, navigable Peek result (SPEC: "Peek Definition/References
/// and durable navigation-result surfaces"). "Durable" here means the
/// list itself does not silently disappear or get overwritten by a
/// later, unrelated request — `PeekViewController` only ever replaces
/// its content when explicitly told to via `show(title:results:)`, and
/// every result already carries a validated absolute file URL and range
/// (never a raw, unchecked server response).
struct PeekResult: Equatable {
    let url: URL
    let range: LSPRange
    /// A short, human-readable line of context shown next to the file
    /// name (e.g. the source line the target range starts on), so a
    /// user can tell results apart without opening each one.
    let previewLine: String?

    init(url: URL, range: LSPRange, previewLine: String? = nil) {
        self.url = url
        self.range = range
        self.previewLine = previewLine
    }

    init(navigationTarget: NavigationTarget, previewLine: String? = nil) {
        self.init(url: navigationTarget.url, range: navigationTarget.range, previewLine: previewLine)
    }
}

/// A durable Peek Definition/References/Declaration/Type-Definition/
/// Implementation surface: a simple, always-available list of validated
/// navigation targets the user can select to jump to. Never shows a raw
/// server response directly — every `PeekResult` it displays has already
/// been through `LanguageWorkspaceService`'s URI/range validation
/// (SPEC 6.3).
@MainActor
final class PeekViewController: NSViewController {
    private let onSelect: (PeekResult) -> Void

    private let titleLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private(set) var results: [PeekResult] = []

    init(onSelect: @escaping (PeekResult) -> Void) {
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let container = NSView()

        titleLabel.font = .boldSystemFont(ofSize: 12)
        titleLabel.identifier = NSUserInterfaceItemIdentifier("peek.title")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("peek.results"))
        column.title = Localized.string("Results", comment: "Column title for the Peek panel's results table")
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.identifier = NSUserInterfaceItemIdentifier("peek.table")
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(handleSelection)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(titleLabel)
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        view = container
    }

    /// Replaces the currently-shown results wholesale — the only way
    /// this controller's content ever changes, so a caller (e.g. a
    /// superseded peek request) can never partially or silently
    /// corrupt what's on screen.
    func show(title: String, results: [PeekResult]) {
        self.results = results
        titleLabel.stringValue = results.isEmpty ? "\(title) — No results" : "\(title) (\(results.count))"
        tableView.reloadData()
    }

    @objc
    private func handleSelection(_ sender: Any?) {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard results.indices.contains(row) else {
            return
        }
        onSelect(results[row])
    }
}

extension PeekViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        results.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("peek.cell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
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

        let result = results[row]
        let location = "\(result.url.lastPathComponent):\(result.range.start.line + 1)"
        if let previewLine = result.previewLine, !previewLine.isEmpty {
            cell.textField?.stringValue = "\(location) — \(previewLine.trimmingCharacters(in: .whitespaces))"
        } else {
            cell.textField?.stringValue = location
        }
        return cell
    }
}

/// Presents a `PeekViewController` as a sheet (mirroring
/// `CommandPaletteController`'s `NSPanel`/`show(asSheetFor:)` pattern),
/// so "Peek Definition"/"Peek References" are genuinely reachable from
/// the Command Palette rather than existing only as an untriggerable
/// class.
@MainActor
final class PeekPanelController: NSWindowController {
    private let peekViewController: PeekViewController

    init(title: String, results: [PeekResult], onSelect: @escaping (PeekResult) -> Void) {
        var controller: PeekViewController!
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 280),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isReleasedWhenClosed = false

        controller = PeekViewController(onSelect: { [weak panel] result in
            onSelect(result)
            if let panel, let sheetParent = panel.sheetParent {
                sheetParent.endSheet(panel)
            }
        })
        peekViewController = controller
        panel.contentViewController = controller

        super.init(window: panel)
        controller.show(title: title, results: results)
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
