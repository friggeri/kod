import AppKit
import CodeViewport
import FontCore
import GitCore
import PreviewCore
import SourceModel
import ThemeCore
import WorkspaceCore

/// A pasteboard type carrying an `EditorTabID.rawValue` for in-process tab
/// drag-and-drop reordering.
private let tabPasteboardType = NSPasteboard.PasteboardType("com.kodapp.editorTab")

private final class LocalEventMonitor: @unchecked Sendable {
    private let token: Any

    init?(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) {
        guard let token = NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler) else {
            return nil
        }
        self.token = token
    }

    deinit {
        NSEvent.removeMonitor(token)
    }
}

/// One editor pane: a tab bar (preview vs. pinned tabs, close buttons, drag
/// reordering), a Back/Forward navigation toolbar, split/close affordances,
/// and a content host that swaps in the `CodeDocumentViewController` for the
/// selected tab. Owns one `EditorGroupState` and reports every state change
/// upward so the workspace can persist it.
@MainActor
final class EditorGroupViewController: NSViewController {
    let groupID: EditorGroupID
    private(set) var state: EditorGroupState

    /// Resolves a workspace-relative path to a freshly-loaded snapshot; set
    /// by the owning `WorkspaceViewController`.
    var loadSnapshot: (@MainActor (String) async throws -> SourceSnapshot)?
    /// Reads a workspace-relative path's exact raw bytes, independent of
    /// `SourceSnapshot`'s text-decoding requirement — used only for
    /// SPEC 10.2 image previews, since a PNG/JPEG/GIF/HEIC/TIFF file is
    /// not valid UTF-8 text and `SourceSnapshotLoader` correctly refuses
    /// to load one at all. Set by the owning `WorkspaceViewController`.
    var loadRawData: (@MainActor (String) async throws -> Data)?
    /// Whether the workspace this group belongs to is currently trusted
    /// (`WorkspaceCore.WorkspaceTrustStore`), threaded through to every
    /// built-in preview's link/resource policy (SPEC 10.1) without this
    /// type depending on `WorkspaceCore` trust machinery directly.
    var isWorkspaceTrusted: () -> Bool = { false }
    /// Invoked when a Markdown preview's link click resolves to a local,
    /// same-workspace relative path — set by `WorkspaceViewController` to
    /// actually navigate there.
    var onOpenLocalRelativePath: ((String) -> Void)?
    var onStateChange: ((EditorGroupID, EditorGroupState) -> Void)?
    var onActivate: ((EditorGroupID) -> Void)?
    var onSplit: ((EditorGroupID, SplitOrientation) -> Void)?
    var onCloseGroup: ((EditorGroupID) -> Void)?
    /// Fired whenever a `CodeDocumentViewController` becomes available for
    /// `relativePath` — on first open and again after every reload — so
    /// the owning `WorkspaceViewController` can wire language-service
    /// integration (document sync, semantic tokens) without this type
    /// needing to know anything about `LanguageClient`.
    var onDocumentReady: ((String, CodeDocumentViewController) -> Void)?
    var onActiveDocumentChange: ((CodeDocumentViewController?) -> Void)?

    /// Disables the close-group affordance when this is the only group left.
    var isOnlyGroup = true {
        didSet { closeGroupButton.isEnabled = !isOnlyGroup }
    }

    /// Whether this is the currently-active split group — the one
    /// Command Palette/Quick Open/Go to Line/etc. target, and the one a
    /// newly-split group is created relative to. Kod previously only
    /// tracked this in `WorkspaceViewController.layoutState.activeGroupID`
    /// with no reflection at all back on the group itself, so there was
    /// no way — visual or accessible — to tell which group was active
    /// with more than one group on screen (SPEC 14: "the currently-active
    /// split group must be accessibly distinguishable"). `didSet` updates
    /// both a subtle header-row highlight and an explicit accessibility
    /// label/value, so a VoiceOver user gets the same information a
    /// sighted user would from the highlight.
    var isActive = true {
        didSet {
            guard oldValue != isActive else {
                return
            }
            applyActiveAppearance()
        }
    }

    var wordWrapEnabled = false {
        didSet {
            guard oldValue != wordWrapEnabled else {
                return
            }
            documentControllers.values.forEach { $0.wordWrapEnabled = wordWrapEnabled }
        }
    }

    private let tabBarView = EditorTabBarView(frame: .zero)
    private let headerRow = NSStackView()
    private let backButton: NSButton
    private let forwardButton: NSButton
    private let splitRightButton: NSButton
    private let splitDownButton: NSButton
    private let closeGroupButton: NSButton
    private let previewSourceToggleButton: NSButton
    private let contentHost = NSView()
    private let placeholderLabel = NSTextField(
        labelWithString: Localized.string(
            "Select a file in the Explorer or press Command-P.",
            comment: "Placeholder text shown in an editor group before any tab is open"
        )
    )

    private var documentControllers: [EditorTabID: CodeDocumentViewController] = [:]
    /// The built-in preview (SPEC 10) for a tab whose content matches a
    /// detected `PreviewKind`, built lazily and asynchronously once its
    /// snapshot/raw bytes are available. Never the *only* representation
    /// for a text-based preview (Markdown/JSON/plist) tab — those always
    /// keep a `documentControllers` entry too, so toggling to "Source"
    /// never has to reload anything.
    private var previewControllers: [EditorTabID: PreviewViewController] = [:]
    private var diffControllers: [EditorTabID: GitDiffViewController] = [:]
    /// The detected `PreviewKind` for a tab, cached once at open/reload
    /// time so repeated content-display decisions don't re-sniff bytes.
    private var previewKinds: [EditorTabID: PreviewKind] = [:]
    /// Tabs currently showing their `PreviewViewController` rather than
    /// their `CodeDocumentViewController` — a newly-opened previewable
    /// tab defaults into this set (SPEC 10: previewing is the point),
    /// with an explicit toggle back to "Source". This is transient,
    /// in-memory UI state, not part of `EditorGroupState`'s persisted
    /// model — SPEC 11.7 persists tab/selection/scroll restoration, and a
    /// once-toggled preview/source choice not surviving a relaunch is an
    /// explicit, documented scope limitation rather than a silent gap.
    private var previewModeTabIDs: Set<EditorTabID> = []
    /// Tabs backed by raw binary bytes with no `CodeDocumentViewController`
    /// at all (SPEC 10.2 images: a PNG is not valid UTF-8 text, so there
    /// is no meaningful "Source" view to toggle to).
    private var imageOnlyTabIDs: Set<EditorTabID> = []
    private var loadTask: Task<Void, Never>?
    private var previewBuildTasks: [EditorTabID: Task<Void, Never>] = [:]
    private var previewBuildGenerations: [EditorTabID: Int] = [:]
    private var activationMouseMonitor: LocalEventMonitor?

    init(groupID: EditorGroupID, state: EditorGroupState) {
        self.groupID = groupID
        self.state = state
        backButton = NSButton(
            image: NSImage(
                systemSymbolName: "chevron.left",
                accessibilityDescription: Localized.string("Back", comment: "Accessibility description for the editor group's back-navigation button")
            ) ?? NSImage(),
            target: nil,
            action: nil
        )
        forwardButton = NSButton(
            image: NSImage(
                systemSymbolName: "chevron.right",
                accessibilityDescription: Localized.string("Forward", comment: "Accessibility description for the editor group's forward-navigation button")
            ) ?? NSImage(),
            target: nil,
            action: nil
        )
        splitRightButton = NSButton(
            image: NSImage(
                systemSymbolName: "square.split.2x1",
                accessibilityDescription: Localized.string("Split Right", comment: "Accessibility description for the split-editor-right button")
            ) ?? NSImage(),
            target: nil,
            action: nil
        )
        splitDownButton = NSButton(
            image: NSImage(
                systemSymbolName: "square.split.1x2",
                accessibilityDescription: Localized.string("Split Down", comment: "Accessibility description for the split-editor-down button")
            ) ?? NSImage(),
            target: nil,
            action: nil
        )
        closeGroupButton = NSButton(
            image: NSImage(
                systemSymbolName: "xmark.square",
                accessibilityDescription: Localized.string("Close Group", comment: "Accessibility description for the close-editor-group button")
            ) ?? NSImage(),
            target: nil,
            action: nil
        )
        previewSourceToggleButton = NSButton(
            title: Localized.string("Preview", comment: "Initial title of the editor group's preview/source toggle button"),
            target: nil,
            action: nil
        )
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceSettingsDidChange),
            name: .kodAppearanceSettingsChanged,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        loadTask?.cancel()
        previewBuildTasks.values.forEach { $0.cancel() }
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func appearanceSettingsDidChange() {
        let theme = AppearanceSettings.currentTheme()
        let fontSettings = AppearanceSettings.currentFontSettings()
        for controller in documentControllers.values {
            controller.theme = theme
            controller.fontSettings = fontSettings
        }
    }
    override func loadView() {
        let container = NSView()
        container.identifier = NSUserInterfaceItemIdentifier("editorGroup.\(groupID.rawValue)")

        tabBarView.identifier = NSUserInterfaceItemIdentifier("editorGroup.tabBar")

        backButton.identifier = NSUserInterfaceItemIdentifier("editorGroup.back")
        backButton.bezelStyle = .rounded
        backButton.target = self
        backButton.action = #selector(handleBack)

        forwardButton.identifier = NSUserInterfaceItemIdentifier("editorGroup.forward")
        forwardButton.bezelStyle = .rounded
        forwardButton.target = self
        forwardButton.action = #selector(handleForward)

        splitRightButton.identifier = NSUserInterfaceItemIdentifier("editorGroup.splitRight")
        splitRightButton.bezelStyle = .rounded
        splitRightButton.target = self
        splitRightButton.action = #selector(handleSplitRight)

        splitDownButton.identifier = NSUserInterfaceItemIdentifier("editorGroup.splitDown")
        splitDownButton.bezelStyle = .rounded
        splitDownButton.target = self
        splitDownButton.action = #selector(handleSplitDown)

        closeGroupButton.identifier = NSUserInterfaceItemIdentifier("editorGroup.closeGroup")
        closeGroupButton.bezelStyle = .rounded
        closeGroupButton.target = self
        closeGroupButton.action = #selector(handleCloseGroup)
        closeGroupButton.isEnabled = !isOnlyGroup

        previewSourceToggleButton.identifier = NSUserInterfaceItemIdentifier("editorGroup.previewSourceToggle")
        previewSourceToggleButton.bezelStyle = .rounded
        previewSourceToggleButton.target = self
        previewSourceToggleButton.action = #selector(handleTogglePreviewSource)
        previewSourceToggleButton.isHidden = true
        previewSourceToggleButton.setAccessibilityLabel(Localized.string("Toggle Source and Preview", comment: "Accessibility label for the preview/source toggle button"))

        let toolbar = NSStackView(views: [
            previewSourceToggleButton, backButton, forwardButton, splitRightButton, splitDownButton, closeGroupButton
        ])
        toolbar.orientation = .horizontal
        toolbar.spacing = 4

        headerRow.setViews([tabBarView, toolbar], in: .leading)
        headerRow.identifier = NSUserInterfaceItemIdentifier("editorGroup.header")
        headerRow.orientation = .horizontal
        headerRow.distribution = .fill
        headerRow.spacing = 8
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.wantsLayer = true
        tabBarView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tabBarView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        placeholderLabel.identifier = NSUserInterfaceItemIdentifier("editorGroup.placeholder")
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.centerXAnchor.constraint(equalTo: contentHost.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: contentHost.centerYAnchor)
        ])

        container.addSubview(headerRow)
        container.addSubview(contentHost)
        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            headerRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            headerRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            contentHost.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 4),
            contentHost.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentHost.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        view = container

        // A recognizer on the group competes with NSControl tracking after the
        // view is reparented into an NSSplitView. A local monitor observes the
        // click without participating in gesture recognition or consuming it.
        activationMouseMonitor = LocalEventMonitor(matching: .leftMouseDown) { [weak self] event in
            self?.processActivationMouseDown(event) ?? event
        }

        applyActiveAppearance()
    }

    /// Reflects `isActive` both visually (a faint header-row tint, so
    /// sighted users don't need to guess which group last-clicked
    /// commands like Quick Open/Go to Line/Command Palette will target)
    /// and accessibly (an explicit label/value on the group's root view,
    /// so the same information reaches VoiceOver — see `isActive`'s doc
    /// comment; SPEC 14 explicitly calls out this state must not rely on
    /// the visual highlight alone).
    private func applyActiveAppearance() {
        headerRow.layer?.backgroundColor = isActive
            ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            : NSColor.clear.cgColor
        view.setAccessibilityLabel(Localized.string("Editor group", comment: "Accessibility label for an editor group's root view"))
        view.setAccessibilityValue(
            isActive
                ? Localized.string("Active editor group", comment: "Accessibility value indicating this is the currently active editor group")
                : Localized.string("Inactive editor group", comment: "Accessibility value indicating this editor group is not currently active")
        )
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        refreshTabBar()
        refreshNavigationButtons()
        restoreIfNeeded()
    }

    // MARK: - Opening content

    /// Opens `relativePath` in this group using an already-loaded snapshot
    /// (used by Explorer/Quick Open, which load the snapshot themselves).
    func openTab(relativePath: String, pinned: Bool, snapshot: SourceSnapshot) {
        let tabID = openStateTab(relativePath: relativePath, pinned: pinned)
        diffControllers.removeValue(forKey: tabID)
        let controller = documentController(for: tabID, snapshot: snapshot)
        preparePreviewIfNeeded(tabID: tabID, relativePath: relativePath, snapshot: snapshot)
        showContent(contentController(forTabID: tabID))
        recordCurrentNavigation()
        refreshTabBar()
        refreshNavigationButtons()
        refreshPreviewToggleButton()
        notifyStateChange()
        onDocumentReady?(relativePath, controller)
    }

    func openDiffTab(relativePath: String, diff: GitFileDiff) {
        recordCurrentNavigation()
        let tabID = openStateTab(relativePath: relativePath, pinned: true)
        cancelPreviewBuild(for: tabID)
        let controller = GitDiffViewController()
        controller.update(diff: diff)
        diffControllers[tabID] = controller
        showContent(controller)
        refreshTabBar()
        refreshNavigationButtons()
        refreshPreviewToggleButton()
        notifyStateChange()
    }

    /// Opens `relativePath` (as `openTab(relativePath:pinned:snapshot:)`
    /// does) and additionally selects `utf8Range`, scrolling it into view —
    /// used to land on a specific Workspace Search match in the active
    /// group (SPEC 8.2: "navigation opens the match in the active group
    /// with selection").
    func openTab(
        relativePath: String,
        pinned: Bool,
        snapshot: SourceSnapshot,
        selectingUTF8Range utf8Range: Range<Int>
    ) {
        openTab(relativePath: relativePath, pinned: pinned, snapshot: snapshot)
        // Force layout before scrolling: `CodeViewport.scrollSourceLineToTop`
        // needs a real, laid-out scroll view frame to compute whether/how
        // far to scroll, which a freshly attached view does not have until
        // a layout pass runs.
        currentDocumentController?.view.window?.layoutIfNeeded()
        currentDocumentController?.restoreNavigationAnchor(
            selection: utf8Range,
            viewportAnchorLine: (try? snapshot.position(forUTF8Offset: utf8Range.lowerBound, encoding: .utf8).line) ?? 0
        )
        recordCurrentNavigation()
        notifyStateChange()
    }

    /// Replaces every open tab for `relativePath` with a freshly loaded
    /// snapshot, preserving the nearest stable reading anchor (selection,
    /// viewport line, folds) via `ReadingAnchorReconciler` (SPEC 5.6). A
    /// no-op if no tab for `relativePath` is open in this group.
    func reloadTab(relativePath: String, with newSnapshot: SourceSnapshot) {
        for tab in state.tabs where tab.relativePath == relativePath {
            let previousController = documentControllers[tab.id]
            let reconciledAnchor: ReadingAnchor?
            if let previousController {
                let oldAnchor = previousController.captureNavigationAnchor()
                let anchor = ReadingAnchor(
                    selection: oldAnchor.selection.map(EditorSelection.init),
                    viewportAnchorLine: oldAnchor.viewportAnchorLine,
                    foldedHeaderLines: previousController.viewport.foldedHeaderLinesSnapshot()
                )
                reconciledAnchor = ReadingAnchorReconciler.reconcile(
                    anchor,
                    from: previousController.snapshot,
                    to: newSnapshot
                )
            } else {
                reconciledAnchor = nil
            }

            let newController = CodeDocumentViewController(
                snapshot: newSnapshot,
                theme: AppearanceSettings.currentTheme(),
                fontSettings: AppearanceSettings.currentFontSettings()
            )
            newController.wordWrapEnabled = wordWrapEnabled
            documentControllers[tab.id] = newController
            diffControllers.removeValue(forKey: tab.id)
            preparePreviewIfNeeded(tabID: tab.id, relativePath: relativePath, snapshot: newSnapshot)

            // The new controller's view must actually be attached to the
            // window (via `showContent`) and laid out *before* restoring
            // the reconciled anchor: `scrollSourceLineToTop` needs a real
            // scroll-view frame to compute a meaningful scroll, which a
            // detached, never-laid-out view does not have.
            if state.selectedTabID == tab.id {
                showContent(contentController(forTabID: tab.id))
                newController.view.window?.layoutIfNeeded()
            }

            if let reconciledAnchor {
                newController.restoreNavigationAnchor(
                    selection: reconciledAnchor.selection?.range,
                    viewportAnchorLine: reconciledAnchor.viewportAnchorLine
                )
                newController.viewport.restoreFoldedHeaderLines(reconciledAnchor.foldedHeaderLines)
            }
            onDocumentReady?(relativePath, newController)
        }
    }

    /// Marks every open tab for `relativePath` as a tombstone (deleted or
    /// moved externally). If that tab is currently shown, its content is
    /// replaced with an explicit "no longer available" placeholder rather
    /// than silently leaving stale content on screen.
    func markTombstoned(relativePath: String, reason: TabTombstoneReason) {
        state.markTombstoned(relativePath: relativePath, reason: reason)
        for tab in state.tabs where tab.relativePath == relativePath {
            discardContent(for: tab.id)
            if state.selectedTabID == tab.id {
                showContent(nil)
                showTombstonePlaceholder(relativePath: relativePath)
            }
        }
        refreshTabBar()
        notifyStateChange()
    }

    /// Clears a previously set tombstone (the file reappeared at the same
    /// path). Reloads the tab's content if it is currently shown.
    func clearTombstone(relativePath: String) {
        state.clearTombstone(relativePath: relativePath)
        refreshTabBar()
        if let selectedID = state.selectedTabID,
           state.tabs.first(where: { $0.id == selectedID })?.relativePath == relativePath {
            loadAndShow(tabID: selectedID, restoring: nil)
        }
        notifyStateChange()
    }

    private func showTombstonePlaceholder(relativePath: String) {
        let message = "\((relativePath as NSString).lastPathComponent) is no longer available.\nIt may have been deleted or moved outside Kod."
        let label = NSTextField(wrappingLabelWithString: message)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: contentHost.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: contentHost.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: contentHost.widthAnchor, constant: -40)
        ])
    }

    func selectTab(_ tabID: EditorTabID) {
        guard state.tabs.contains(where: { $0.id == tabID }) else {
            return
        }
        recordCurrentNavigation()
        state.selectedTabID = tabID
        loadAndShow(tabID: tabID, restoring: nil)
        refreshTabBar()
        refreshPreviewToggleButton()
        notifyStateChange()
    }

    func closeTab(_ tabID: EditorTabID) {
        discardContent(for: tabID)
        let stillHasTabs = state.closeTab(tabID)
        if stillHasTabs, let selectedID = state.selectedTabID {
            loadAndShow(tabID: selectedID, restoring: nil)
        } else if !stillHasTabs {
            showContent(nil)
        }
        refreshTabBar()
        refreshNavigationButtons()
        refreshPreviewToggleButton()
        notifyStateChange()
    }

    func pinTab(_ tabID: EditorTabID) {
        state.pin(tabID)
        refreshTabBar()
        notifyStateChange()
    }

    private func moveTab(_ tabID: EditorTabID, toIndex index: Int) {
        state.moveTab(tabID, toIndex: index)
        refreshTabBar()
        notifyStateChange()
    }

    var currentDocumentController: CodeDocumentViewController? {
        guard let selectedTabID = state.selectedTabID, diffControllers[selectedTabID] == nil else {
            return nil
        }
        return documentControllers[selectedTabID]
    }

    func toggleFindBar() {
        currentDocumentController?.toggleFindBar()
    }

    func goToLine(_ oneBasedLine: Int) {
        currentDocumentController?.goToLine(oneBasedLine)
    }

    // MARK: - Back / Forward

    var canGoBack: Bool { state.canGoBack }
    var canGoForward: Bool { state.canGoForward }

    func goBack() {
        handleBack(nil)
    }

    func goForward() {
        handleForward(nil)
    }

    @objc
    private func handleBack(_ sender: Any?) {
        onActivate?(groupID)
        captureLatestAnchorIntoState()
        guard let entry = state.goBack() else {
            return
        }
        applyNavigation(entry)
        refreshTabBar()
        refreshNavigationButtons()
        notifyStateChange()
    }

    @objc
    private func handleForward(_ sender: Any?) {
        onActivate?(groupID)
        captureLatestAnchorIntoState()
        guard let entry = state.goForward() else {
            return
        }
        applyNavigation(entry)
        refreshTabBar()
        refreshNavigationButtons()
        notifyStateChange()
    }

    private func applyNavigation(_ entry: EditorNavigationEntry) {
        let tabID: EditorTabID
        if let existing = state.tabs.first(where: { $0.relativePath == entry.relativePath }) {
            tabID = existing.id
        } else {
            tabID = openStateTab(relativePath: entry.relativePath, pinned: true)
        }
        state.selectedTabID = tabID
        diffControllers.removeValue(forKey: tabID)
        state.current = entry
        loadAndShow(tabID: tabID, restoring: entry)
    }

    @objc
    private func handleSplitRight(_ sender: Any?) {
        onActivate?(groupID)
        onSplit?(groupID, .horizontal)
    }

    @objc
    private func handleSplitDown(_ sender: Any?) {
        onActivate?(groupID)
        onSplit?(groupID, .vertical)
    }

    @objc
    private func handleCloseGroup(_ sender: Any?) {
        onActivate?(groupID)
        onCloseGroup?(groupID)
    }

    func processActivationMouseDown(_ event: NSEvent) -> NSEvent {
        guard let window = view.window, event.windowNumber == window.windowNumber else {
            return event
        }
        let location = view.convert(event.locationInWindow, from: nil)
        guard view.bounds.contains(location) else {
            return event
        }
        onActivate?(groupID)
        return event
    }

    // MARK: - Persisted-state restoration

    private func restoreIfNeeded() {
        guard let selectedID = state.selectedTabID else {
            return
        }
        loadAndShow(tabID: selectedID, restoring: state.current)
    }

    /// Captures the outgoing tab's live selection/scroll position into
    /// `state.current` before persisting or navigating away, without
    /// disturbing the Back/Forward stacks.
    func captureLatestAnchorIntoState() {
        guard let tabID = state.selectedTabID, let controller = documentControllers[tabID] else {
            return
        }
        let anchor = controller.captureNavigationAnchor()
        state.updateCurrentAnchor(
            selection: anchor.selection.map(EditorSelection.init),
            viewportAnchorLine: anchor.viewportAnchorLine
        )
    }

    private func recordCurrentNavigation() {
        guard let tabID = state.selectedTabID,
              let tab = state.tabs.first(where: { $0.id == tabID }),
              let controller = documentControllers[tabID] else {
            return
        }
        let anchor = controller.captureNavigationAnchor()
        let entry = EditorNavigationEntry(
            relativePath: tab.relativePath,
            selection: anchor.selection.map(EditorSelection.init),
            viewportAnchorLine: anchor.viewportAnchorLine
        )
        state.recordNavigation(entry)
    }

    private func openStateTab(relativePath: String, pinned: Bool) -> EditorTabID {
        let previousPaths = Dictionary(uniqueKeysWithValues: state.tabs.map { ($0.id, $0.relativePath) })
        let tabID = state.openTab(relativePath: relativePath, pinned: pinned)
        if let previousPath = previousPaths[tabID], previousPath != relativePath {
            discardContent(for: tabID)
        }
        return tabID
    }

    private func discardContent(for tabID: EditorTabID) {
        cancelPreviewBuild(for: tabID)
        documentControllers.removeValue(forKey: tabID)
        previewControllers.removeValue(forKey: tabID)
        diffControllers.removeValue(forKey: tabID)
        previewKinds.removeValue(forKey: tabID)
        previewModeTabIDs.remove(tabID)
        imageOnlyTabIDs.remove(tabID)
    }

    private func cancelPreviewBuild(for tabID: EditorTabID) {
        previewBuildTasks.removeValue(forKey: tabID)?.cancel()
        previewBuildGenerations[tabID, default: 0] += 1
    }

    private func documentController(for tabID: EditorTabID, snapshot: SourceSnapshot) -> CodeDocumentViewController {
        if let existing = documentControllers[tabID] {
            return existing
        }
        let controller = CodeDocumentViewController(
            snapshot: snapshot,
            theme: AppearanceSettings.currentTheme(),
            fontSettings: AppearanceSettings.currentFontSettings()
        )
        controller.wordWrapEnabled = wordWrapEnabled
        documentControllers[tabID] = controller
        return controller
    }

    private func loadAndShow(tabID: EditorTabID, restoring entry: EditorNavigationEntry?) {
        guard let tab = state.tabs.first(where: { $0.id == tabID }) else {
            return
        }
        if tab.isTombstoned {
            documentControllers.removeValue(forKey: tabID)
            previewControllers.removeValue(forKey: tabID)
            showContent(nil)
            showTombstonePlaceholder(relativePath: tab.relativePath)
            return
        }
        if let diffController = diffControllers[tabID] {
            showContent(diffController)
            refreshPreviewToggleButton()
            return
        }
        if imageOnlyTabIDs.contains(tabID) {
            showContent(previewControllers[tabID])
            refreshPreviewToggleButton()
            return
        }
        if let controller = documentControllers[tabID] {
            showContent(contentController(forTabID: tabID))
            refreshPreviewToggleButton()
            if let entry {
                controller.restoreNavigationAnchor(
                    selection: entry.selection?.range,
                    viewportAnchorLine: entry.viewportAnchorLine
                )
            }
            return
        }

        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self, let loadSnapshot else {
                return
            }
            do {
                let snapshot = try await loadSnapshot(tab.relativePath)
                guard !Task.isCancelled else {
                    return
                }
                let controller = documentController(for: tabID, snapshot: snapshot)
                preparePreviewIfNeeded(tabID: tabID, relativePath: tab.relativePath, snapshot: snapshot)
                showContent(contentController(forTabID: tabID))
                onDocumentReady?(tab.relativePath, controller)
                refreshPreviewToggleButton()
                if let entry {
                    controller.restoreNavigationAnchor(
                        selection: entry.selection?.range,
                        viewportAnchorLine: entry.viewportAnchorLine
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                // `SourceSnapshotLoader` only ever throws here for a file
                // that is not valid text (SPEC 11.4) — which is exactly
                // what a PNG/JPEG/GIF/HEIC/TIFF/SVG image is. Recover by
                // reading its raw bytes and, if they are a recognized
                // image format, showing the SPEC 10.2 image preview
                // instead of leaving the content host blank.
                await self.tryShowImagePreviewAfterSnapshotFailure(tabID: tabID, relativePath: tab.relativePath)
            }
        }
    }

    /// Recovery path for `loadAndShow`'s snapshot-load failure: reads
    /// `relativePath`'s raw bytes independent of any text-decoding
    /// requirement, and — only if they are a recognized image format —
    /// builds and shows an image-only preview tab with no
    /// `CodeDocumentViewController` at all (there is no meaningful
    /// "Source" view for binary image bytes). Any other failure (a
    /// genuinely unsupported/corrupt file) leaves the content host
    /// untouched, exactly as before this method existed.
    private func tryShowImagePreviewAfterSnapshotFailure(tabID: EditorTabID, relativePath: String) async {
        guard let loadRawData else {
            return
        }
        guard let data = try? await loadRawData(relativePath) else {
            return
        }
        let kind = PreviewContentDetector.detect(
            pathExtension: (relativePath as NSString).pathExtension,
            contentPrefix: data.prefix(4_096)
        )
        guard case .image = kind else {
            return
        }
        guard let preview = await PreviewViewController.make(
            kind: kind,
            data: data,
            theme: AppearanceSettings.currentTheme(),
            fontSettings: AppearanceSettings.currentFontSettings(),
            isWorkspaceTrusted: isWorkspaceTrusted
        ) else {
            return
        }
        guard !Task.isCancelled,
              state.tabs.first(where: { $0.id == tabID })?.relativePath == relativePath else {
            return
        }
        cancelPreviewBuild(for: tabID)
        previewControllers[tabID] = preview
        diffControllers.removeValue(forKey: tabID)
        previewKinds[tabID] = kind
        imageOnlyTabIDs.insert(tabID)
        previewModeTabIDs.insert(tabID)
        if state.selectedTabID == tabID {
            showContent(preview)
            refreshPreviewToggleButton()
        }
    }

    /// Detects `relativePath`'s `PreviewKind` from `snapshot`'s already-
    /// decoded bytes (text-based formats only — Markdown and JSON/plist
    /// are always valid UTF-8, so they load through the normal
    /// `SourceSnapshot` path with no special-casing) and, if it matches a
    /// built-in preview format, asynchronously builds its
    /// `PreviewViewController`. A newly-detected previewable tab defaults
    /// into preview mode (SPEC 10: previewing is the point of this
    /// feature); a no-op for tabs whose content isn't a recognized
    /// preview format.
    private func preparePreviewIfNeeded(tabID: EditorTabID, relativePath: String, snapshot: SourceSnapshot) {
        cancelPreviewBuild(for: tabID)
        let pathExtension = (relativePath as NSString).pathExtension
        let kind = PreviewContentDetector.detect(pathExtension: pathExtension, contentPrefix: snapshot.utf8Data.prefix(4_096))
        previewKinds[tabID] = kind
        guard kind != .none else {
            previewControllers.removeValue(forKey: tabID)
            previewModeTabIDs.remove(tabID)
            imageOnlyTabIDs.remove(tabID)
            return
        }
        previewModeTabIDs.insert(tabID)

        let data = snapshot.utf8Data
        let theme = AppearanceSettings.currentTheme()
        let fontSettings = AppearanceSettings.currentFontSettings()
        let trustCheck = isWorkspaceTrusted
        let openLocal = onOpenLocalRelativePath
        let generation = previewBuildGenerations[tabID, default: 0]
        let task = Task { [weak self] in
            guard let self else {
                return
            }
            guard let preview = await PreviewViewController.make(
                kind: kind,
                data: data,
                theme: theme,
                fontSettings: fontSettings,
                isWorkspaceTrusted: trustCheck,
                openLocalRelativePath: openLocal
            ) else {
                return
            }
            guard !Task.isCancelled,
                  self.previewBuildGenerations[tabID] == generation,
                  self.state.tabs.first(where: { $0.id == tabID })?.relativePath == relativePath else {
                return
            }
            self.previewBuildTasks.removeValue(forKey: tabID)
            self.previewControllers[tabID] = preview
            if self.state.selectedTabID == tabID {
                self.showContent(self.contentController(forTabID: tabID))
                self.refreshPreviewToggleButton()
            }
        }
        previewBuildTasks[tabID] = task
    }

    /// Resolves which view controller should currently occupy the
    /// content host for `tabID`: an image-only tab always shows its
    /// preview (there is no source view); a text-based previewable tab
    /// shows its preview or its `CodeDocumentViewController` depending on
    /// `previewModeTabIDs`; everything else shows its
    /// `CodeDocumentViewController` exactly as before this phase.
    private func contentController(forTabID tabID: EditorTabID) -> NSViewController? {
        if let diffController = diffControllers[tabID] {
            return diffController
        }
        if imageOnlyTabIDs.contains(tabID) {
            return previewControllers[tabID]
        }
        if previewModeTabIDs.contains(tabID), let preview = previewControllers[tabID] {
            return preview
        }
        return documentControllers[tabID]
    }

    /// Shows or hides the Source/Preview toggle for the currently
    /// selected tab and keeps its title in sync with which side is
    /// currently displayed. Hidden entirely for tabs with no detected
    /// preview kind, and disabled (but still visible, reading "Preview")
    /// for image-only tabs, where there is no Source side to toggle to.
    private func refreshPreviewToggleButton() {
        guard let tabID = state.selectedTabID,
              diffControllers[tabID] == nil,
              let kind = previewKinds[tabID],
              kind != .none else {
            previewSourceToggleButton.isHidden = true
            return
        }
        previewSourceToggleButton.isHidden = false
        if imageOnlyTabIDs.contains(tabID) {
            previewSourceToggleButton.title = Localized.string("Preview", comment: "Preview/source toggle button title when only a preview is available (image-only tab)")
            previewSourceToggleButton.isEnabled = false
            return
        }
        previewSourceToggleButton.isEnabled = previewControllers[tabID] != nil
        previewSourceToggleButton.title = previewModeTabIDs.contains(tabID)
            ? Localized.string("View Source", comment: "Preview/source toggle button title when currently showing the preview, offering to switch to source")
            : Localized.string("View Preview", comment: "Preview/source toggle button title when currently showing the source, offering to switch to preview")
        previewSourceToggleButton.setAccessibilityValue(
            previewModeTabIDs.contains(tabID)
                ? Localized.string("Showing Preview", comment: "Accessibility value for the preview/source toggle button when a preview is currently shown")
                : Localized.string("Showing Source", comment: "Accessibility value for the preview/source toggle button when source is currently shown")
        )
    }

    @objc
    private func handleTogglePreviewSource(_ sender: Any?) {
        onActivate?(groupID)
        togglePreviewSource(sender)
    }

    /// The real Source/Preview toggle entry point (SPEC 5.7's preview
    /// toggle in the primary open → search → navigate → diagnose → diff
    /// → preview workflow) — shared by the toolbar button's action and
    /// `WorkspaceViewController.togglePreviewSource(_:)`'s main-menu/
    /// keyboard-shortcut wiring, so both paths stay identical by
    /// construction.
    func togglePreviewSource(_ sender: Any?) {
        guard let tabID = state.selectedTabID, !imageOnlyTabIDs.contains(tabID) else {
            return
        }
        if previewModeTabIDs.contains(tabID) {
            previewModeTabIDs.remove(tabID)
        } else {
            previewModeTabIDs.insert(tabID)
        }
        showContent(contentController(forTabID: tabID))
        refreshPreviewToggleButton()
    }

    /// Test-facing wrapper for the Source/Preview toggle action, since
    /// this codebase never synthesizes real button clicks in tests.
    func togglePreviewSourceForTesting() {
        togglePreviewSource(nil)
    }

    /// Test-facing accessor for the tab currently shown for `tabID`
    /// (`.preview` or `.source`), independent of AppKit view hierarchy
    /// introspection.
    enum DisplayedContentKind: Equatable {
        case source
        case preview
        case diff
        case none
    }

    func displayedContentKind(forTabID tabID: EditorTabID) -> DisplayedContentKind {
        if diffControllers[tabID] != nil {
            return .diff
        }
        if imageOnlyTabIDs.contains(tabID) {
            return previewControllers[tabID] == nil ? .none : .preview
        }
        if previewModeTabIDs.contains(tabID), previewControllers[tabID] != nil {
            return .preview
        }
        return documentControllers[tabID] == nil ? .none : .source
    }

    func previewController(forTabID tabID: EditorTabID) -> PreviewViewController? {
        previewControllers[tabID]
    }

    func diffController(forTabID tabID: EditorTabID) -> GitDiffViewController? {
        diffControllers[tabID]
    }

    func previewKind(forTabID tabID: EditorTabID) -> PreviewKind? {
        previewKinds[tabID]
    }

    /// Opens `relativePath` as a preview-only image tab (SPEC 10.2),
    /// creating the tab if it does not already exist. Used by
    /// `WorkspaceViewController` when `SourceSnapshotLoader` has already
    /// failed for this path with `.unsupportedEncoding` (SPEC 11.4: not
    /// valid UTF-8 text) and its raw bytes turned out to be a recognized
    /// image format — this is the one path that lets an image Explorer/
    /// Quick-Open click actually show something instead of the silent
    /// no-op that error previously produced.
    func openImagePreviewTab(relativePath: String, pinned: Bool, kind: PreviewKind, preview: PreviewViewController) {
        let tabID: EditorTabID
        if let existing = state.tabs.first(where: { $0.relativePath == relativePath }) {
            tabID = existing.id
        } else {
            tabID = openStateTab(relativePath: relativePath, pinned: pinned)
        }
        cancelPreviewBuild(for: tabID)
        previewControllers[tabID] = preview
        diffControllers.removeValue(forKey: tabID)
        previewKinds[tabID] = kind
        imageOnlyTabIDs.insert(tabID)
        previewModeTabIDs.insert(tabID)
        state.selectedTabID = tabID
        showContent(preview)
        recordCurrentNavigation()
        refreshTabBar()
        refreshNavigationButtons()
        refreshPreviewToggleButton()
        notifyStateChange()
    }

    private func showContent(_ controller: NSViewController?) {
        children.forEach { child in
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        contentHost.subviews.forEach { $0.removeFromSuperview() }

        guard let controller else {
            contentHost.addSubview(placeholderLabel)
            NSLayoutConstraint.activate([
                placeholderLabel.centerXAnchor.constraint(equalTo: contentHost.centerXAnchor),
                placeholderLabel.centerYAnchor.constraint(equalTo: contentHost.centerYAnchor)
            ])
            onActiveDocumentChange?(nil)
            return
        }

        addChild(controller)
        let contentView = controller.view
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: contentHost.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor)
        ])
        onActiveDocumentChange?(currentDocumentController)
    }

    private func refreshNavigationButtons() {
        backButton.isEnabled = state.canGoBack
        forwardButton.isEnabled = state.canGoForward
    }

    private func notifyStateChange() {
        onStateChange?(groupID, state)
    }

    // MARK: - Tab bar

    private func refreshTabBar() {
        tabBarView.update(
            tabs: state.tabs,
            selectedTabID: state.selectedTabID,
            onSelect: { [weak self] tabID in
                guard let self else { return }
                self.onActivate?(self.groupID)
                self.selectTab(tabID)
            },
            onClose: { [weak self] tabID in
                guard let self else { return }
                self.onActivate?(self.groupID)
                self.closeTab(tabID)
            },
            onPin: { [weak self] tabID in
                guard let self else { return }
                self.onActivate?(self.groupID)
                self.pinTab(tabID)
            },
            onMove: { [weak self] tabID, index in
                guard let self else { return }
                self.onActivate?(self.groupID)
                self.moveTab(tabID, toIndex: index)
            }
        )
    }
}

/// Pure: the accessibility "value" describing one tab's current state
/// (selection, pinned vs. preview, tombstoned) as a short spoken phrase —
/// e.g. "Selected, pinned tab" or "Unavailable, preview tab" — kept
/// separate from `EditorTabChipView` (which is `private`) so
/// `EditorGroupTabAccessibilityTests` can assert on it directly without
/// needing a real view, and so the phrase used in the chip's actual
/// `accessibilityValue()` can never silently drift from what a test
/// verifies (SPEC 14: tabs need "a value/state for pinned vs. preview
/// vs. dirty-external-change/tombstoned" — Kod is strictly read-only, so
/// there is no "dirty/unsaved" tab state to represent here).
func editorTabAccessibilityValue(tab: EditorTab, isSelected: Bool) -> String {
    var parts: [String] = []
    if isSelected {
        parts.append(Localized.string("Selected", comment: "Accessibility value component indicating a tab chip is the currently selected tab"))
    }
    if tab.isTombstoned {
        parts.append(Localized.string("Unavailable", comment: "Accessibility value component indicating a tab chip's file is no longer available"))
    }
    parts.append(
        tab.isPinned
            ? Localized.string("Pinned tab", comment: "Accessibility value component indicating a tab chip is pinned")
            : Localized.string("Preview tab", comment: "Accessibility value component indicating a tab chip is an unpinned preview tab")
    )
    return parts.joined(separator: ", ")
}

/// A horizontally scrolling, fixed-width AppKit collection view gives tabs
/// stable hit targets and sizing while retaining native selection and
/// drag-and-drop behavior.
@MainActor
private final class EditorTabBarView: NSView {
    private static let itemIdentifier = NSUserInterfaceItemIdentifier("editorGroup.tabItem")
    private static let minimumTabWidth: CGFloat = 88

    private let railBackgroundView = NSView()
    private let collectionView = NSCollectionView()
    private var tabs: [EditorTab] = []
    private var selectedTabID: EditorTabID?
    private var onSelect: (EditorTabID) -> Void = { _ in }
    private var onClose: (EditorTabID) -> Void = { _ in }
    private var onPin: (EditorTabID) -> Void = { _ in }
    private var onMove: (EditorTabID, Int) -> Void = { _, _ in }
    private var isApplyingSelection = false
    private var lastLayoutWidth: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        railBackgroundView.wantsLayer = true
        railBackgroundView.layer?.cornerRadius = 16
        railBackgroundView.layer?.masksToBounds = true
        railBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        updateBarAppearance()

        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: 168, height: 32)
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0
        layout.sectionInset = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            EditorTabCollectionItem.self,
            forItemWithIdentifier: Self.itemIdentifier
        )
        collectionView.registerForDraggedTypes([tabPasteboardType])

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(railBackgroundView)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            railBackgroundView.topAnchor.constraint(equalTo: topAnchor),
            railBackgroundView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            railBackgroundView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            railBackgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 32),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 80)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        guard abs(bounds.width - lastLayoutWidth) > 0.5 else {
            return
        }
        lastLayoutWidth = bounds.width
        collectionView.collectionViewLayout?.invalidateLayout()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBarAppearance()
        collectionView.reloadData()
    }

    private func updateBarAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let component: CGFloat = isDark ? 0.20 : 237 / 255
        railBackgroundView.layer?.backgroundColor = NSColor(
            srgbRed: component,
            green: component,
            blue: component,
            alpha: 1
        ).cgColor
    }

    func update(
        tabs: [EditorTab],
        selectedTabID: EditorTabID?,
        onSelect: @escaping (EditorTabID) -> Void,
        onClose: @escaping (EditorTabID) -> Void,
        onPin: @escaping (EditorTabID) -> Void,
        onMove: @escaping (EditorTabID, Int) -> Void
    ) {
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        self.onSelect = onSelect
        self.onClose = onClose
        self.onPin = onPin
        self.onMove = onMove
        collectionView.collectionViewLayout?.invalidateLayout()
        collectionView.reloadData()

        isApplyingSelection = true
        defer { isApplyingSelection = false }
        if let selectedTabID,
           let index = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            collectionView.selectionIndexPaths = [IndexPath(item: index, section: 0)]
            collectionView.scrollToItems(
                at: [IndexPath(item: index, section: 0)],
                scrollPosition: .nearestHorizontalEdge
            )
        } else {
            collectionView.selectionIndexPaths = []
        }
    }
}

@MainActor
extension EditorTabBarView: NSCollectionViewDataSource, @preconcurrency NSCollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        tabs.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> NSSize {
        guard !tabs.isEmpty,
              let scrollView = collectionView.enclosingScrollView else {
            return NSSize(width: 168, height: 32)
        }
        let availableWidth = max(0, scrollView.contentSize.width - 16)
        let tabWidth = max(Self.minimumTabWidth, availableWidth / CGFloat(tabs.count))
        return NSSize(width: tabWidth, height: 32)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        guard tabs.indices.contains(indexPath.item),
              let item = collectionView.makeItem(
                withIdentifier: Self.itemIdentifier,
                for: indexPath
              ) as? EditorTabCollectionItem else {
            return NSCollectionViewItem()
        }
        let tab = tabs[indexPath.item]
        let nextTabIsSelected = tabs.indices.contains(indexPath.item + 1)
            && tabs[indexPath.item + 1].id == selectedTabID
        item.configure(
            tab: tab,
            isSelected: tab.id == selectedTabID,
            showsTrailingSeparator: indexPath.item < tabs.count - 1
                && tab.id != selectedTabID
                && !nextTabIsSelected,
            onSelect: { [weak self] in self?.onSelect(tab.id) },
            onClose: { [weak self] in self?.onClose(tab.id) },
            onPin: { [weak self] in self?.onPin(tab.id) }
        )
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        didSelectItemsAt indexPaths: Set<IndexPath>
    ) {
        guard !isApplyingSelection else {
            return
        }
        guard let index = indexPaths.first?.item, tabs.indices.contains(index) else {
            return
        }
        onSelect(tabs[index].id)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        canDragItemsAt indexPaths: Set<IndexPath>,
        with event: NSEvent
    ) -> Bool {
        indexPaths.count == 1
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        writeItemsAt indexPaths: Set<IndexPath>,
        to pasteboard: NSPasteboard
    ) -> Bool {
        guard let index = indexPaths.first?.item, tabs.indices.contains(index) else {
            return false
        }
        pasteboard.clearContents()
        return pasteboard.setString(tabs[index].id.rawValue, forType: tabPasteboardType)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        guard draggingInfo.draggingPasteboard.string(forType: tabPasteboardType) != nil else {
            return []
        }
        proposedDropOperation.pointee = .before
        return .move
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop draggingInfo: NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        guard let rawValue = draggingInfo.draggingPasteboard.string(forType: tabPasteboardType),
              let sourceIndex = tabs.firstIndex(where: { $0.id.rawValue == rawValue }) else {
            return false
        }
        var destination = min(indexPath.item, tabs.count)
        if sourceIndex < destination {
            destination -= 1
        }
        onMove(tabs[sourceIndex].id, max(0, destination))
        return true
    }
}

@MainActor
private final class EditorTabTitleButton: NSButton {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // NSButton otherwise consumes the mouse sequence, preventing the
        // collection view from recognizing a drag that begins on the title.
        nil
    }
}

@MainActor
private final class EditorTabIconView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
private final class EditorTabContentView: NSStackView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hitView = super.hitTest(point)
        return hitView is NSButton ? hitView : nil
    }
}

@MainActor
private final class EditorTabBackgroundView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
private final class EditorTabCollectionItem: NSCollectionViewItem {
    private static var fileIcons: [String: NSImage] = [:]

    private let titleButton = EditorTabTitleButton(title: "", target: nil, action: nil)
    private let fileIconView = EditorTabIconView()
    private let contentView = EditorTabContentView()
    private let selectionBackgroundView = EditorTabBackgroundView()
    private let pinButton = NSButton(
        image: NSImage(
            systemSymbolName: "pin",
            accessibilityDescription: Localized.string(
                "Pin Tab",
                comment: "Generic accessibility description for the pin-tab image, overridden per-tab below"
            )
        ) ?? NSImage(),
        target: nil,
        action: nil
    )
    private let closeButton = NSButton(
        image: NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: Localized.string(
                "Close Tab",
                comment: "Generic accessibility description for the close-tab image, overridden per-tab below"
            )
        ) ?? NSImage(),
        target: nil,
        action: nil
    )
    private let trailingSeparator = NSView()
    private var tab: EditorTab?
    private var configuredSelection = false
    private var showsTrailingSeparator = false
    private var isHovered = false
    private var hoverTrackingArea: NSTrackingArea?
    private var onSelect: () -> Void = {}
    private var onClose: () -> Void = {}
    private var onPin: () -> Void = {}

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true

        selectionBackgroundView.wantsLayer = true
        selectionBackgroundView.layer?.cornerRadius = 13
        selectionBackgroundView.translatesAutoresizingMaskIntoConstraints = false

        titleButton.bezelStyle = .inline
        titleButton.isBordered = false
        titleButton.setButtonType(.momentaryPushIn)
        titleButton.alignment = .center
        titleButton.lineBreakMode = .byTruncatingMiddle
        titleButton.target = self
        titleButton.action = #selector(handleSelect)
        titleButton.translatesAutoresizingMaskIntoConstraints = false
        titleButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        fileIconView.imageScaling = .scaleProportionallyUpOrDown
        fileIconView.translatesAutoresizingMaskIntoConstraints = false
        fileIconView.setAccessibilityElement(false)

        for button in [pinButton, closeButton] {
            button.bezelStyle = .inline
            button.isBordered = false
            button.imageScaling = .scaleProportionallyDown
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        pinButton.image = pinButton.image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
        )
        closeButton.image = closeButton.image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
        )
        pinButton.target = self
        pinButton.action = #selector(handlePin)
        closeButton.target = self
        closeButton.action = #selector(handleClose)

        contentView.setViews([fileIconView, titleButton], in: .leading)
        contentView.orientation = .horizontal
        contentView.alignment = .centerY
        contentView.spacing = 3
        contentView.translatesAutoresizingMaskIntoConstraints = false

        trailingSeparator.wantsLayer = true
        trailingSeparator.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.122).cgColor
        trailingSeparator.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(selectionBackgroundView)
        container.addSubview(contentView)
        container.addSubview(closeButton)
        container.addSubview(pinButton)
        container.addSubview(trailingSeparator)
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        container.addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
        NSLayoutConstraint.activate([
            selectionBackgroundView.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
            selectionBackgroundView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 3),
            selectionBackgroundView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -3),
            selectionBackgroundView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
            closeButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 7),
            closeButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            fileIconView.widthAnchor.constraint(equalToConstant: 18),
            fileIconView.heightAnchor.constraint(equalToConstant: 18),
            contentView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            contentView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            contentView.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 28),
            contentView.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -28),
            pinButton.widthAnchor.constraint(equalToConstant: 18),
            pinButton.heightAnchor.constraint(equalToConstant: 18),
            pinButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -7),
            pinButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            trailingSeparator.widthAnchor.constraint(equalToConstant: 1),
            trailingSeparator.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            trailingSeparator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            trailingSeparator.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])
        view = container
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applySelectionAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applySelectionAppearance()
    }

    override var isSelected: Bool {
        didSet {
            applySelectionAppearance()
        }
    }

    func configure(
        tab: EditorTab,
        isSelected: Bool,
        showsTrailingSeparator: Bool,
        onSelect: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onPin: @escaping () -> Void
    ) {
        _ = view
        self.tab = tab
        self.configuredSelection = isSelected
        self.showsTrailingSeparator = showsTrailingSeparator
        self.onSelect = onSelect
        self.onClose = onClose
        self.onPin = onPin

        let displayName = (tab.relativePath as NSString).lastPathComponent
        let titleFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize + 2)
        titleButton.title = displayName
        titleButton.font = tab.isPinned
            ? titleFont
            : NSFontManager.shared.convert(titleFont, toHaveTrait: .italicFontMask)
        titleButton.toolTip = tab.relativePath
        view.toolTip = tab.relativePath
        titleButton.identifier = NSUserInterfaceItemIdentifier("tab.title.\(tab.relativePath)")
        titleButton.setAccessibilityLabel(displayName)
        titleButton.setAccessibilityValue(
            editorTabAccessibilityValue(tab: tab, isSelected: isSelected)
        )
        fileIconView.image = Self.fileIcon(for: tab.relativePath)
        fileIconView.identifier = NSUserInterfaceItemIdentifier("tab.icon.\(tab.relativePath)")
        contentView.identifier = NSUserInterfaceItemIdentifier("tab.content.\(tab.relativePath)")
        pinButton.isHidden = tab.isPinned || !isHovered
        pinButton.identifier = NSUserInterfaceItemIdentifier("tab.pin.\(tab.relativePath)")
        pinButton.setAccessibilityLabel(
            Localized.string(
                "Pin \(displayName)",
                comment: "Accessibility label for a tab chip's pin button, naming the specific file it pins"
            )
        )
        pinButton.toolTip = pinButton.accessibilityLabel()
        closeButton.identifier = NSUserInterfaceItemIdentifier("tab.close.\(tab.relativePath)")
        closeButton.setAccessibilityLabel(
            Localized.string(
                "Close \(displayName)",
                comment: "Accessibility label for a tab chip's close button, naming the specific file it closes"
            )
        )
        closeButton.toolTip = closeButton.accessibilityLabel()
        view.identifier = NSUserInterfaceItemIdentifier("tab.\(tab.relativePath)")
        applySelectionAppearance()
    }

    private static func fileIcon(for relativePath: String) -> NSImage {
        let pathExtension = (relativePath as NSString).pathExtension.lowercased()
        let cacheKey = pathExtension.isEmpty ? "file" : pathExtension
        if let cached = fileIcons[cacheKey] {
            return cached
        }

        let colors: [NSColor] = [
            .systemOrange, .systemBlue, .systemPurple,
            .systemGreen, .systemRed, .systemIndigo
        ]
        let colorIndex = cacheKey.unicodeScalars.reduce(0) { result, scalar in
            result + Int(scalar.value)
        } % colors.count
        let glyph = String((pathExtension.first ?? "F").uppercased())
        let icon = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            colors[colorIndex].setFill()
            NSBezierPath(
                roundedRect: rect.insetBy(dx: 0.25, dy: 0.25),
                xRadius: 2.5,
                yRadius: 2.5
            ).fill()

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 7, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let textSize = glyph.size(withAttributes: attributes)
            glyph.draw(
                at: NSPoint(
                    x: (rect.width - textSize.width) / 2,
                    y: (rect.height - textSize.height) / 2
                ),
                withAttributes: attributes
            )
            return true
        }
        icon.isTemplate = false
        fileIcons[cacheKey] = icon
        return icon
    }

    private func applySelectionAppearance() {
        let selected = isSelected || configuredSelection
        if selected {
            let isDark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let component: CGFloat = isDark ? 0.27 : 250 / 255
            selectionBackgroundView.layer?.backgroundColor = NSColor(
                srgbRed: component,
                green: component,
                blue: component,
                alpha: 1
            ).cgColor
            selectionBackgroundView.layer?.shadowColor = NSColor.shadowColor.cgColor
            selectionBackgroundView.layer?.shadowOpacity = 0.12
            selectionBackgroundView.layer?.shadowRadius = 1
            selectionBackgroundView.layer?.shadowOffset = NSSize(width: 0, height: -0.5)
        } else {
            selectionBackgroundView.layer?.backgroundColor = isHovered
                ? NSColor.labelColor.withAlphaComponent(0.06).cgColor
                : NSColor.clear.cgColor
            selectionBackgroundView.layer?.shadowOpacity = 0
        }
        trailingSeparator.isHidden = selected || !showsTrailingSeparator
        titleButton.contentTintColor = selected
            ? .labelColor
            : NSColor.labelColor.withAlphaComponent(0.78)
        fileIconView.isHidden = false
        closeButton.isHidden = !isHovered
        pinButton.isHidden = tab?.isPinned != false || !isHovered
        pinButton.contentTintColor = .secondaryLabelColor
        closeButton.contentTintColor = .secondaryLabelColor
        if let tab {
            titleButton.setAccessibilityValue(
                editorTabAccessibilityValue(tab: tab, isSelected: selected)
            )
        }
    }

    @objc
    private func handleSelect(_ sender: Any?) {
        onSelect()
    }

    @objc
    private func handleClose(_ sender: Any?) {
        onClose()
    }

    @objc
    private func handlePin(_ sender: Any?) {
        onPin()
    }
}
