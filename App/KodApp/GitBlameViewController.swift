import AppKit
import GitCore

/// The per-line blame display and commit popover (SPEC 9.1: "Per-line
/// blame with author, commit, timestamp, and summary" plus "Commit
/// metadata popover for a blamed line"). Renders one condensed line per
/// blamed source line in a table, and builds a commit popover's content
/// from a selected row. Every piece of text this produces comes from a
/// pure, headlessly-testable formatting method, so
/// `GitBlameViewControllerTests` can assert on exact strings without
/// needing a window or popover to actually appear on screen.
@MainActor
final class GitBlameViewController: NSViewController {
    private(set) var result: GitBlameResult?
    var onSelectLine: (GitBlameLine) -> Void

    private let tableView = NSTableView()

    init(onSelectLine: @escaping (GitBlameLine) -> Void = { _ in }) {
        self.onSelectLine = onSelectLine
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let container = NSView()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("gitBlame.column"))
        column.title = Localized.string("Blame", comment: "Column title for the Git blame gutter table")
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.identifier = NSUserInterfaceItemIdentifier("gitBlame.table")
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(handleSelection)
        tableView.rowSizeStyle = .small

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        view = container
    }

    func update(result: GitBlameResult?) {
        self.result = result
        tableView.reloadData()
    }

    @objc
    private func handleSelection(_ sender: Any?) {
        let row = tableView.selectedRow
        guard row >= 0, let result, result.lines.indices.contains(row) else {
            return
        }
        onSelectLine(result.lines[row])
    }

    /// The condensed gutter string for one blamed line: a short author
    /// name, a short (`yyyy-MM-dd`) author date, and the commit summary
    /// — the same three fields most editors show inline per line,
    /// truncated to keep the gutter narrow.
    static func gutterText(for line: GitBlameLine) -> String {
        if line.commit.isUncommitted {
            return Localized.string("Not committed yet", comment: "Git blame gutter text for a line with no committed history yet")
        }
        let formatter = Self.dateFormatter
        let date = formatter.string(from: line.commit.authorTime)
        return Localized.string(
            "\(line.commit.authorName), \(date) • \(line.commit.summary)",
            comment: "Git blame gutter text showing a line's author, date, and commit summary"
        )
    }

    /// The full commit metadata popover body for a blamed line: author
    /// name/email, author date with its original timezone offset (not
    /// normalized to any particular display timezone, so the popover
    /// shows exactly what the commit itself recorded), commit id, and
    /// summary.
    static func popoverText(for line: GitBlameLine) -> String {
        let commit = line.commit
        if commit.isUncommitted {
            return Localized.string(
                "Uncommitted change\n\(line.filename), line \(line.finalLineNumber)",
                comment: "Git blame popover body for an uncommitted line"
            )
        }
        let shortCommitID = String(commit.commitID.prefix(7))
        return Localized.string(
            """
            \(commit.authorName) <\(commit.authorEmail)>
            \(Self.popoverDateFormatter.string(from: commit.authorTime)) \(commit.authorTimeZone)
            \(shortCommitID) — \(commit.summary)
            """,
            comment: "Git blame popover body showing a commit's author, date, id, and summary"
        )
    }

    /// A full-sentence accessibility label for one blamed line — author,
    /// date, and commit summary in a form that reads naturally as a
    /// single VoiceOver announcement, unlike `gutterText(for:)`'s terse,
    /// visually-compact form.
    static func accessibilityText(for line: GitBlameLine) -> String {
        if line.commit.isUncommitted {
            return Localized.string(
                "Line \(line.finalLineNumber), not committed yet",
                comment: "Accessibility text for an uncommitted Git blame line"
            )
        }
        let date = Self.dateFormatter.string(from: line.commit.authorTime)
        return Localized.string(
            "Line \(line.finalLineNumber), \(line.commit.authorName), \(date): \(line.commit.summary)",
            comment: "Accessibility text for a committed Git blame line, spelling out line number, author, date, and summary"
        )
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static let popoverDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}

extension GitBlameViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        result?.lines.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let result, result.lines.indices.contains(row) else {
            return nil
        }
        let identifier = NSUserInterfaceItemIdentifier("gitBlame.cell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingTail
            textField.font = .systemFont(ofSize: 11)
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.textField = textField
            cell.addSubview(textField)
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.textField?.stringValue = Self.gutterText(for: result.lines[row])
        // A dedicated accessibility label using the same full commit
        // metadata as the popover (author/date/commit summary), so
        // VoiceOver conveys blame information without requiring the
        // popover to be opened first (SPEC 9.1/14).
        cell.textField?.setAccessibilityLabel(Self.accessibilityText(for: result.lines[row]))
        return cell
    }
}
