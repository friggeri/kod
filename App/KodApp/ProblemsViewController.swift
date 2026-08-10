import AppKit
import LanguageClient

/// The Problems sidebar surface (SPEC 6.4): diagnostics merged by file,
/// most recent per file first. Selecting a diagnostic navigates to it
/// without changing the list. Populated entirely from
/// `textDocument/publishDiagnostics` notifications forwarded by
/// `LanguageServicesCoordinator`; empty and inert whenever no language
/// server is running, per SPEC 6.2 ("Syntax viewing and text search
/// remain available when a server is missing").
@MainActor
final class ProblemsViewController: NSViewController {
    struct DiagnosticSelection {
        let url: URL
        let range: LSPRange
    }

    private let root: URL
    private let onSelectDiagnostic: (DiagnosticSelection) -> Void

    private let statusLabel = NSTextField(labelWithString: Localized.string("No problems.", comment: "Status label shown in the Problems panel when there are no diagnostics"))
    private let outlineView = NSOutlineView()

    private var diagnosticsByFile: [URL: [Diagnostic]] = [:]
    private var orderedFiles: [URL] = []

    init(root: URL, onSelectDiagnostic: @escaping (DiagnosticSelection) -> Void) {
        self.root = root
        self.onSelectDiagnostic = onSelectDiagnostic
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
        statusLabel.identifier = NSUserInterfaceItemIdentifier("problems.status")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("problems.results"))
        column.title = Localized.string("Problems", comment: "Column title for the Problems outline view (header is hidden but title remains accessible)")
        outlineView.addTableColumn(column)
        outlineView.headerView = nil
        outlineView.identifier = NSUserInterfaceItemIdentifier("problems.outline")
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

    /// Replaces the diagnostics known for `url`. An empty array clears any
    /// previously reported problems for that file (e.g. the file was
    /// fixed, closed, or the server republished a clean report).
    func update(url: URL, diagnostics: [Diagnostic]) {
        if diagnostics.isEmpty {
            diagnosticsByFile.removeValue(forKey: url)
            orderedFiles.removeAll { $0 == url }
        } else {
            if diagnosticsByFile[url] == nil {
                orderedFiles.append(url)
            }
            diagnosticsByFile[url] = diagnostics
        }
        outlineView.reloadData()
        updateStatusLabel()
    }

    private func updateStatusLabel() {
        let count = diagnosticsByFile.values.reduce(0) { $0 + $1.count }
        statusLabel.stringValue = count == 0
            ? Localized.string("No problems.", comment: "Status label shown in the Problems panel when there are no diagnostics")
            : Localized.string(
                "\(count) problem\(count == 1 ? "" : "s") in \(orderedFiles.count) file\(orderedFiles.count == 1 ? "" : "s").",
                comment: "Status label summarizing the total diagnostic count across files in the Problems panel"
            )
    }

    private func relativePath(of url: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard targetPath.hasPrefix(prefix) else {
            return url.lastPathComponent
        }
        return String(targetPath.dropFirst(prefix.count))
    }

    @objc
    private func handleSelection(_ sender: Any?) {
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? DiagnosticRow else {
            return
        }
        onSelectDiagnostic(DiagnosticSelection(url: item.url, range: item.diagnostic.range))
    }
}

/// One navigable leaf row: a specific diagnostic within a specific file.
private final class DiagnosticRow {
    let url: URL
    let diagnostic: Diagnostic

    init(url: URL, diagnostic: Diagnostic) {
        self.url = url
        self.diagnostic = diagnostic
    }
}

extension ProblemsViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else {
            return orderedFiles.count
        }
        guard let url = item as? URL else {
            return 0
        }
        return diagnosticsByFile[url]?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is URL
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else {
            return orderedFiles[index]
        }
        guard let url = item as? URL, let diagnostics = diagnosticsByFile[url], diagnostics.indices.contains(index) else {
            return NSObject()
        }
        return DiagnosticRow(url: url, diagnostic: diagnostics[index])
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("problems.cell")
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

        if let url = item as? URL {
            let count = diagnosticsByFile[url]?.count ?? 0
            cell.textField?.stringValue = "\(relativePath(of: url)) (\(count))"
            cell.textField?.font = .boldSystemFont(ofSize: 12)
            cell.textField?.setAccessibilityLabel(
                Localized.string(
                    "\(relativePath(of: url)), \(count) problem\(count == 1 ? "" : "s")",
                    comment: "Accessibility label for a file row in the Problems panel, announcing its path and diagnostic count"
                )
            )
        } else if let row = item as? DiagnosticRow {
            let line = row.diagnostic.range.start.line + 1
            let severity = severitySymbol(row.diagnostic.severity)
            cell.textField?.stringValue = "\(severity) \(line): \(row.diagnostic.message)"
            cell.textField?.font = .systemFont(ofSize: 12)
            // A dedicated accessibility label spelling severity as a full
            // word ("Error"/"Warning"/"Information"/"Hint") rather than
            // the glyph used in the visible text, so VoiceOver never
            // conveys severity through an icon/color alone (SPEC 14).
            cell.textField?.setAccessibilityLabel(
                Localized.string(
                    "\(severityDisplayName(row.diagnostic.severity)), line \(line): \(row.diagnostic.message)",
                    comment: "Accessibility label for a diagnostic row in the Problems panel, spelling out severity as a word rather than an icon/color"
                )
            )
        }
        return cell
    }

    private func severitySymbol(_ severity: DiagnosticSeverity?) -> String {
        switch severity {
        case .error:
            return "⛔️"
        case .warning:
            return "⚠️"
        case .information:
            return "ℹ️"
        case .hint:
            return "💡"
        case nil:
            return "•"
        }
    }

    private func severityDisplayName(_ severity: DiagnosticSeverity?) -> String {
        switch severity {
        case .error:
            return Localized.string("Error", comment: "Accessibility severity word for an error diagnostic")
        case .warning:
            return Localized.string("Warning", comment: "Accessibility severity word for a warning diagnostic")
        case .information:
            return Localized.string("Information", comment: "Accessibility severity word for an informational diagnostic")
        case .hint:
            return Localized.string("Hint", comment: "Accessibility severity word for a hint diagnostic")
        case nil:
            return Localized.string("Problem", comment: "Accessibility severity word used when a diagnostic has no explicit severity")
        }
    }
}
