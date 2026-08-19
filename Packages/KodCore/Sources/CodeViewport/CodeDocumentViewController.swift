import AppKit
import FontCore
import SourceIO
import SourceModel
import SyntaxCore
import ThemeCore

@MainActor
public final class CodeDocumentViewController: NSViewController {
    public let snapshot: SourceSnapshot
    public let viewport: CodeViewport

    private let scrollView = NSScrollView()
    private lazy var minimapView = CodeMinimapView(viewport: viewport, scrollView: scrollView)
    private var minimapTrailingConstraint: NSLayoutConstraint?
    private var minimapWidthConstraint: NSLayoutConstraint?
    private let findBar = NSView()
    private let findField = NSSearchField()
    private let matchCaseButton = NSButton(checkboxWithTitle: "Case", target: nil, action: nil)
    private let wholeWordButton = NSButton(checkboxWithTitle: "Word", target: nil, action: nil)
    private let regexButton = NSButton(checkboxWithTitle: "Regex", target: nil, action: nil)
    private let matchCountLabel = NSTextField(labelWithString: "")

    private var findState = FindStateModel()
    private var isFindBarVisible = false
    private var diagnosticMarkers: [CodeMinimapDiagnosticMarker] = []

    public var minimapEnabled = true {
        didSet {
            guard oldValue != minimapEnabled else {
                return
            }
            updateMinimapVisibility()
        }
    }

    private let syntaxEngine: SyntaxEngine
    /// Exposed so tests can `await` the initial parse-and-highlight pass
    /// deterministically instead of polling; production callers never need
    /// to read it.
    public private(set) var highlightingTask: Task<Void, Never>?

    /// Off by default; mirrors `CodeViewport.wordWrapEnabled`.
    public var wordWrapEnabled: Bool {
        get { viewport.wordWrapEnabled }
        set { viewport.wordWrapEnabled = newValue }
    }

    public var theme: KodTheme {
        get { viewport.theme }
        set { viewport.theme = newValue }
    }

    public var fontSettings: FontSettings {
        get { viewport.fontSettings }
        set { viewport.fontSettings = newValue }
    }

    public convenience init(
        snapshot: SourceSnapshot,
        theme: KodTheme = BundledThemes.dark,
        fontSettings: FontSettings = .default,
        syntaxEngine: SyntaxEngine = SyntaxEngine()
    ) {
        self.init(
            snapshot: snapshot,
            syntaxLanguage: SyntaxLanguage.detect(for: snapshot),
            theme: theme,
            fontSettings: fontSettings,
            syntaxEngine: syntaxEngine
        )
    }

    public init(
        snapshot: SourceSnapshot,
        syntaxLanguage: SyntaxLanguage?,
        theme: KodTheme = BundledThemes.dark,
        fontSettings: FontSettings = .default,
        syntaxEngine: SyntaxEngine = SyntaxEngine()
    ) {
        self.snapshot = snapshot
        self.viewport = CodeViewport(
            snapshot: snapshot,
            syntaxLanguage: syntaxLanguage,
            theme: theme,
            fontSettings: fontSettings
        )
        self.syntaxEngine = syntaxEngine
        super.init(nibName: nil, bundle: nil)
        self.viewport.onMinimapInvalidation = { [weak self] invalidation in
            guard let self else {
                return
            }
            if invalidation == .selection {
                self.minimapView.updateSelection(self.viewport.selectedUTF8Range)
            } else if invalidation == .markers {
                self.refreshMinimapMarkers()
            }
            self.minimapView.invalidate(invalidation)
        }
        startSyntaxHighlighting()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        highlightingTask?.cancel()
    }

    /// Parses the snapshot and applies highlight captures, prioritizing
    /// the current viewport before the rest of the file (SPEC 7.1/11.6).
    /// First plain-text paint (already visible by the time this runs)
    /// never waits on this: it only repaints affected lines once captures
    /// arrive. Safety-mode files and files with no compiled grammar are
    /// skipped entirely. Cancelled on `deinit` (tab close, snapshot
    /// change) so no obsolete work lingers, per SPEC 11.6.
    private func startSyntaxHighlighting() {
        guard let language = viewport.language, snapshot.safetyModeReason == nil else {
            return
        }

        let engine = syntaxEngine
        let capturedSnapshot = snapshot
        highlightingTask = Task { @MainActor [weak self] in
            do {
                let tree = try await engine.parse(snapshot: capturedSnapshot, language: language)
                try Task.checkCancellation()
                guard let self else {
                    return
                }
                self.viewport.applySyntaxTree(tree)

                let visibleRange = self.viewport.visibleUTF8Range
                let fullRange = 0..<capturedSnapshot.utf8Count
                let (viewportCaptures, fullCaptures) = try await engine.highlight(
                    tree: tree,
                    viewportByteRange: visibleRange,
                    fullByteRange: fullRange
                )
                try Task.checkCancellation()
                self.viewport.applyLexicalCaptures(
                    viewportCaptures,
                    snapshotVersion: capturedSnapshot.version,
                    layerVersion: 1
                )
                try Task.checkCancellation()
                self.viewport.applyLexicalCaptures(
                    fullCaptures,
                    snapshotVersion: capturedSnapshot.version,
                    layerVersion: 2
                )
            } catch is CancellationError {
                // Superseded by a closed tab, a new snapshot, or a
                // workspace switch; nothing to reconcile.
            } catch {
                // Parse/query failure (e.g. a pathological file tripping
                // a grammar resource limit) never regresses the
                // already-painted plain text: syntax coloring simply does
                // not appear for this file. It is still logged, not
                // silently discarded, so a real regression is visible.
                CodeViewportLog.highlighting.error(
                    "Syntax highlighting failed for \(capturedSnapshot.url.path, privacy: .public) (\(language.rawValue, privacy: .public)): \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    public override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let pathLabel = NSTextField(labelWithString: snapshot.url.path)
        pathLabel.identifier = NSUserInterfaceItemIdentifier("document.path")
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor

        let headerStack = NSStackView(views: [pathLabel])
        headerStack.identifier = NSUserInterfaceItemIdentifier("document.header")
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 6
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        if let safetyModeReason = snapshot.safetyModeReason {
            let safetyLabel = NSTextField(
                labelWithString: SourceRenderingSafetyPolicy
                    .codeViewportDefault
                    .message(for: safetyModeReason)
            )
            safetyLabel.identifier = NSUserInterfaceItemIdentifier("document.safetyMode")
            safetyLabel.textColor = .systemOrange
            headerStack.addArrangedSubview(safetyLabel)
            safetyLabel.widthAnchor.constraint(equalTo: headerStack.widthAnchor).isActive = true
        }

        configureFindBar()
        headerStack.addArrangedSubview(findBar)
        findBar.widthAnchor.constraint(equalTo: headerStack.widthAnchor).isActive = true
        findBar.isHidden = true

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        // Sticky headers are painted relative to the clip view's visible
        // origin, so every bounds change explicitly invalidates the viewport.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
        )
        scrollView.documentView = viewport
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(headerStack)
        container.addSubview(scrollView)
        container.addSubview(minimapView)
        minimapView.translatesAutoresizingMaskIntoConstraints = false

        let minimapTrailing = minimapView.trailingAnchor.constraint(
            equalTo: scrollView.trailingAnchor,
            constant: -verticalScrollerWidth
        )
        let minimapWidth = minimapView.widthAnchor.constraint(equalToConstant: 96)
        minimapTrailingConstraint = minimapTrailing
        minimapWidthConstraint = minimapWidth

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            headerStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            headerStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            pathLabel.widthAnchor.constraint(equalTo: headerStack.widthAnchor),
            scrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            minimapView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            minimapTrailing,
            minimapView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            minimapWidth
        ])

        view = container
        updateMinimapVisibility()
        refreshMinimapMarkers()
    }

    var postsScrollBoundsChanges: Bool {
        scrollView.contentView.postsBoundsChangedNotifications
    }

    @objc
    private func clipViewBoundsDidChange(_ notification: Notification) {
        viewport.needsDisplay = true
        minimapView.viewportDidScroll()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        minimapTrailingConstraint?.constant = -verticalScrollerWidth
        viewport.setMinimumViewportWidth(scrollView.contentSize.width)
        if minimapEnabled {
            minimapWidthConstraint?.constant = CodeMinimapLayout.recommendedWidth(
                containerWidth: view.bounds.width,
                requestedColumns: viewport.minimapMaximumRenderedColumns
            )
        }
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(viewport)
    }

    public var isMinimapVisible: Bool {
        minimapEnabled && isViewLoaded && !minimapView.isHidden
    }

    public var reservedMinimapWidth: CGFloat {
        0
    }

    var activeMinimapMarkers: CodeMinimapMarkers {
        minimapView.currentMarkers
    }

    public func applyDiagnosticMarkers(
        _ markers: [CodeMinimapDiagnosticMarker],
        snapshotVersion: Int
    ) -> Bool {
        guard snapshotVersion == snapshot.version,
              markers.allSatisfy({
                  $0.utf8Range.lowerBound >= 0
                      && $0.utf8Range.upperBound <= snapshot.utf8Count
                      && $0.utf8Range.lowerBound <= $0.utf8Range.upperBound
              }) else {
            return false
        }
        diagnosticMarkers = markers
        refreshMinimapMarkers()
        return true
    }

    public func clearDiagnosticMarkers() {
        diagnosticMarkers = []
        refreshMinimapMarkers()
    }

    private func updateMinimapVisibility() {
        guard isViewLoaded else {
            return
        }
        minimapView.isHidden = !minimapEnabled
        minimapWidthConstraint?.constant = minimapEnabled
            ? CodeMinimapLayout.recommendedWidth(
                containerWidth: view.bounds.width,
                requestedColumns: viewport.minimapMaximumRenderedColumns
            )
            : 0
        if !minimapEnabled {
            minimapView.invalidate(.layout)
        }
        view.needsLayout = true
    }

    private var verticalScrollerWidth: CGFloat {
        guard scrollView.hasVerticalScroller else {
            return 0
        }
        return NSScroller.scrollerWidth(
            for: scrollView.verticalScroller?.controlSize ?? .regular,
            scrollerStyle: scrollView.scrollerStyle
        )
    }

    private func refreshMinimapMarkers() {
        guard isViewLoaded else {
            return
        }
        minimapView.updateMarkerCollections(
            findMatches: isFindBarVisible ? findState.matches.map(\.utf8Range) : [],
            diagnostics: diagnosticMarkers,
            gitChanges: viewport.activeGutterChanges
        )
        minimapView.updateSelection(viewport.selectedUTF8Range)
    }

    // MARK: - Find in File

    public var isFindBarShown: Bool {
        isFindBarVisible
    }

    public func captureFindState() -> FindState {
        FindState(
            query: findField.stringValue,
            options: currentFindOptions(),
            currentMatchIndex: findState.currentMatchIndex,
            isVisible: isFindBarVisible,
            hadKeyboardFocus: isViewLoaded
                && view.window?.firstResponder === findField
        )
    }

    public func restoreFindState(_ state: FindState) {
        loadViewIfNeeded()
        findField.stringValue = state.query
        matchCaseButton.state = state.options.matchCase ? .on : .off
        wholeWordButton.state = state.options.wholeWord ? .on : .off
        regexButton.state = state.options.useRegex ? .on : .off
        isFindBarVisible = state.isVisible
        findBar.isHidden = !state.isVisible
        runFind()
        if let currentMatchIndex = state.currentMatchIndex,
           findState.select(index: currentMatchIndex) != nil {
            applyCurrentMatch()
        }
        if state.hadKeyboardFocus {
            view.window?.makeFirstResponder(findField)
        }
    }

    /// Shows the inline find bar (compiling/highlighting the current query,
    /// if any) or hides it and returns focus to the viewport.
    public func toggleFindBar() {
        if isFindBarVisible {
            hideFindBar()
        } else {
            isFindBarVisible = true
            findBar.isHidden = false
            view.window?.makeFirstResponder(findField)
            runFind()
        }
    }

    private func hideFindBar() {
        guard isFindBarVisible else {
            return
        }
        isFindBarVisible = false
        findBar.isHidden = true
        refreshMinimapMarkers()
        view.window?.makeFirstResponder(viewport)
    }

    // MARK: - Go to Line

    /// Selects and reveals `oneBasedLine`, clamped to the document bounds.
    public func goToLine(_ oneBasedLine: Int) {
        guard snapshot.lineCount > 0 else {
            return
        }
        let lineIndex = max(0, min(oneBasedLine - 1, snapshot.lineCount - 1))
        guard let lineRange = snapshot.utf8RangeForLine(lineIndex) else {
            return
        }
        try? viewport.selectUTF8Range(lineRange)
        viewport.scrollSourceLineToTop(max(0, lineIndex - 3))
        view.window?.makeFirstResponder(viewport)
    }

    // MARK: - Navigation anchors

    /// Captures the current selection and topmost visible line so a
    /// Back/Forward entry can restore this exact view later.
    public func captureNavigationAnchor() -> (selection: Range<Int>?, viewportAnchorLine: Int) {
        (viewport.selectedUTF8Range, viewport.topmostVisibleLine)
    }

    public func restoreNavigationAnchor(selection: Range<Int>?, viewportAnchorLine: Int) {
        try? viewport.selectUTF8Range(selection)
        viewport.scrollSourceLineToTop(viewportAnchorLine)
    }

    // MARK: - Find bar construction

    private func configureFindBar() {
        findBar.identifier = NSUserInterfaceItemIdentifier("document.findBar")

        findField.placeholderString = "Find in File"
        findField.identifier = NSUserInterfaceItemIdentifier("find.query")
        findField.delegate = self
        findField.translatesAutoresizingMaskIntoConstraints = false

        matchCaseButton.identifier = NSUserInterfaceItemIdentifier("find.matchCase")
        wholeWordButton.identifier = NSUserInterfaceItemIdentifier("find.wholeWord")
        regexButton.identifier = NSUserInterfaceItemIdentifier("find.regex")
        for button in [matchCaseButton, wholeWordButton, regexButton] {
            button.target = self
            button.action = #selector(findOptionsChanged(_:))
        }

        let previousButton = NSButton(
            image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous Match")
                ?? NSImage(),
            target: self,
            action: #selector(findPrevious(_:))
        )
        previousButton.identifier = NSUserInterfaceItemIdentifier("find.previous")
        previousButton.bezelStyle = .rounded

        let nextButton = NSButton(
            image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next Match")
                ?? NSImage(),
            target: self,
            action: #selector(findNext(_:))
        )
        nextButton.identifier = NSUserInterfaceItemIdentifier("find.next")
        nextButton.bezelStyle = .rounded

        matchCountLabel.identifier = NSUserInterfaceItemIdentifier("find.matchCount")
        matchCountLabel.font = .systemFont(ofSize: 11)
        matchCountLabel.textColor = .secondaryLabelColor

        let closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Find Bar") ?? NSImage(),
            target: self,
            action: #selector(closeFindBar(_:))
        )
        closeButton.identifier = NSUserInterfaceItemIdentifier("find.close")
        closeButton.bezelStyle = .rounded

        let row = NSStackView(views: [
            findField,
            matchCaseButton,
            wholeWordButton,
            regexButton,
            previousButton,
            nextButton,
            matchCountLabel,
            closeButton
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false

        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: findBar.topAnchor, constant: 4),
            row.leadingAnchor.constraint(equalTo: findBar.leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: findBar.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: findBar.bottomAnchor, constant: -4),
            findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
    }

    @objc
    private func findOptionsChanged(_ sender: Any?) {
        runFind()
    }

    @objc
    private func findNext(_ sender: Any?) {
        selectMatch(offsetBy: 1)
    }

    @objc
    private func findPrevious(_ sender: Any?) {
        selectMatch(offsetBy: -1)
    }

    @objc
    private func closeFindBar(_ sender: Any?) {
        hideFindBar()
    }

    private func currentFindOptions() -> FindOptions {
        FindOptions(
            matchCase: matchCaseButton.state == .on,
            wholeWord: wholeWordButton.state == .on,
            useRegex: regexButton.state == .on
        )
    }

    private func runFind() {
        let query = findField.stringValue
        let outcome = findState.search(
            snapshot: snapshot,
            query: query,
            options: currentFindOptions(),
            anchorUTF8Offset: viewport.selectedUTF8Range?.lowerBound ?? 0
        )
        switch outcome {
        case .empty:
            matchCountLabel.stringValue = ""
            findField.backgroundColor = .textBackgroundColor
            refreshMinimapMarkers()
            return
        case .invalid:
            findField.backgroundColor = .systemRed.withAlphaComponent(0.15)
            matchCountLabel.stringValue = "No Results"
            refreshMinimapMarkers()
            return
        case .noResults:
            findField.backgroundColor = .textBackgroundColor
            matchCountLabel.stringValue = "No Results"
            refreshMinimapMarkers()
            return
        case .matches:
            findField.backgroundColor = .textBackgroundColor
        }
        refreshMinimapMarkers()
        applyCurrentMatch()
    }

    private func selectMatch(offsetBy delta: Int) {
        guard findState.select(offsetBy: delta) != nil else {
            return
        }
        applyCurrentMatch()
    }

    private func applyCurrentMatch() {
        guard let match = findState.currentMatch else {
            return
        }
        try? viewport.selectUTF8Range(match.utf8Range)
        viewport.revealUTF8Offset(match.utf8Range.lowerBound)
        matchCountLabel.stringValue = findState.statusText
    }
}

extension CodeDocumentViewController: NSSearchFieldDelegate {
    public func controlTextDidChange(_ notification: Notification) {
        runFind()
    }

    public func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            selectMatch(offsetBy: 1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            selectMatch(offsetBy: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            selectMatch(offsetBy: -1)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hideFindBar()
            return true
        default:
            return false
        }
    }
}
