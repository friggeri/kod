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

    private let searchIconView = NSImageView()
    private let searchField = NSTextField()
    private let clearSearchButton = NSButton()
    private let matchCaseButton = NSButton()
    private let wholeWordButton = NSButton()
    private let regexButton = NSButton()
    private let searchDetailsButton = NSButton()
    private let searchDetailsStack = NSStackView()
    private let includeHiddenButton = NSButton()
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
        searchField.action = #selector(searchTextChanged)
        searchField.isContinuous = true
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 13)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let cell = searchField.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = true
            cell.isScrollable = true
            cell.wraps = false
            cell.lineBreakMode = .byClipping
        }

        searchIconView.image = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        )
        searchIconView.identifier = NSUserInterfaceItemIdentifier("search.icon")
        searchIconView.imageScaling = .scaleProportionallyDown
        searchIconView.contentTintColor = .secondaryLabelColor
        searchIconView.setAccessibilityElement(false)
        searchIconView.translatesAutoresizingMaskIntoConstraints = false

        let clearSearchLabel = searchUIStrings.string(
            "Clear Search",
            comment: "Tooltip and accessibility label for the button that clears workspace search"
        )
        clearSearchButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: clearSearchLabel
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        )
        clearSearchButton.identifier = NSUserInterfaceItemIdentifier("search.clear")
        clearSearchButton.target = self
        clearSearchButton.action = #selector(clearSearch)
        clearSearchButton.bezelStyle = .inline
        clearSearchButton.isBordered = false
        clearSearchButton.imagePosition = .imageOnly
        clearSearchButton.contentTintColor = .secondaryLabelColor
        clearSearchButton.toolTip = clearSearchLabel
        clearSearchButton.setAccessibilityLabel(clearSearchLabel)
        clearSearchButton.translatesAutoresizingMaskIntoConstraints = false
        clearSearchButton.isHidden = true

        configureToggleButton(
            matchCaseButton,
            title: "Aa",
            label: searchUIStrings.string("Match Case", comment: "Tooltip and accessibility label for the case-sensitive search toggle")
        )
        configureToggleButton(
            wholeWordButton,
            title: "ab",
            label: searchUIStrings.string("Match Whole Word", comment: "Tooltip and accessibility label for the whole-word search toggle")
        )
        wholeWordButton.attributedTitle = NSAttributedString(
            string: "ab",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
        )
        configureToggleButton(
            regexButton,
            title: ".*",
            label: searchUIStrings.string("Use Regular Expression", comment: "Tooltip and accessibility label for the regular-expression search toggle")
        )
        configureToggleButton(
            searchDetailsButton,
            title: "...",
            label: searchUIStrings.string("Search Details", comment: "Tooltip and accessibility label for the search-details disclosure button"),
            action: #selector(toggleSearchDetails)
        )
        searchDetailsButton.identifier = NSUserInterfaceItemIdentifier("search.detailsToggle")
        searchDetailsButton.setAccessibilityValue(
            searchUIStrings.string("Collapsed", comment: "Accessibility value for collapsed search details")
        )

        matchCaseButton.identifier = NSUserInterfaceItemIdentifier("search.matchCase")
        wholeWordButton.identifier = NSUserInterfaceItemIdentifier("search.wholeWord")
        regexButton.identifier = NSUserInterfaceItemIdentifier("search.regex")

        let searchOptionsStack = NSStackView(
            views: [clearSearchButton, matchCaseButton, wholeWordButton, regexButton]
        )
        searchOptionsStack.identifier = NSUserInterfaceItemIdentifier("search.options")
        searchOptionsStack.orientation = .horizontal
        searchOptionsStack.alignment = .centerY
        searchOptionsStack.spacing = 4
        searchOptionsStack.translatesAutoresizingMaskIntoConstraints = false

        let searchBar = SearchBarView()
        searchBar.identifier = NSUserInterfaceItemIdentifier("search.bar")
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchBar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        searchBar.addSubview(searchIconView)
        searchBar.addSubview(searchField)
        searchBar.addSubview(searchOptionsStack)

        let searchRow = NSStackView(views: [searchBar, searchDetailsButton])
        searchRow.identifier = NSUserInterfaceItemIdentifier("search.row")
        searchRow.orientation = .horizontal
        searchRow.alignment = .centerY
        searchRow.spacing = 4
        searchRow.translatesAutoresizingMaskIntoConstraints = false

        configureCheckboxButton(
            includeHiddenButton,
            title: searchUIStrings.string(
                "Show Hidden Files",
                comment: "Checkbox that includes hidden files in workspace search"
            )
        )
        includeHiddenButton.identifier = NSUserInterfaceItemIdentifier("search.includeHidden")

        configureFilterField(
            includeGlobField,
            placeholder: searchUIStrings.string("e.g. *.swift", comment: "Placeholder text for the files-to-include glob field"),
            identifier: "search.includeGlob"
        )
        configureFilterField(
            excludeGlobField,
            placeholder: searchUIStrings.string("e.g. Generated/**", comment: "Placeholder text for the files-to-exclude glob field"),
            identifier: "search.excludeGlob"
        )

        let includeLabel = searchDetailsLabel(
            searchUIStrings.string("files to include", comment: "Label above the files-to-include glob field"),
            identifier: "search.includeLabel"
        )
        let excludeLabel = searchDetailsLabel(
            searchUIStrings.string("files to exclude", comment: "Label above the files-to-exclude glob field"),
            identifier: "search.excludeLabel"
        )
        let visibilitySpacer = NSView()
        let visibilityStack = NSStackView(
            views: [includeHiddenButton, visibilitySpacer]
        )
        visibilityStack.orientation = .horizontal
        visibilityStack.alignment = .centerY
        visibilityStack.spacing = 4
        visibilityStack.translatesAutoresizingMaskIntoConstraints = false

        searchDetailsStack.identifier = NSUserInterfaceItemIdentifier("search.details")
        searchDetailsStack.orientation = .vertical
        searchDetailsStack.alignment = .leading
        searchDetailsStack.spacing = 4
        searchDetailsStack.addArrangedSubview(includeLabel)
        searchDetailsStack.addArrangedSubview(includeGlobField)
        searchDetailsStack.setCustomSpacing(8, after: includeGlobField)
        searchDetailsStack.addArrangedSubview(excludeLabel)
        searchDetailsStack.addArrangedSubview(excludeGlobField)
        searchDetailsStack.setCustomSpacing(6, after: excludeGlobField)
        searchDetailsStack.addArrangedSubview(visibilityStack)
        searchDetailsStack.translatesAutoresizingMaskIntoConstraints = false
        searchDetailsStack.isHidden = true

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.identifier = NSUserInterfaceItemIdentifier("search.status")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        if let engineUnavailableReason {
            setStatus(engineUnavailableReason, color: .systemRed)
        } else {
            setStatus("")
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

        let controlsStack = NSStackView(views: [searchRow, searchDetailsStack, statusLabel])
        controlsStack.orientation = .vertical
        controlsStack.alignment = .leading
        controlsStack.spacing = 6
        controlsStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(controlsStack)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            controlsStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            controlsStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            controlsStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            searchRow.widthAnchor.constraint(equalTo: controlsStack.widthAnchor),
            searchBar.heightAnchor.constraint(equalToConstant: 30),
            searchIconView.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor, constant: 8),
            searchIconView.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            searchIconView.widthAnchor.constraint(equalToConstant: 13),
            searchIconView.heightAnchor.constraint(equalToConstant: 13),
            searchField.leadingAnchor.constraint(equalTo: searchIconView.trailingAnchor, constant: 6),
            searchField.trailingAnchor.constraint(equalTo: searchOptionsStack.leadingAnchor, constant: -4),
            searchField.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            searchOptionsStack.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor, constant: -3),
            searchOptionsStack.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),

            clearSearchButton.widthAnchor.constraint(equalToConstant: 18),
            clearSearchButton.heightAnchor.constraint(equalToConstant: 22),
            matchCaseButton.widthAnchor.constraint(equalToConstant: 28),
            wholeWordButton.widthAnchor.constraint(equalToConstant: 28),
            regexButton.widthAnchor.constraint(equalToConstant: 26),
            searchDetailsButton.widthAnchor.constraint(equalToConstant: 28),
            matchCaseButton.heightAnchor.constraint(equalToConstant: 22),
            wholeWordButton.heightAnchor.constraint(equalToConstant: 22),
            regexButton.heightAnchor.constraint(equalToConstant: 22),
            searchDetailsButton.heightAnchor.constraint(equalToConstant: 28),

            searchDetailsStack.widthAnchor.constraint(equalTo: controlsStack.widthAnchor),
            includeGlobField.widthAnchor.constraint(equalTo: searchDetailsStack.widthAnchor),
            excludeGlobField.widthAnchor.constraint(equalTo: searchDetailsStack.widthAnchor),
            visibilityStack.widthAnchor.constraint(equalTo: searchDetailsStack.widthAnchor),
            includeGlobField.heightAnchor.constraint(equalToConstant: 24),
            excludeGlobField.heightAnchor.constraint(equalToConstant: 24),
            includeHiddenButton.heightAnchor.constraint(equalToConstant: 22),

            statusLabel.widthAnchor.constraint(equalTo: controlsStack.widthAnchor),

            scrollView.topAnchor.constraint(equalTo: controlsStack.bottomAnchor, constant: 6),
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
    private func searchTextChanged(_ sender: Any?) {
        updateClearSearchButton()
        runSearch()
    }

    @objc
    private func clearSearch(_ sender: Any?) {
        searchField.stringValue = ""
        updateClearSearchButton()
        runSearch()
        view.window?.makeFirstResponder(searchField)
    }

    @objc
    private func toggleSearchDetails(_ sender: Any?) {
        let isExpanded = searchDetailsButton.state == .on
        searchDetailsStack.isHidden = !isExpanded
        searchDetailsButton.setAccessibilityValue(
            isExpanded
                ? searchUIStrings.string("Expanded", comment: "Accessibility value for expanded search details")
                : searchUIStrings.string("Collapsed", comment: "Accessibility value for collapsed search details")
        )
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
        searchTask?.cancel()
        searchTask = nil

        guard !pattern.isEmpty else {
            setStatus(
                engineUnavailableReason ?? "",
                color: engineUnavailableReason == nil ? .secondaryLabelColor : .systemRed
            )
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
            setStatus(engineUnavailableReason ?? "", color: .systemRed)
            return
        }

        let query = SearchQuery(
            pattern: pattern,
            root: root,
            options: currentSearchOptions,
            version: version
        )
        setStatus(
            searchUIStrings.string("Searching…", comment: "Status label shown while a workspace search is in progress")
        )

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
                self.setStatus(
                    searchUIStrings.string(
                        "Search failed: \(String(describing: error))",
                        comment: "Status label shown when a workspace search fails"
                    ),
                    color: .systemRed
                )
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

    var currentSearchOptions: SearchOptions {
        SearchOptions(
            matchCase: matchCaseButton.state == .on,
            wholeWord: wholeWordButton.state == .on,
            useRegex: regexButton.state == .on,
            includeHidden: includeHiddenButton.state == .on,
            includeIgnored: true,
            includeGlobs: Self.splitGlobs(includeGlobField.stringValue),
            excludeGlobs: Self.splitGlobs(excludeGlobField.stringValue)
        )
    }

    private func applyCompletion(_ completion: SearchCompletion) {
        if completion.matchCount == 0 {
            setStatus(searchUIStrings.string("No results.", comment: "Status label shown when a workspace search finds no matches"))
        } else if completion.truncated {
            setStatus(
                searchUIStrings.string(
                    "Showing first \(completion.matchCount) matches (more available).",
                    comment: "Status label shown when a workspace search's results were truncated"
                )
            )
        } else {
            setStatus(
                searchUIStrings.string(
                    "\(completion.matchCount) matches in \(completion.matchedFileCount) files.",
                    comment: "Status label summarizing a completed workspace search's match/file counts"
                )
            )
        }
    }

    private func configureToggleButton(
        _ button: NSButton,
        title: String,
        label: String,
        action: Selector = #selector(optionsChanged)
    ) {
        button.title = title
        button.target = self
        button.action = action
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func configureCheckboxButton(_ button: NSButton, title: String) {
        button.title = title
        button.target = self
        button.action = #selector(optionsChanged)
        button.setButtonType(.switch)
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func configureFilterField(
        _ field: NSTextField,
        placeholder: String,
        identifier: String
    ) {
        field.placeholderString = placeholder
        field.identifier = NSUserInterfaceItemIdentifier(identifier)
        field.target = self
        field.action = #selector(optionsChanged)
        field.controlSize = .small
        field.font = .systemFont(ofSize: 12)
        field.translatesAutoresizingMaskIntoConstraints = false
    }

    private func searchDetailsLabel(_ title: String, identifier: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.identifier = NSUserInterfaceItemIdentifier(identifier)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func setStatus(_ message: String, color: NSColor = .secondaryLabelColor) {
        statusLabel.stringValue = message
        statusLabel.textColor = color
        statusLabel.isHidden = message.isEmpty
    }

    private func updateClearSearchButton() {
        clearSearchButton.isHidden = searchField.stringValue.isEmpty
    }

    private static func splitGlobs(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}

private final class SearchBarView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
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
