import AppKit
import CodeViewport
import FontCore
import GitCore
import GitUI
import KodUIComponents
import LanguageClient
import PreviewCore
import PreviewUI
import SettingsCore
import SourceModel
import SyntaxCore
import ThemeCore
import WorkspaceCore

/// Shared by this group (click-to-activate) and its tab bar (drag
/// cancellation): a scoped `NSEvent` local monitor that removes itself when
/// released, so no observation outlives the view that installed it.
final class LocalEventMonitor: @unchecked Sendable {
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

private final class EditorGroupRootView: NSView {
    override var fittingSize: NSSize {
        .zero
    }
}

@MainActor
public struct EditorTabDropPreview: Equatable {
    public let groupID: EditorGroupID
    public let insertionIndex: Int
    public let gapFrameInWindow: NSRect
    public let railFrameInWindow: NSRect
}

public enum EditorPreviewSourceControlState: Equatable {
    case unavailable
    case previewOnly
    case showingPreview
    case showingSource
}

/// One editor pane: a tab bar (preview vs. pinned tabs, close buttons, drag
/// reordering — `EditorTabBarView`), and a content host that swaps in
/// whatever the selected tab's `EditorTabRuntime` currently is (source,
/// preview, Git diff, Quick Diff, tombstone). Owns one `EditorGroupState`
/// and reports every state change upward so the workspace can persist it;
/// owns exactly one runtime per open tab and nothing else about a tab's
/// live content.
@MainActor
public final class EditorGroupViewController: NSViewController {
    public let groupID: EditorGroupID
    public private(set) var state: EditorGroupState

    /// Resolves a workspace-relative path to a freshly-loaded snapshot; set
    /// by the owning `WorkspaceViewController`.
    public var loadSnapshot: (@MainActor (String) async throws -> SourceSnapshot)?
    public var syntaxLanguageForSnapshot: ((SourceSnapshot) -> SyntaxLanguage?)?
    /// Reads a workspace-relative path's exact raw bytes, independent of
    /// `SourceSnapshot`'s text-decoding requirement — used only for
    /// SPEC 10.2 image previews, since a PNG/JPEG/GIF/HEIC/TIFF file is
    /// not valid UTF-8 text and `SourceSnapshotLoader` correctly refuses
    /// to load one at all. Set by the owning `WorkspaceViewController`.
    public var loadRawData: (@MainActor (String) async throws -> Data)?
    /// Reads an HTML preview subresource only after the owning workspace has
    /// verified that its resolved path remains inside the workspace root.
    public var loadPreviewResourceData: (@MainActor (String) async throws -> Data)?
    /// Whether the workspace this group belongs to is currently trusted
    /// (`WorkspaceCore.WorkspaceTrustStore`), threaded through to every
    /// built-in preview's link/resource policy (SPEC 10.1) without this
    /// type depending on `WorkspaceCore` trust machinery directly.
    public var isWorkspaceTrusted: () -> Bool = { false }
    /// Invoked when a preview's link click resolves to a local,
    /// same-workspace relative path — set by `WorkspaceViewController` to
    /// actually navigate there.
    public var onOpenLocalRelativePath: ((String) -> Void)?
    public var onStateChange: ((EditorGroupID, EditorGroupState) -> Void)?
    public var onActivate: ((EditorGroupID) -> Void)?
    public var onTabDragUpdate: ((EditorGroupID, EditorTabID, NSPoint) -> EditorTabDropPreview?)?
    public var onTabDrop: ((EditorGroupID, EditorTabID, EditorTabDropPreview) -> Bool)?
    public var onTabDragEnd: ((EditorGroupID) -> Void)?
    public var onPreviewSourceControlChange: ((EditorGroupID, EditorPreviewSourceControlState) -> Void)?
    /// Fired whenever a `CodeDocumentViewController` becomes available for
    /// `relativePath` — on first open and again after every reload — so
    /// the owning `WorkspaceViewController` can wire language-service
    /// integration (document sync, semantic tokens) without this type
    /// needing to know anything about `LanguageClient`.
    public var onDocumentReady: ((String, CodeDocumentViewController) -> Void)?
    /// Fired immediately before a `CodeDocumentViewController`'s content is
    /// permanently discarded by this group — tab closed, a preview tab
    /// reused for a different file, a reload's superseded controller, a
    /// tombstoned tab, or the whole group being removed from the split
    /// tree. Deliberately *not* fired when a tab is transferred live to
    /// another group: the same controller keeps running there, so its
    /// language-service document must stay open.
    public var onDocumentClosed: ((String, CodeDocumentViewController) -> Void)?
    public var onActiveDocumentChange: ((CodeDocumentViewController?) -> Void)?

    /// Whether this is the currently-active split group — the one
    /// Command Palette/Quick Open/Go to Line/etc. target, and the one a
    /// newly-split group is created relative to. Kod previously only
    /// tracked this in `WorkspaceViewController.layoutState.activeGroupID`
    /// with no reflection at all back on the group itself, so there was
    /// no way — visual or accessible — to tell which group was active
    /// with more than one group on screen (SPEC 14: "the currently-active
    /// split group must be accessibly distinguishable"). `didSet` updates
    /// both a subtle tab-rail tint and an explicit accessibility
    /// label/value, so a VoiceOver user gets the same information a
    /// sighted user would from the highlight.
    public var isActive = true {
        didSet {
            guard oldValue != isActive else {
                return
            }
            applyActiveAppearance()
        }
    }

    public var wordWrapEnabled = false {
        didSet {
            guard oldValue != wordWrapEnabled else {
                return
            }
            runtimes.all.forEach { $0.applyWordWrap(wordWrapEnabled) }
        }
    }

    public var minimapEnabled = true {
        didSet {
            guard oldValue != minimapEnabled else {
                return
            }
            runtimes.all.forEach { $0.applyMinimap(minimapEnabled) }
        }
    }

    private let tabBarView = EditorTabBarView(frame: .zero)
    private let appearanceCenter: AppearanceCenter
    private var appearanceObservation: SettingsObservation?
    private let headerRow = NSStackView()
    private let contentHost = NSView()
    private let placeholderLabel = NSTextField(
        labelWithString: editorUIStrings.string(
            "Select a file in the Explorer or press Command-P.",
            comment: "Placeholder text shown in an editor group before any tab is open"
        )
    )

    /// Exactly one `EditorTabRuntime` per open tab, and the only thing in
    /// this group that owns a tab's live child controllers, its detected
    /// preview kind, its preview/source choice, or its in-flight preview
    /// build. Replaces the six parallel per-tab dictionaries and two
    /// boolean ID sets this type used to keep in sync by hand.
    private var runtimes = EditorTabRuntimeStore()
    private var loadTask: Task<Void, Never>?
    private var activationMouseMonitor: LocalEventMonitor?

    public init(
        groupID: EditorGroupID,
        state: EditorGroupState,
        appearanceCenter: AppearanceCenter
    ) {
        self.groupID = groupID
        self.state = state
        self.appearanceCenter = appearanceCenter
        super.init(nibName: nil, bundle: nil)
        appearanceObservation = appearanceCenter.observe { [weak self] snapshot in
            self?.applyAppearance(snapshot)
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    deinit {
        // Nonisolated: only main-actor-independent cleanup belongs here.
        // Each `EditorTabRuntime` cancels its own preview build when it is
        // released with this group. Document closes are reported from
        // `prepareForRemovalFromWorkspace()` instead, and the language
        // services coordinator additionally sweeps registrations whose
        // controller was released without one.
        loadTask?.cancel()
    }

    private func applyAppearance(_ snapshot: AppearanceCenter.Snapshot) {
        runtimes.all.forEach {
            $0.applyAppearance(
                theme: snapshot.theme,
                fontSettings: snapshot.fontSettings
            )
        }
    }
    public override func loadView() {
        let container = EditorGroupRootView()
        container.identifier = NSUserInterfaceItemIdentifier("editorGroup.container")
        container.setContentHuggingPriority(.defaultLow, for: .horizontal)
        container.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        container.setAccessibilityIdentifier("editorGroup.container")

        tabBarView.identifier = NSUserInterfaceItemIdentifier("editorGroup.tabBar")

        headerRow.setViews([tabBarView], in: .leading)
        headerRow.identifier = NSUserInterfaceItemIdentifier("editorGroup.header")
        headerRow.orientation = .horizontal
        headerRow.distribution = .fill
        headerRow.spacing = 0
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tabBarView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tabBarView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        placeholderLabel.identifier = NSUserInterfaceItemIdentifier("editorGroup.placeholder")
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        contentHost.identifier = NSUserInterfaceItemIdentifier("editorGroup.contentHost")
        contentHost.wantsLayer = true
        contentHost.layer?.masksToBounds = true
        contentHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
        contentHost.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentHost.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.centerXAnchor.constraint(equalTo: contentHost.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: contentHost.centerYAnchor)
        ])

        container.addSubview(contentHost)
        container.addSubview(headerRow, positioned: .above, relativeTo: contentHost)
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

    /// Reflects `isActive` both visually (a faint tab-rail tint, so
    /// sighted users don't need to guess which group last-clicked
    /// commands like Quick Open/Go to Line/Command Palette will target)
    /// and accessibly (an explicit label/value on the group's root view,
    /// so the same information reaches VoiceOver — see `isActive`'s doc
    /// comment; SPEC 14 explicitly calls out this state must not rely on
    /// the visual highlight alone).
    private func applyActiveAppearance() {
        tabBarView.isActive = isActive
        view.setAccessibilityLabel(editorUIStrings.string("Editor group", comment: "Accessibility label for an editor group's root view"))
        view.setAccessibilityValue(
            isActive
                ? editorUIStrings.string("Active editor group", comment: "Accessibility value indicating this is the currently active editor group")
                : editorUIStrings.string("Inactive editor group", comment: "Accessibility value indicating this editor group is not currently active")
        )
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        refreshTabBar()
        restoreIfNeeded()
    }

    // MARK: - Opening content

    /// Opens `relativePath` in this group using an already-loaded snapshot
    /// (used by Explorer/Quick Open, which load the snapshot themselves).
    public func openTab(relativePath: String, pinned: Bool, snapshot: SourceSnapshot) {
        let tabID = openStateTab(relativePath: relativePath, pinned: pinned)
        let runtime = runtimes.runtime(for: tabID, relativePath: relativePath)
        // Reopening a file this tab is already showing keeps its live
        // source view (and its scroll position, and its language-service
        // document) rather than replacing it with an identical one.
        let controller = runtime.sourceDocument ?? makeDocumentController(snapshot: snapshot)
        notifyDocumentsClosed(runtime.showSource(controller), path: runtime.relativePath)
        preparePreviewIfNeeded(runtime: runtime, tabID: tabID, snapshot: snapshot)
        showContent(runtime.displayedController)
        recordCurrentNavigation()
        refreshTabBar()
        notifyPreviewSourceControlChange()
        notifyStateChange()
        onDocumentReady?(relativePath, controller)
    }

    public func openDiffTab(relativePath: String, diff: GitFileDiff) {
        recordCurrentNavigation()
        let tabID = openStateTab(relativePath: relativePath, pinned: true)
        let runtime = runtimes.runtime(for: tabID, relativePath: relativePath)
        let controller = GitDiffViewController()
        controller.update(diff: diff)
        runtime.showDiff(controller)
        showContent(runtime.displayedController)
        refreshTabBar()
        notifyPreviewSourceControlChange()
        notifyStateChange()
    }

    public func openQuickDiffTab(
        relativePath: String,
        snapshot: SourceSnapshot,
        sources: [GitQuickDiffSource],
        revealFirstHunk: Bool,
        unavailableMessage: String? = nil,
        fallbackDiff: GitFileDiff? = nil
    ) {
        recordCurrentNavigation()
        let tabID = openStateTab(relativePath: relativePath, pinned: true)
        let runtime = runtimes.runtime(for: tabID, relativePath: relativePath)

        let documentController = makeDocumentController(snapshot: snapshot)
        let quickDiffController = GitQuickDiffController(documentController: documentController)
        wireQuickDiffController(
            quickDiffController,
            tabID: tabID,
            relativePath: relativePath
        )
        runtime.showQuickDiff(document: documentController, controller: quickDiffController)
        showContent(documentController)
        if let unavailableMessage {
            quickDiffController.showUnavailable(message: unavailableMessage, diff: fallbackDiff)
        } else {
            quickDiffController.update(sources: sources, revealFirstHunk: revealFirstHunk)
        }
        refreshTabBar()
        notifyPreviewSourceControlChange()
        notifyStateChange()
    }

    private func wireQuickDiffController(
        _ controller: GitQuickDiffController,
        tabID: EditorTabID,
        relativePath: String
    ) {
        controller.onOpenFullDiff = { [weak self] diff in
            guard let self,
                  self.state.tabs.contains(where: { $0.id == tabID && $0.relativePath == relativePath }) else {
                return
            }
            self.openDiffTab(relativePath: relativePath, diff: diff)
        }
    }

    /// Opens `relativePath` (as `openTab(relativePath:pinned:snapshot:)`
    /// does) and additionally selects `utf8Range`, scrolling it into view —
    /// used to land on a specific Workspace Search match in the active
    /// group (SPEC 8.2: "navigation opens the match in the active group
    /// with selection").
    public func openTab(
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
    public func reloadTab(relativePath: String, with newSnapshot: SourceSnapshot) {
        for tab in state.tabs where tab.relativePath == relativePath {
            let runtime = runtimes.runtime(for: tab.id, relativePath: relativePath)
            // Source Control Quick Diff owns a virtual working/index snapshot.
            // Its Git-status refresh replaces that snapshot; an FSEvent may
            // refresh a previously opened source controller behind it, but
            // must not convert the visible tab back to normal source mode.
            let preservesQuickDiff = runtime.showsQuickDiff
            let previousController = runtime.sourceDocument
            if preservesQuickDiff, previousController == nil {
                continue
            }
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

            let newController = makeDocumentController(snapshot: newSnapshot)
            if !preservesQuickDiff {
                // A full-file diff is a snapshot of a comparison, not a live
                // view of the file: an external change converts the tab back
                // to source, exactly as it did before this phase. Quick Diff
                // is the deliberate exception above.
                runtime.dismissDiff()
            }
            let superseded = runtime.replaceSourceDocument(with: newController)
            preparePreviewIfNeeded(runtime: runtime, tabID: tab.id, snapshot: newSnapshot)

            // The new controller's view must actually be attached to the
            // window (via `showContent`) and laid out *before* restoring
            // the reconciled anchor: `scrollSourceLineToTop` needs a real
            // scroll-view frame to compute a meaningful scroll, which a
            // detached, never-laid-out view does not have.
            if state.selectedTabID == tab.id, !preservesQuickDiff {
                showContent(runtime.displayedController)
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
            // Reported *after* the replacement is registered: a reload keeps
            // the same file open (with a new version), so the language
            // service must never see the document drop to zero live panes
            // and churn through didClose/didOpen.
            if let superseded, superseded !== newController {
                notifyDocumentsClosed([superseded], path: runtime.relativePath)
            }
        }
    }

    /// Marks every open tab for `relativePath` as a tombstone (deleted or
    /// moved externally). If that tab is currently shown, its content is
    /// replaced with an explicit "no longer available" placeholder rather
    /// than silently leaving stale content on screen.
    public func markTombstoned(relativePath: String, reason: TabTombstoneReason) {
        state.markTombstoned(relativePath: relativePath, reason: reason)
        for tab in state.tabs where tab.relativePath == relativePath {
            let runtime = runtimes.runtime(for: tab.id, relativePath: relativePath)
            notifyDocumentsClosed(
                runtime.markTombstoned(reason: reason),
                path: runtime.relativePath
            )
            if state.selectedTabID == tab.id {
                showContent(nil)
                showTombstonePlaceholder(relativePath: relativePath)
            }
        }
        refreshTabBar()
        notifyStateChange()
    }

    public func reloadChangedSyntaxDefinitions() {
        let changedSnapshots = state.tabs.reduce(into: [String: SourceSnapshot]()) { snapshots, tab in
            guard let syntaxLanguageForSnapshot,
                  let document = runtimes[tab.id]?.sourceDocument,
                  document.viewport.language != syntaxLanguageForSnapshot(document.snapshot) else {
                return
            }
            snapshots[tab.relativePath] = document.snapshot
        }
        for (relativePath, snapshot) in changedSnapshots {
            reloadTab(relativePath: relativePath, with: snapshot)
        }
    }

    /// Clears a previously set tombstone (the file reappeared at the same
    /// path). Reloads the tab's content if it is currently shown.
    public func clearTombstone(relativePath: String) {
        state.clearTombstone(relativePath: relativePath)
        refreshTabBar()
        if let selectedID = state.selectedTabID,
           state.tabs.first(where: { $0.id == selectedID })?.relativePath == relativePath {
            loadAndShow(tabID: selectedID, restoring: nil)
        }
        notifyStateChange()
    }

    private func showTombstonePlaceholder(relativePath: String) {
        let message = editorUIStrings.string(
            "\((relativePath as NSString).lastPathComponent) is no longer available.\nIt may have been deleted or moved outside Kod.",
            comment: "Editor placeholder explaining that an open file was deleted or moved"
        )
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
        notifyPreviewSourceControlChange()
        notifyStateChange()
    }

    public func closeTab(_ tabID: EditorTabID) {
        discardRuntime(for: tabID)
        let stillHasTabs = state.closeTab(tabID)
        if stillHasTabs, let selectedID = state.selectedTabID {
            loadAndShow(tabID: selectedID, restoring: nil)
        } else if !stillHasTabs {
            showContent(nil)
        }
        refreshTabBar()
        notifyPreviewSourceControlChange()
        notifyStateChange()
    }

    public func pinTab(_ tabID: EditorTabID) {
        state.pin(tabID)
        refreshTabBar()
        notifyStateChange()
    }

    private func moveTab(_ tabID: EditorTabID, toIndex index: Int) {
        state.moveTab(tabID, toIndex: index)
        refreshTabBar()
        notifyStateChange()
    }

    /// Hands this tab's live runtime — the same controllers, still running —
    /// to whichever group the drag lands in. Nothing is torn down and no
    /// document close is reported: the file never stops being open, it just
    /// changes panes.
    public func detachTabForTransfer(_ tabID: EditorTabID) -> EditorTabTransferPayload? {
        guard let tab = state.tabs.first(where: { $0.id == tabID }) else {
            return nil
        }
        recordCurrentNavigation()
        if state.selectedTabID == tabID {
            loadTask?.cancel()
            loadTask = nil
        }
        let runtime = runtimes.remove(tabID)
            ?? EditorTabRuntime(relativePath: tab.relativePath)
        // Any in-flight preview build belongs to this group's content host;
        // the destination restarts it once the runtime lands there.
        runtime.cancelPreviewBuild()
        let payload = EditorTabTransferPayload(tab: tab, runtime: runtime)
        _ = state.removeTabForTransfer(tabID)
        if let selectedID = state.selectedTabID {
            loadAndShow(tabID: selectedID, restoring: nil)
        } else {
            showContent(nil)
        }
        refreshTabBar()
        notifyPreviewSourceControlChange()
        notifyStateChange()
        return payload
    }

    @discardableResult
    public func insertTransferredTab(
        _ payload: EditorTabTransferPayload,
        at index: Int
    ) -> EditorTabID {
        let insertedID = state.insertTransferredTab(payload.tab, at: index)
        let runtime = payload.runtime
        if insertedID == payload.tab.id {
            runtime.applyWordWrap(wordWrapEnabled)
            runtime.applyMinimap(minimapEnabled)
            if let quickDiffController = runtime.quickDiffController {
                wireQuickDiffController(
                    quickDiffController,
                    tabID: insertedID,
                    relativePath: payload.tab.relativePath
                )
            }
            if let displaced = runtimes.adopt(runtime, for: insertedID) {
                // Defensive: nothing should already own this tab ID, but a
                // displaced runtime is torn down rather than leaked.
                notifyDocumentsClosed(displaced.discardContent(), path: displaced.relativePath)
            }
            if runtime.previewController == nil,
               let documentController = runtime.sourceDocument {
                preparePreviewIfNeeded(
                    runtime: runtime,
                    tabID: insertedID,
                    snapshot: documentController.snapshot
                )
            }
        } else {
            // The destination group re-identified the tab (an ID it already
            // uses), so the transferred runtime cannot be reattached and
            // its content is discarded here rather than silently leaked —
            // `loadAndShow` below reloads the file from scratch.
            notifyDocumentsClosed(runtime.discardContent(), path: runtime.relativePath)
        }

        loadAndShow(tabID: insertedID, restoring: nil)
        recordCurrentNavigation()
        refreshTabBar()
        notifyPreviewSourceControlChange()
        notifyStateChange()
        return insertedID
    }

    public func tabDropInsertionIndex(at windowLocation: NSPoint) -> Int? {
        tabBarView.insertionIndex(at: windowLocation)
    }

    @discardableResult
    public func showTabDropPreview(at windowLocation: NSPoint) -> EditorTabDropPreview? {
        guard let geometry = tabBarView.showExternalDropPreview(at: windowLocation) else {
            return nil
        }
        return EditorTabDropPreview(
            groupID: groupID,
            insertionIndex: geometry.insertionIndex,
            gapFrameInWindow: geometry.gapFrameInWindow,
            railFrameInWindow: geometry.railFrameInWindow
        )
    }

    public func clearTabDropPreview() {
        tabBarView.clearExternalDropPreview()
    }

    public func consumeTabDropPreview() {
        tabBarView.consumeExternalDropPreview()
    }

    public var currentDocumentController: CodeDocumentViewController? {
        guard let selectedTabID = state.selectedTabID else {
            return nil
        }
        return runtimes[selectedTabID]?.focusedSourceDocument
    }

    public var currentStatusDocument: EditorStatusDocument? {
        guard let selectedTabID = state.selectedTabID else {
            return nil
        }
        return runtimes[selectedTabID]?.statusDocument
    }

    public func applyDiagnostics(url: URL, diagnostics: [NormalizedDiagnostic]) {
        let markerDiagnostics = diagnostics.map { diagnostic in
            let severity: CodeMinimapDiagnosticSeverity
            switch diagnostic.severity {
            case .error:
                severity = .error
            case .warning:
                severity = .warning
            case .information, .hint, nil:
                severity = .information
            }
            return CodeMinimapDiagnosticMarker(
                utf8Range: diagnostic.utf8Range,
                severity: severity
            )
        }
        for controller in runtimes.all.flatMap({ $0.documentControllers })
        where controller.snapshot.url.standardizedFileURL == url.standardizedFileURL {
            guard let version = diagnostics.first?.snapshotVersion else {
                controller.clearDiagnosticMarkers()
                continue
            }
            _ = controller.applyDiagnosticMarkers(markerDiagnostics, snapshotVersion: version)
        }
    }

    public var currentVisibleDocumentController: CodeDocumentViewController? {
        guard let selectedTabID = state.selectedTabID else {
            return nil
        }
        return runtimes[selectedTabID]?.visibleSourceDocument
    }

    public var currentQuickDiffController: GitQuickDiffController? {
        guard let selectedTabID = state.selectedTabID else {
            return nil
        }
        return runtimes[selectedTabID]?.quickDiffController
    }

    public var currentTabRelativePath: String? {
        guard let selectedTabID = state.selectedTabID else {
            return nil
        }
        return state.tabs.first(where: { $0.id == selectedTabID })?.relativePath
    }

    public func toggleFindBar() {
        currentDocumentController?.toggleFindBar()
    }

    public func goToLine(_ oneBasedLine: Int) {
        currentDocumentController?.goToLine(oneBasedLine)
    }

    // MARK: - Back / Forward

    public var canGoBack: Bool { state.canGoBack }
    public var canGoForward: Bool { state.canGoForward }

    public func goBack() {
        handleBack(nil)
    }

    public func goForward() {
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
        // Navigating back/forward to a tab that is showing a full diff
        // returns to the source it was opened from, which is still live
        // underneath it.
        runtimes[tabID]?.dismissDiff()
        state.current = entry
        loadAndShow(tabID: tabID, restoring: entry)
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
    public func captureLatestAnchorIntoState() {
        guard let tabID = state.selectedTabID,
              let controller = runtimes[tabID]?.sourceDocument else {
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
              let controller = runtimes[tabID]?.sourceDocument else {
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
        let tabID = state.openTab(relativePath: relativePath, pinned: pinned)
        if let runtime = runtimes[tabID], runtime.relativePath != relativePath {
            // The (unpinned) preview tab is being reused for a different
            // file: its previous content is gone for good, and its runtime
            // still knows the path it was actually showing, so the close is
            // reported under that path rather than the new one.
            discardRuntime(for: tabID)
        }
        return tabID
    }

    /// The group's single "this tab's content is gone for good" path:
    /// removes the runtime and reports exactly the source documents it
    /// actually discarded as closed. A transfer to another group
    /// deliberately does not come through here — the runtime keeps running
    /// there, so its language-service document must stay open.
    private func discardRuntime(for tabID: EditorTabID) {
        guard let runtime = runtimes.remove(tabID) else {
            return
        }
        notifyDocumentsClosed(runtime.discardContent(), path: runtime.relativePath)
    }

    /// Reports every source document a teardown actually discarded as
    /// closed, under the path its runtime was showing (a tab reused for a
    /// different file has already lost that path from the tab model).
    private func notifyDocumentsClosed(
        _ controllers: [CodeDocumentViewController],
        path: String
    ) {
        controllers.forEach { onDocumentClosed?(path, $0) }
    }

    /// Called by `WorkspaceViewController` just before this group is
    /// dropped from the split tree, so every document it still holds is
    /// reported closed while the closure wiring is alive. `deinit` cannot
    /// do this: it is nonisolated and must not touch main-actor state.
    public func prepareForRemovalFromWorkspace() {
        loadTask?.cancel()
        loadTask = nil
        for runtime in runtimes.removeAll() {
            notifyDocumentsClosed(runtime.discardContent(), path: runtime.relativePath)
        }
    }

    private func makeDocumentController(
        snapshot: SourceSnapshot
    ) -> CodeDocumentViewController {
        let appearance = appearanceCenter.snapshot
        let controller: CodeDocumentViewController
        if let syntaxLanguageForSnapshot {
            controller = CodeDocumentViewController(
                snapshot: snapshot,
                syntaxLanguage: syntaxLanguageForSnapshot(snapshot),
                theme: appearance.theme,
                fontSettings: appearance.fontSettings
            )
        } else {
            controller = CodeDocumentViewController(
                snapshot: snapshot,
                theme: appearance.theme,
                fontSettings: appearance.fontSettings
            )
        }
        controller.wordWrapEnabled = wordWrapEnabled
        controller.minimapEnabled = minimapEnabled
        return controller
    }

    private func loadAndShow(tabID: EditorTabID, restoring entry: EditorNavigationEntry?) {
        guard let tab = state.tabs.first(where: { $0.id == tabID }) else {
            return
        }
        let runtime = runtimes.runtime(for: tabID, relativePath: tab.relativePath)
        if tab.isTombstoned {
            notifyDocumentsClosed(
                runtime.markTombstoned(reason: tab.tombstoneReason),
                path: runtime.relativePath
            )
            showContent(nil)
            showTombstonePlaceholder(relativePath: tab.relativePath)
            return
        }
        // The file came back at the same path (`clearTombstone`): the
        // tombstone placeholder is stale, so fall through to a fresh load.
        runtime.prepareForReload()

        if let controller = runtime.displayedController {
            showContent(controller)
            notifyPreviewSourceControlChange()
            if let entry, let document = runtime.focusedSourceDocument {
                document.restoreNavigationAnchor(
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
                // The tab may have been closed, reused for another file or
                // dragged into another group while the load was suspended;
                // its runtime is then no longer this group's to fill in.
                guard !Task.isCancelled, runtimes.owns(runtime, for: tabID) else {
                    return
                }
                let controller = runtime.sourceDocument ?? makeDocumentController(snapshot: snapshot)
                notifyDocumentsClosed(runtime.showSource(controller), path: runtime.relativePath)
                preparePreviewIfNeeded(runtime: runtime, tabID: tabID, snapshot: snapshot)
                showContent(runtime.displayedController)
                onDocumentReady?(tab.relativePath, controller)
                notifyPreviewSourceControlChange()
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
                // what a raster image or binary property list is. Recover
                // by reading its raw bytes and building a preview-only tab
                // instead of leaving the content host blank.
                await self.tryShowPreviewAfterSnapshotFailure(runtime: runtime, tabID: tabID)
            }
        }
    }

    /// Recovery path for `loadAndShow`'s snapshot-load failure: reads raw
    /// bytes independent of text decoding and builds a preview-only tab for
    /// formats that are meaningful without a textual source side.
    private func tryShowPreviewAfterSnapshotFailure(
        runtime: EditorTabRuntime,
        tabID: EditorTabID
    ) async {
        guard let loadRawData else {
            return
        }
        let relativePath = runtime.relativePath
        guard let data = try? await loadRawData(relativePath) else {
            return
        }
        let kind = PreviewContentDetector.detect(
            pathExtension: (relativePath as NSString).pathExtension,
            contentPrefix: data.prefix(4_096)
        )
        switch kind {
        case .image, .structuredData:
            break
        case .markdown, .html, .none:
            return
        }
        guard let preview = await PreviewViewController.make(
            kind: kind,
            data: data,
            theme: appearanceCenter.snapshot.theme,
            fontSettings: appearanceCenter.snapshot.fontSettings,
            isWorkspaceTrusted: isWorkspaceTrusted
        ) else {
            return
        }
        guard !Task.isCancelled,
              runtimes.owns(runtime, for: tabID),
              state.tabs.first(where: { $0.id == tabID })?.relativePath == relativePath else {
            return
        }
        notifyDocumentsClosed(
            runtime.showPreviewOnly(preview, kind: kind),
            path: relativePath
        )
        if state.selectedTabID == tabID {
            showContent(preview)
            notifyPreviewSourceControlChange()
        }
    }

    /// Detects the tab's `PreviewKind` from a text snapshot (Markdown, HTML,
    /// JSON, XML plist, or SVG) and hands the build to the runtime. Binary images
    /// and binary plists take the raw-data recovery path above instead. A
    /// newly-detected previewable tab defaults into preview mode (SPEC 10:
    /// previewing is the point of this feature); for content that is not a
    /// recognized preview format the runtime simply keeps showing source.
    private func preparePreviewIfNeeded(
        runtime: EditorTabRuntime,
        tabID: EditorTabID,
        snapshot: SourceSnapshot
    ) {
        let kind = PreviewContentDetector.detect(
            pathExtension: (runtime.relativePath as NSString).pathExtension,
            contentPrefix: snapshot.utf8Data.prefix(4_096)
        )
        runtime.buildPreview(
            kind: kind,
            data: snapshot.utf8Data,
            theme: appearanceCenter.snapshot.theme,
            fontSettings: appearanceCenter.snapshot.fontSettings,
            isWorkspaceTrusted: isWorkspaceTrusted,
            documentRelativePath: runtime.relativePath,
            loadLocalResource: loadPreviewResourceData,
            openLocalRelativePath: onOpenLocalRelativePath
        ) { [weak self] readyRuntime in
            guard let self, self.runtimes.owns(readyRuntime, for: tabID) else {
                return
            }
            guard self.state.selectedTabID == tabID else {
                return
            }
            self.showContent(readyRuntime.displayedController)
            self.notifyPreviewSourceControlChange()
        }
    }

    public var previewSourceControlState: EditorPreviewSourceControlState {
        guard let tabID = state.selectedTabID, let runtime = runtimes[tabID] else {
            return .unavailable
        }
        return runtime.previewSourceControlState
    }

    private func notifyPreviewSourceControlChange() {
        onPreviewSourceControlChange?(groupID, previewSourceControlState)
    }

    /// The real Source/Preview toggle entry point (SPEC 5.7's preview
    /// toggle in the primary open → search → navigate → diagnose → diff
    /// → preview workflow), routed here by the window toolbar, main menu,
    /// and keyboard shortcut.
    public func togglePreviewSource(_ sender: Any?) {
        guard let tabID = state.selectedTabID,
              let runtime = runtimes[tabID],
              !runtime.isPreviewOnly else {
            return
        }
        runtime.togglePrefersPreview()
        showContent(runtime.displayedController)
        notifyPreviewSourceControlChange()
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
        case quickDiff
        case none
    }

    func displayedContentKind(forTabID tabID: EditorTabID) -> DisplayedContentKind {
        guard let runtime = runtimes[tabID] else {
            return .none
        }
        switch runtime.content {
        case .loading, .tombstone:
            return .none
        case .source:
            return .source
        case .sourceWithPreview:
            return runtime.prefersPreview ? .preview : .source
        case .previewOnly:
            return .preview
        case .diff:
            return .diff
        case .quickDiff:
            return .quickDiff
        }
    }

    /// Test-facing accessor for a tab's whole content state, so a test can
    /// assert on the case a tab is actually in rather than inferring it
    /// from several separate accessors.
    func content(forTabID tabID: EditorTabID) -> EditorTabContent? {
        runtimes[tabID]?.content
    }

    func previewController(forTabID tabID: EditorTabID) -> PreviewViewController? {
        runtimes[tabID]?.previewController
    }

    func diffController(forTabID tabID: EditorTabID) -> GitDiffViewController? {
        runtimes[tabID]?.diffController
    }

    func previewKind(forTabID tabID: EditorTabID) -> PreviewKind? {
        runtimes[tabID]?.previewKind
    }

    /// Opens `relativePath` as a preview-only tab, creating it if needed.
    /// Used when source decoding fails but raw bytes identify a supported
    /// image or binary property list.
    public func openPreviewOnlyTab(
        relativePath: String,
        pinned: Bool,
        kind: PreviewKind,
        preview: PreviewViewController
    ) {
        let tabID: EditorTabID
        if let existing = state.tabs.first(where: { $0.relativePath == relativePath }) {
            tabID = existing.id
        } else {
            tabID = openStateTab(relativePath: relativePath, pinned: pinned)
        }
        let runtime = runtimes.runtime(for: tabID, relativePath: relativePath)
        notifyDocumentsClosed(
            runtime.showPreviewOnly(preview, kind: kind),
            path: runtime.relativePath
        )
        state.selectedTabID = tabID
        showContent(preview)
        recordCurrentNavigation()
        refreshTabBar()
        notifyPreviewSourceControlChange()
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
        makePaneContentFlexible(contentView)
        contentHost.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: contentHost.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor)
        ])
        onActiveDocumentChange?(currentDocumentController)
    }

    private func makePaneContentFlexible(_ view: NSView) {
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.subviews.forEach { self.makePaneContentFlexible($0) }
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
                self.moveTab(tabID, toIndex: index)
            },
            onExternalDragUpdate: { [weak self] tabID, windowLocation in
                guard let self else { return nil }
                return self.onTabDragUpdate?(self.groupID, tabID, windowLocation)
            },
            onExternalDrop: { [weak self] tabID, preview in
                guard let self else { return false }
                return self.onTabDrop?(self.groupID, tabID, preview) ?? false
            },
            onDragEnd: { [weak self] in
                guard let self else { return }
                self.onTabDragEnd?(self.groupID)
            }
        )
    }
}
