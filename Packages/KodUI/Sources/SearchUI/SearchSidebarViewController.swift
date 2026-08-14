import AppKit
import DiagnosticsCore
import SearchCore

/// The Search sidebar surface (SPEC 8.2/5.1): a workspace-wide text search
/// with streaming, file-grouped results. Selecting a match calls
/// `onSelectMatch` so the owning `WorkspaceViewController` can open it in
/// the active editor group with the match selected.
@MainActor
public final class SearchSidebarViewController: NSViewController {
    public struct MatchSelection: Equatable, Sendable {
        public let relativePath: String
        public let utf8Range: Range<Int>
    }

    private let root: URL
    private let onSelectMatch: (MatchSelection) -> Void
    private var searcher: WorkspaceTextSearcher?
    private let makeSearcher: @MainActor () throws -> WorkspaceTextSearcher
    /// Runs each search stream. The workspace session supplies a runner
    /// that tracks the task, so an in-flight search is cancelled and
    /// awaited by session shutdown instead of outliving the workspace.
    private let runSearchTask: @MainActor (
        @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never>
    private var engineUnavailableReason: String?
    private let reportSearchHealth: @MainActor (String?) -> Void
    /// Shared, app-lifetime bounded diagnostics log (SPEC 15): the search
    /// engine failing to initialize, or a running search failing
    /// mid-stream, are both already-existing, already user-visible
    /// (`statusLabel`) failure paths — recorded here too so they survive
    /// past the current search session for the Diagnostics viewer/
    /// support bundle. Never logs the search pattern itself.
    private let diagnosticsLog: BoundedEventLog

    private let searchField = NSSearchField()
    private let matchCaseButton = NSButton(
        checkboxWithTitle: searchUIStrings.string("Case", comment: "Checkbox toggling case-sensitive workspace search"),
        target: nil,
        action: nil
    )
    private let wholeWordButton = NSButton(
        checkboxWithTitle: searchUIStrings.string("Word", comment: "Checkbox toggling whole-word matching in workspace search"),
        target: nil,
        action: nil
    )
    private let regexButton = NSButton(
        checkboxWithTitle: searchUIStrings.string("Regex", comment: "Checkbox toggling regular-expression matching in workspace search"),
        target: nil,
        action: nil
    )
    private let includeHiddenButton = NSButton(
        checkboxWithTitle: searchUIStrings.string("Hidden", comment: "Checkbox toggling inclusion of hidden files in workspace search"),
        target: nil,
        action: nil
    )
    private let includeIgnoredButton = NSButton(
        checkboxWithTitle: searchUIStrings.string("Ignored", comment: "Checkbox toggling inclusion of ignored files in workspace search"),
        target: nil,
        action: nil
    )
    private let includeGlobField = NSTextField()
    private let excludeGlobField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let outlineView = NSOutlineView()

    private var fileResults: [SearchFileResult] = []
    private var queryVersion = 0
    private var searchTask: Task<Void, Never>?

    public init(
        root: URL,
        diagnosticsLog: BoundedEventLog = BoundedEventLog(),
        makeSearcher: @escaping @MainActor () throws -> WorkspaceTextSearcher = {
            try WorkspaceTextSearcher()
        },
        runSearchTask: @escaping @MainActor (
            @escaping @MainActor @Sendable () async -> Void
        ) -> Task<Void, Never> = { operation in
            Task { @MainActor in await operation() }
        },
        reportSearchHealth: @escaping @MainActor (String?) -> Void = { _ in },
        onSelectMatch: @escaping (MatchSelection) -> Void
    ) {
        self.root = root
        self.diagnosticsLog = diagnosticsLog
        self.makeSearcher = makeSearcher
        self.runSearchTask = runSearchTask
        self.reportSearchHealth = reportSearchHealth
        self.onSelectMatch = onSelectMatch
        var unavailableReason: String?
        do {
            self.searcher = try makeSearcher()
            self.engineUnavailableReason = nil
        } catch {
            self.searcher = nil
            let reason = searchUIStrings.string(
                "Search is unavailable: \(String(describing: error)).",
                comment: "Status text shown when the workspace search engine fails to initialize"
            )
            self.engineUnavailableReason = reason
            unavailableReason = reason
        }
        super.init(nibName: nil, bundle: nil)
        if let unavailableReason {
            Task {
                await diagnosticsLog.record(
                    subsystem: .search,
                    level: .warning,
                    message: searchUIStrings.string("Workspace search engine failed to initialize", comment: "Diagnostics log message recorded when the workspace text search engine fails to start"),
                    context: [
                        DiagnosticContextField(name: "workspaceRoot", category: .fullPath, value: root.path),
                        DiagnosticContextField(name: "reason", category: .diagnosticMessage, value: unavailableReason)
                    ]
                )
            }
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    deinit {
        searchTask?.cancel()
    }

    public override func loadView() {
        let container = NSView()

        searchField.placeholderString = searchUIStrings.string("Search Workspace", comment: "Placeholder text in the workspace search field")
        searchField.identifier = NSUserInterfaceItemIdentifier("search.field")
        searchField.target = self
        searchField.action = #selector(optionsChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        for button in [matchCaseButton, wholeWordButton, regexButton, includeHiddenButton, includeIgnoredButton] {
            button.target = self
            button.action = #selector(optionsChanged)
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        matchCaseButton.identifier = NSUserInterfaceItemIdentifier("search.matchCase")
        wholeWordButton.identifier = NSUserInterfaceItemIdentifier("search.wholeWord")
        regexButton.identifier = NSUserInterfaceItemIdentifier("search.regex")
        includeHiddenButton.identifier = NSUserInterfaceItemIdentifier("search.includeHidden")
        includeIgnoredButton.identifier = NSUserInterfaceItemIdentifier("search.includeIgnored")

        let optionsStack = NSStackView(views: [matchCaseButton, wholeWordButton, regexButton])
        optionsStack.orientation = .horizontal
        optionsStack.spacing = 8
        optionsStack.translatesAutoresizingMaskIntoConstraints = false

        let visibilityStack = NSStackView(views: [includeHiddenButton, includeIgnoredButton])
        visibilityStack.orientation = .horizontal
        visibilityStack.spacing = 8
        visibilityStack.translatesAutoresizingMaskIntoConstraints = false

        includeGlobField.placeholderString = searchUIStrings.string("Include (e.g. *.swift)", comment: "Placeholder text for the include-glob filter field in workspace search")
        includeGlobField.identifier = NSUserInterfaceItemIdentifier("search.includeGlob")
        includeGlobField.target = self
        includeGlobField.action = #selector(optionsChanged)
        includeGlobField.translatesAutoresizingMaskIntoConstraints = false

        excludeGlobField.placeholderString = searchUIStrings.string("Exclude (e.g. Generated/**)", comment: "Placeholder text for the exclude-glob filter field in workspace search")
        excludeGlobField.identifier = NSUserInterfaceItemIdentifier("search.excludeGlob")
        excludeGlobField.target = self
        excludeGlobField.action = #selector(optionsChanged)
        excludeGlobField.translatesAutoresizingMaskIntoConstraints = false

        let globStack = NSStackView(views: [includeGlobField, excludeGlobField])
        globStack.orientation = .horizontal
        globStack.distribution = .fillEqually
        globStack.spacing = 8
        globStack.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.identifier = NSUserInterfaceItemIdentifier("search.status")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        if let engineUnavailableReason {
            statusLabel.stringValue = engineUnavailableReason
            statusLabel.textColor = .systemRed
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("search.results"))
        column.title = searchUIStrings.string("Results", comment: "Column title for the workspace search results outline view")
        outlineView.addTableColumn(column)
        outlineView.headerView = nil
        outlineView.identifier = NSUserInterfaceItemIdentifier("search.outline")
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

        container.addSubview(searchField)
        container.addSubview(optionsStack)
        container.addSubview(visibilityStack)
        container.addSubview(globStack)
        container.addSubview(statusLabel)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            optionsStack.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            optionsStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),

            visibilityStack.topAnchor.constraint(equalTo: optionsStack.bottomAnchor, constant: 6),
            visibilityStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),

            globStack.topAnchor.constraint(equalTo: visibilityStack.bottomAnchor, constant: 6),
            globStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            globStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            statusLabel.topAnchor.constraint(equalTo: globStack.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        view = container
    }

    /// Gives the search field first-responder focus, e.g. when the sidebar
    /// is revealed via Command-Shift-F.
    public func focusSearchField() {
        view.window?.makeFirstResponder(searchField)
    }

    @objc
    private func optionsChanged(_ sender: Any?) {
        runSearch()
    }

    @objc
    private func handleSelection(_ sender: Any?) {
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) else {
            return
        }
        if let match = item as? SelectedMatch {
            onSelectMatch(
                MatchSelection(relativePath: match.relativePath, utf8Range: match.range.utf8Range)
            )
        }
    }

    private func runSearch() {
        queryVersion += 1
        let version = queryVersion
        let pattern = searchField.stringValue

        fileResults = []
        outlineView.reloadData()

        guard !pattern.isEmpty else {
            statusLabel.stringValue = engineUnavailableReason ?? ""
            return
        }
        let searcher: WorkspaceTextSearcher
        do {
            if let existing = self.searcher {
                searcher = existing
            } else {
                let created = try makeSearcher()
                self.searcher = created
                engineUnavailableReason = nil
                searcher = created
            }
        } catch {
            let reason = String(describing: error)
            engineUnavailableReason = searchUIStrings.string(
                "Search is unavailable: \(reason).",
                comment: "Status text shown when the workspace search engine fails to initialize"
            )
            statusLabel.stringValue = engineUnavailableReason ?? ""
            statusLabel.textColor = .systemRed
            return
        }

        let options = SearchOptions(
            matchCase: matchCaseButton.state == .on,
            wholeWord: wholeWordButton.state == .on,
            useRegex: regexButton.state == .on,
            includeHidden: includeHiddenButton.state == .on,
            includeIgnored: includeIgnoredButton.state == .on,
            includeGlobs: Self.splitGlobs(includeGlobField.stringValue),
            excludeGlobs: Self.splitGlobs(excludeGlobField.stringValue)
        )
        let query = SearchQuery(pattern: pattern, root: root, options: options, version: version)
        statusLabel.stringValue = searchUIStrings.string("Searching…", comment: "Status label shown while a workspace search is in progress")
        statusLabel.textColor = .secondaryLabelColor

        searchTask?.cancel()
        searchTask = runSearchTask { [weak self] in
            guard let self else {
                return
            }
            do {
                for try await event in await searcher.search(query) {
                    guard version == self.queryVersion else {
                        return
                    }
                    switch event {
                    case .fileResult(let result):
                        self.fileResults.append(result)
                        self.outlineView.reloadData()
                    case .completed(let completion):
                        guard completion.queryVersion == version else {
                            return
                        }
                        self.applyCompletion(completion)
                        self.reportSearchHealth(nil)
                    }
                }
            } catch {
                guard version == self.queryVersion else {
                    return
                }
                self.statusLabel.stringValue = searchUIStrings.string(
                    "Search failed: \(String(describing: error))",
                    comment: "Status label shown when a workspace search fails"
                )
                self.statusLabel.textColor = .systemRed
                self.reportSearchHealth(String(describing: error))
                await self.diagnosticsLog.record(
                    subsystem: .search,
                    level: .warning,
                    message: searchUIStrings.string("Workspace search failed", comment: "Diagnostics log message recorded when a workspace search fails"),
                    context: [
                        DiagnosticContextField(name: "workspaceRoot", category: .fullPath, value: self.root.path),
                        DiagnosticContextField(name: "reason", category: .diagnosticMessage, value: String(describing: error))
                    ]
                )
            }
        }
    }

    private func applyCompletion(_ completion: SearchCompletion) {
        if completion.matchCount == 0 {
            statusLabel.stringValue = searchUIStrings.string("No results.", comment: "Status label shown when a workspace search finds no matches")
        } else if completion.truncated {
            statusLabel.stringValue = searchUIStrings.string(
                "Showing first \(completion.matchCount) matches (more available).",
                comment: "Status label shown when a workspace search's results were truncated"
            )
        } else {
            statusLabel.stringValue = searchUIStrings.string(
                "\(completion.matchCount) matches in \(completion.matchedFileCount) files.",
                comment: "Status label summarizing a completed workspace search's match/file counts"
            )
        }
        statusLabel.textColor = .secondaryLabelColor
    }

    private static func splitGlobs(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}

/// One navigable leaf row: a specific match range within a specific file.
private final class SelectedMatch {
    let relativePath: String
    let match: SearchMatch
    let range: SearchMatchRange

    init(relativePath: String, match: SearchMatch, range: SearchMatchRange) {
        self.relativePath = relativePath
        self.match = match
        self.range = range
    }
}

extension SearchSidebarViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else {
            return fileResults.count
        }
        guard let fileResult = item as? SearchFileResult else {
            return 0
        }
        return fileResult.matches.reduce(0) { $0 + max(1, $1.ranges.count) }
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SearchFileResult
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else {
            return fileResults[index]
        }
        guard let fileResult = item as? SearchFileResult else {
            return NSObject()
        }

        var remaining = index
        for match in fileResult.matches {
            let rangeCount = max(1, match.ranges.count)
            if remaining < rangeCount {
                let range = match.ranges.indices.contains(remaining)
                    ? match.ranges[remaining]
                    : SearchMatchRange(utf8Range: 0..<0)
                return SelectedMatch(relativePath: fileResult.relativePath, match: match, range: range)
            }
            remaining -= rangeCount
        }
        return NSObject()
    }

    public func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("search.cell")
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

        if let fileResult = item as? SearchFileResult {
            cell.textField?.stringValue = "\(fileResult.relativePath) (\(fileResult.matches.count))"
            cell.textField?.font = .boldSystemFont(ofSize: 12)
            cell.textField?.setAccessibilityLabel(
                searchUIStrings.string(
                    "\(fileResult.relativePath), \(fileResult.matches.count) match\(fileResult.matches.count == 1 ? "" : "es")",
                    comment: "Accessibility label for a search-result file row, naming the file and its match count"
                )
            )
        } else if let selected = item as? SelectedMatch {
            cell.textField?.stringValue = "\(selected.match.lineNumber): \(selected.match.lineText)"
            cell.textField?.font = .systemFont(ofSize: 12)
            cell.textField?.setAccessibilityLabel(
                searchUIStrings.string(
                    "Line \(selected.match.lineNumber): \(selected.match.lineText)",
                    comment: "Accessibility label for a search-result match row, naming the line number and its text"
                )
            )
        }
        return cell
    }
}
