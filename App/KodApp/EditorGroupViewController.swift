import AppKit
import CodeViewport
import FontCore
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

    private let tabBarStack = NSStackView()
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

        tabBarStack.identifier = NSUserInterfaceItemIdentifier("editorGroup.tabBar")
        tabBarStack.orientation = .horizontal
        tabBarStack.alignment = .centerY
        tabBarStack.spacing = 2
        tabBarStack.registerForDraggedTypes([tabPasteboardType])

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

        headerRow.setViews([tabBarStack, toolbar], in: .leading)
        headerRow.identifier = NSUserInterfaceItemIdentifier("editorGroup.header")
        headerRow.orientation = .horizontal
        headerRow.distribution = .fill
        headerRow.spacing = 8
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.wantsLayer = true
        tabBarStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

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
        let tabID = state.openTab(relativePath: relativePath, pinned: pinned)
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
            documentControllers.removeValue(forKey: tab.id)
            previewControllers.removeValue(forKey: tab.id)
            previewKinds.removeValue(forKey: tab.id)
            imageOnlyTabIDs.remove(tab.id)
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
        documentControllers.removeValue(forKey: tabID)
        previewControllers.removeValue(forKey: tabID)
        previewKinds.removeValue(forKey: tabID)
        previewModeTabIDs.remove(tabID)
        imageOnlyTabIDs.remove(tabID)
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
        state.selectedTabID.flatMap { documentControllers[$0] }
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
            tabID = state.openTab(relativePath: entry.relativePath, pinned: true)
        }
        state.selectedTabID = tabID
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
        guard !Task.isCancelled else {
            return
        }
        previewControllers[tabID] = preview
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
        let pathExtension = (relativePath as NSString).pathExtension
        let kind = PreviewContentDetector.detect(pathExtension: pathExtension, contentPrefix: snapshot.utf8Data.prefix(4_096))
        previewKinds[tabID] = kind
        guard kind != .none else {
            previewControllers.removeValue(forKey: tabID)
            return
        }
        previewModeTabIDs.insert(tabID)

        let data = snapshot.utf8Data
        let theme = AppearanceSettings.currentTheme()
        let fontSettings = AppearanceSettings.currentFontSettings()
        let trustCheck = isWorkspaceTrusted
        let openLocal = onOpenLocalRelativePath
        Task { [weak self] in
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
            self.previewControllers[tabID] = preview
            if self.state.selectedTabID == tabID {
                self.showContent(self.contentController(forTabID: tabID))
                self.refreshPreviewToggleButton()
            }
        }
    }

    /// Resolves which view controller should currently occupy the
    /// content host for `tabID`: an image-only tab always shows its
    /// preview (there is no source view); a text-based previewable tab
    /// shows its preview or its `CodeDocumentViewController` depending on
    /// `previewModeTabIDs`; everything else shows its
    /// `CodeDocumentViewController` exactly as before this phase.
    private func contentController(forTabID tabID: EditorTabID) -> NSViewController? {
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
        guard let tabID = state.selectedTabID, let kind = previewKinds[tabID], kind != .none else {
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
        case none
    }

    func displayedContentKind(forTabID tabID: EditorTabID) -> DisplayedContentKind {
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
            tabID = state.openTab(relativePath: relativePath, pinned: pinned)
        }
        previewControllers[tabID] = preview
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
        tabBarStack.arrangedSubviews.forEach {
            tabBarStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for tab in state.tabs {
            let chip = EditorTabChipView(
                tab: tab,
                isSelected: tab.id == state.selectedTabID,
                onSelect: { [weak self] in
                    guard let self else { return }
                    self.onActivate?(self.groupID)
                    self.selectTab(tab.id)
                },
                onClose: { [weak self] in
                    guard let self else { return }
                    self.onActivate?(self.groupID)
                    self.closeTab(tab.id)
                },
                onPin: { [weak self] in
                    guard let self else { return }
                    self.onActivate?(self.groupID)
                    self.pinTab(tab.id)
                },
                onDropBefore: { [weak self] draggedID in
                    guard let self else { return }
                    self.onActivate?(self.groupID)
                    self.handleDrop(draggedID: draggedID, before: tab.id)
                }
            )
            tabBarStack.addArrangedSubview(chip)
        }
    }

    private func handleDrop(draggedID: EditorTabID, before targetID: EditorTabID) {
        guard let targetIndex = state.tabs.firstIndex(where: { $0.id == targetID }) else {
            return
        }
        moveTab(draggedID, toIndex: targetIndex)
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

/// A single tab chip: title (italic while unpinned/"preview"), a pin
/// affordance for preview tabs, and a close button. Also acts as an
/// `NSDraggingSource` so tabs can be dragged to reorder within the bar.
private final class EditorTabChipView: NSView, NSDraggingSource {
    private let tab: EditorTab
    private let onSelect: () -> Void
    private let onClose: () -> Void
    private let onPin: () -> Void
    private let onDropBefore: (EditorTabID) -> Void
    private let titleButton: NSButton
    private var dragOrigin: NSPoint?

    init(
        tab: EditorTab,
        isSelected: Bool,
        onSelect: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onPin: @escaping () -> Void,
        onDropBefore: @escaping (EditorTabID) -> Void
    ) {
        self.tab = tab
        self.onSelect = onSelect
        self.onClose = onClose
        self.onPin = onPin
        self.onDropBefore = onDropBefore

        let displayName = (tab.relativePath as NSString).lastPathComponent
        titleButton = NSButton(title: displayName, target: nil, action: nil)
        super.init(frame: .zero)

        identifier = NSUserInterfaceItemIdentifier("tab.\(tab.relativePath)")
        registerForDraggedTypes([tabPasteboardType])

        titleButton.bezelStyle = .inline
        titleButton.isBordered = false
        titleButton.setButtonType(.momentaryPushIn)
        titleButton.target = self
        titleButton.action = #selector(handleSelect)
        titleButton.contentTintColor = isSelected ? .labelColor : .secondaryLabelColor
        titleButton.identifier = NSUserInterfaceItemIdentifier("tab.title.\(tab.relativePath)")
        // Explicit label/value pair (SPEC 14): the label is always the
        // bare filename (never the italicized/decorated visual title),
        // and the value spells out selection/pinned/preview/tombstoned
        // state as text rather than relying on the chip's background
        // tint or the title's italic styling alone.
        titleButton.setAccessibilityLabel(displayName)
        titleButton.setAccessibilityValue(editorTabAccessibilityValue(tab: tab, isSelected: isSelected))
        if !tab.isPinned {
            let attributed = NSMutableAttributedString(string: displayName)
            attributed.addAttribute(
                .font,
                value: NSFontManager.shared.convert(NSFont.systemFont(ofSize: 12), toHaveTrait: .italicFontMask),
                range: NSRange(location: 0, length: attributed.length)
            )
            titleButton.attributedTitle = attributed
        }
        titleButton.translatesAutoresizingMaskIntoConstraints = false

        var views: [NSView] = [titleButton]

        if !tab.isPinned {
            let pinButton = NSButton(
                image: NSImage(
                    systemSymbolName: "pin",
                    accessibilityDescription: Localized.string("Pin Tab", comment: "Generic accessibility description for the pin-tab image, overridden per-tab below")
                ) ?? NSImage(),
                target: self,
                action: #selector(handlePin)
            )
            pinButton.identifier = NSUserInterfaceItemIdentifier("tab.pin.\(tab.relativePath)")
            pinButton.bezelStyle = .inline
            pinButton.isBordered = false
            // Per-tab label ("Pin <filename>") rather than the shared,
            // generic "Pin Tab" image description, so VoiceOver names the
            // specific tab this button pins (SPEC 14).
            pinButton.setAccessibilityLabel(
                Localized.string("Pin \(displayName)", comment: "Accessibility label for a tab chip's pin button, naming the specific file it pins")
            )
            views.append(pinButton)
        }

        let closeButton = NSButton(
            image: NSImage(
                systemSymbolName: "xmark",
                accessibilityDescription: Localized.string("Close Tab", comment: "Generic accessibility description for the close-tab image, overridden per-tab below")
            ) ?? NSImage(),
            target: self,
            action: #selector(handleClose)
        )
        closeButton.identifier = NSUserInterfaceItemIdentifier("tab.close.\(tab.relativePath)")
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        // Per-tab label ("Close <filename>") rather than the shared,
        // generic "Close Tab" image description (SPEC 14).
        closeButton.setAccessibilityLabel(
            Localized.string("Close \(displayName)", comment: "Accessibility label for a tab chip's close button, naming the specific file it closes")
        )
        views.append(closeButton)

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false

        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = isSelected
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).cgColor
            : NSColor.clear.cgColor

        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
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

    // MARK: - Drag source (reordering)

    override func mouseDown(with event: NSEvent) {
        dragOrigin = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin else {
            return
        }
        let distance = hypot(
            event.locationInWindow.x - dragOrigin.x,
            event.locationInWindow.y - dragOrigin.y
        )
        guard distance > 4 else {
            return
        }
        self.dragOrigin = nil

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(tab.id.rawValue, forType: tabPasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(bounds, contents: nil)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let rawValue = sender.draggingPasteboard.string(forType: tabPasteboardType) else {
            return false
        }
        onDropBefore(EditorTabID(rawValue: rawValue))
        return true
    }
}
