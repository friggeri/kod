import AppKit
import CodeViewport
import DiagnosticsCore
import GitCore
import LanguageAdapters
import LanguageClient
import PreviewCore
import SourceModel
import WorkspaceCore

private extension NSToolbarItem.Identifier {
    static let workspaceToggleSidebar = NSToolbarItem.Identifier(
        "workspace.toggleSidebar"
    )
    static let workspaceSplitControls = NSToolbarItem.Identifier(
        "workspace.splitControls"
    )
    static let workspacePreviewSource = NSToolbarItem.Identifier(
        "workspace.previewSource"
    )
}

private final class WorkspaceTitleOverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
private final class WorkspacePreviewSourceControlView: NSButton {
    private weak var toolbarItem: NSToolbarItem?

    init(target: WorkspaceViewController, toolbarItem: NSToolbarItem) {
        self.toolbarItem = toolbarItem
        let label = Localized.string(
            "Toggle Source and Preview",
            comment: "Accessibility label for the titlebar preview/source toggle button"
        )
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 28))

        identifier = NSUserInterfaceItemIdentifier("workspace.previewSourceToggle")
        image = NSImage(
            systemSymbolName: "eye",
            accessibilityDescription: label
        )
        self.target = target
        action = #selector(WorkspaceViewController.togglePreviewSource(_:))
        bezelStyle = .toolbar
        isBordered = false
        imageScaling = .scaleProportionallyDown
        setAccessibilityRole(.button)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 32),
            heightAnchor.constraint(equalToConstant: 28)
        ])
        update(.unavailable)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func update(_ state: EditorPreviewSourceControlState) {
        let actionTitle: String
        let stateDescription: String
        let symbolName: String

        switch state {
        case .unavailable, .previewOnly:
            toolbarItem?.isEnabled = false
            isEnabled = false
            alphaValue = 0
            setAccessibilityElement(false)
            return
        case .showingPreview:
            actionTitle = Localized.string(
                "View Source",
                comment: "Titlebar button label when currently showing the preview, offering to switch to source"
            )
            stateDescription = Localized.string(
                "Showing Preview",
                comment: "Accessibility value for the titlebar preview/source toggle when a preview is shown"
            )
            symbolName = "chevron.left.forwardslash.chevron.right"
        case .showingSource:
            actionTitle = Localized.string(
                "View Preview",
                comment: "Titlebar button label when currently showing source, offering to switch to preview"
            )
            stateDescription = Localized.string(
                "Showing Source",
                comment: "Accessibility value for the titlebar preview/source toggle when source is shown"
            )
            symbolName = "eye"
        }

        image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: actionTitle
        )
        toolbarItem?.label = actionTitle
        toolbarItem?.toolTip = actionTitle
        toolbarItem?.isEnabled = true
        toolTip = actionTitle
        setAccessibilityLabel(actionTitle)
        setAccessibilityValue(stateDescription)
        setAccessibilityElement(true)
        alphaValue = 1
        isEnabled = true
    }
}

@MainActor
private final class WorkspaceSplitControlsView: NSView {
    private let divider = NSView()

    init(target: WorkspaceViewController) {
        super.init(frame: NSRect(x: 0, y: 0, width: 65, height: 28))

        let splitRightButton = Self.makeButton(
            symbolName: "square.split.2x1",
            identifier: "editorGroup.splitRight",
            accessibilityLabel: Localized.string(
                "Split Right",
                comment: "Accessibility label for the titlebar split-editor-right button"
            ),
            target: target,
            action: #selector(WorkspaceViewController.splitActiveGroupRight(_:))
        )
        let splitDownButton = Self.makeButton(
            symbolName: "square.split.1x2",
            identifier: "editorGroup.splitDown",
            accessibilityLabel: Localized.string(
                "Split Down",
                comment: "Accessibility label for the titlebar split-editor-down button"
            ),
            target: target,
            action: #selector(WorkspaceViewController.splitActiveGroupDown(_:))
        )

        identifier = NSUserInterfaceItemIdentifier("workspace.splitControls")
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5

        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false

        addSubview(splitRightButton)
        addSubview(divider)
        addSubview(splitDownButton)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 65),
            heightAnchor.constraint(equalToConstant: 28),
            splitRightButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitRightButton.topAnchor.constraint(equalTo: topAnchor),
            splitRightButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            splitRightButton.widthAnchor.constraint(equalToConstant: 32),
            divider.leadingAnchor.constraint(equalTo: splitRightButton.trailingAnchor),
            divider.centerYAnchor.constraint(equalTo: centerYAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 16),
            splitDownButton.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            splitDownButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitDownButton.topAnchor.constraint(equalTo: topAnchor),
            splitDownButton.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private static func makeButton(
        symbolName: String,
        identifier: String,
        accessibilityLabel: String,
        target: AnyObject,
        action: Selector
    ) -> NSButton {
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityLabel
        ) ?? NSImage()
        let button = NSButton(image: image, target: target, action: action)
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.bezelStyle = .toolbar
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = accessibilityLabel
        button.setAccessibilityLabel(accessibilityLabel)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func updateAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = (
            isDark
                ? NSColor.white.withAlphaComponent(0.10)
                : NSColor.black.withAlphaComponent(0.065)
        ).cgColor
        layer?.borderColor = (
            isDark
                ? NSColor.white.withAlphaComponent(0.12)
                : NSColor.black.withAlphaComponent(0.08)
        ).cgColor
        divider.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
    }
}

@MainActor
private final class WorkspaceToolbarDelegate: NSObject, NSToolbarDelegate {
    weak var target: WorkspaceViewController?

    init(target: WorkspaceViewController) {
        self.target = target
    }

    func toolbarAllowedItemIdentifiers(
        _ toolbar: NSToolbar
    ) -> [NSToolbarItem.Identifier] {
        [
            .workspaceToggleSidebar,
            .sidebarTrackingSeparator,
            .workspacePreviewSource,
            .workspaceSplitControls,
            .flexibleSpace
        ]
    }

    func toolbarDefaultItemIdentifiers(
        _ toolbar: NSToolbar
    ) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            .workspaceToggleSidebar,
            .sidebarTrackingSeparator,
            .flexibleSpace,
            .workspacePreviewSource,
            .workspaceSplitControls
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let target else {
            return nil
        }

        if itemIdentifier == .workspacePreviewSource {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.target = target
            item.action = #selector(WorkspaceViewController.togglePreviewSource(_:))
            item.label = Localized.string(
                "Toggle Source and Preview",
                comment: "Label for the titlebar preview/source toolbar item"
            )
            item.view = target.makePreviewSourceControlView(toolbarItem: item)
            item.visibilityPriority = .high
            return item
        }

        if itemIdentifier == .workspaceSplitControls {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = Localized.string(
                "Split Editor",
                comment: "Label for the grouped titlebar split-editor controls"
            )
            item.view = WorkspaceSplitControlsView(target: target)
            item.visibilityPriority = .high
            return item
        }

        guard itemIdentifier == .workspaceToggleSidebar else {
            return nil
        }

        let image = NSImage(
            systemSymbolName: "sidebar.left",
            accessibilityDescription: Localized.string(
                "Toggle Sidebar",
                comment: "Accessibility description for the workspace titlebar button that shows or hides the sidebar"
            )
        ) ?? NSImage()
        let button = NSButton(image: image, target: target, action: #selector(WorkspaceViewController.toggleSidebar(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("workspace.toggleSidebar")
        button.bezelStyle = .toolbar
        button.setAccessibilityLabel(
            Localized.string(
                "Toggle Sidebar",
                comment: "Accessibility label for the workspace titlebar button that shows or hides the sidebar"
            )
        )

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = Localized.string(
            "Toggle Sidebar",
            comment: "Label for the workspace titlebar sidebar toggle item"
        )
        item.toolTip = button.accessibilityLabel()
        item.view = button
        item.visibilityPriority = .high
        return item
    }
}

@MainActor
final class WorkspaceViewController: NSViewController {
    private static let defaultSidebarWidth: CGFloat = 240
    private static let minimumSidebarWidth: CGFloat = 180
    private static let maximumSidebarWidth: CGFloat = 420

    let identity: WorkspaceIdentity

    let filenameIndex = FilenameIndex()
    private let scanner = WorkspaceScanner()
    private let trustStore: WorkspaceTrustStore
    private let layoutStore: WorkspaceLayoutStore
    /// Shared, app-lifetime bounded diagnostics log (SPEC 15), injected
    /// from `AppDelegate` (or a caller-supplied default for tests/
    /// standalone construction) and threaded into every subsystem
    /// coordinator this controller owns that has a real, existing
    /// failure/degraded path worth recording — never a per-workspace
    /// instance, so a support bundle/Diagnostics viewer sees events from
    /// every workspace opened in this app run.
    let diagnosticsLog: BoundedEventLog
    private let outlineView = NSOutlineView()
    private let statusLabel = NSTextField(labelWithString: Localized.string("Discovering files...", comment: "Status label shown in the workspace Explorer while the initial file scan is in progress"))
    private let showHiddenFilesButton = NSButton(
        checkboxWithTitle: Localized.string("Hidden", comment: "Explorer checkbox that reveals hidden files"),
        target: nil,
        action: nil
    )
    private let showIgnoredFilesButton = NSButton(
        checkboxWithTitle: Localized.string("Ignored", comment: "Explorer checkbox that reveals Git-ignored files"),
        target: nil,
        action: nil
    )
    private let workspaceBannerStack = NSStackView()
    private let trustBanner = NSStackView()
    private let trustBannerLabel = NSTextField(labelWithString: "")
    private let trustActionButton = NSButton(title: "", target: nil, action: nil)
    private let trustStatusButton = NSButton()
    private let trustDismissButton = NSButton(
        image: NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: Localized.string(
                "Dismiss Workspace Trust Banner",
                comment: "Accessibility description for the button that dismisses the workspace trust banner"
            )
        ) ?? NSImage(),
        target: nil,
        action: nil
    )
    private let languageSupportBanner = NSStackView()
    private let languageSupportBannerLabel = NSTextField(labelWithString: "")
    private let languageSupportFindButton = NSButton(
        title: Localized.string(
            "Find a Server...",
            comment: "Button title opening the public language-server directory from the missing-server banner"
        ),
        target: nil,
        action: nil
    )
    private let languageSupportChooseButton = NSButton(
        title: Localized.string(
            "Choose Existing...",
            comment: "Button title in the missing language-server banner"
        ),
        target: nil,
        action: nil
    )
    private let languageSupportSettingsButton = NSButton(
        title: Localized.string(
            "Language Support...",
            comment: "Button title opening Language Support settings from the missing-server banner"
        ),
        target: nil,
        action: nil
    )
    private let languageSupportNotNowButton = NSButton(
        title: Localized.string(
            "Not Now",
            comment: "Button title dismissing the missing language-server banner for this session"
        ),
        target: nil,
        action: nil
    )
    private var contentTopWithTrustBannerConstraint: NSLayoutConstraint?
    private var contentTopWithoutTrustBannerConstraint: NSLayoutConstraint?
    private lazy var shouldShowInitialTrustBanner =
        trustStore.claimInitialTrustBannerPresentation(for: identity)
    private var isTrustBannerDismissed = false
    private var currentMissingLanguageKey: String?
    private var currentUnknownLanguageURL: URL?
    /// The official installation-documentation URL to open when the
    /// banner's "Find a Server.../Installation Help..." button is
    /// pressed for the *currently presented* missing-server prompt. Set
    /// only when that prompt is for a known default profile with
    /// shipped guidance (`DefaultLanguageServerInstallationGuides`);
    /// `nil` for unknown/custom profiles or default profiles without
    /// guidance, which fall back to the public LSP directory.
    private var currentMissingLanguageInstallationDocumentationURL: URL?
    private var queuedMissingLanguageKeys: [String] = []
    private var queuedUnknownLanguageURLs: [URL] = []
    private var suppressedMissingLanguageKeys: Set<String> = []
    private var isPreparingMissingLanguagePrompt = false
    private var languageSupportPromptGeneration = 0
    private let sidebarModeControl = NSSegmentedControl(
        labels: [
            Localized.string("Explorer", comment: "Sidebar mode segment title for the file Explorer"),
            Localized.string("Search", comment: "Sidebar mode segment title for workspace Search"),
            Localized.string("Problems", comment: "Sidebar mode segment title for the Problems panel"),
            Localized.string("Symbols", comment: "Sidebar mode segment title for the Symbols panel"),
            Localized.string("Source Control", comment: "Sidebar mode segment title for the Source Control panel")
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let workspaceTitleLabel = NSTextField(labelWithString: "")
    private var workspaceSplitViewController: NSSplitViewController!
    private var windowToolbarDelegate: WorkspaceToolbarDelegate?
    private var previewSourceControlView: WorkspacePreviewSourceControlView?
    private var explorerContainer: NSView!
    private var searchSidebarController: SearchSidebarViewController!
    private var problemsViewController: ProblemsViewController!
    private var symbolsViewController: SymbolsViewController!
    private var sourceControlSidebarController: SourceControlSidebarViewController!
    /// Read-only Git context for this workspace (SPEC 9): `nil` for
    /// non-Git folders, kept fresh from the same FSEvents pipeline that
    /// drives Explorer/index live updates.
    private var gitCoordinator: GitWorkspaceCoordinator!
    private var gitBlamePanelController: GitBlamePanelController?
    let multiLanguageServicesCoordinator: MultiLanguageServicesCoordinator
    private let languageServerStateLabel = NSTextField(labelWithString: "")
    private let languageServerRestartButton = NSButton(
        title: Localized.string("Restart", comment: "Button title to restart the language server"),
        target: nil,
        action: nil
    )
    var entriesByParent: [String: [WorkspaceFileEntry]] = [:]
    private var nodeCache: [String: WorkspaceTreeNode] = [:]
    private var discoveryTask: Task<Void, Never>?
    private var discoveryOptions = WorkspaceDiscoveryOptions()
    private var discoveryGeneration = 0
    private var sourceLoadTask: Task<Void, Never>?
    private var quickOpenController: QuickOpenPanelController?
    private var commandPaletteController: CommandPaletteController?
    private var goToLinePanelController: GoToLinePanelController?
    private var peekPanelController: PeekPanelController?
    private var hierarchyPanelController: HierarchyPanelController?
    private var definitionNavigationTask: Task<Void, Never>?
    private lazy var languageHoverController = LanguageHoverController(
        hoverRequest: { [weak self] snapshot, utf8Offset in
            guard let self else {
                throw CancellationError()
            }
            return try await self.hover(
                snapshot: snapshot,
                utf8Offset: utf8Offset
            )
        },
        definitionRequest: { [weak self] snapshot, utf8Offset in
            guard let self else {
                throw CancellationError()
            }
            return try await self.definitionTargets(
                snapshot: snapshot,
                utf8Offset: utf8Offset
            )
        }
    )
    private var hasStartedDiscovery = false
    private var lastLanguageServerStates: [String: LanguageServerState] = [:]

    /// FSEvents-driven live updates (SPEC 5.6): incremental Explorer/index
    /// updates, automatic reload of externally modified open files into a
    /// new immutable snapshot version, and tombstone tabs for files that
    /// disappear out from under Kod.
    private var fileWatcher: WorkspaceFileWatcher?
    /// Every loaded/reloaded snapshot gets a strictly increasing version so
    /// stale in-flight syntax/navigation work for a superseded snapshot is
    /// rejected rather than shown (SPEC 5.6).
    private var nextSnapshotVersion = 1
    private var externalReloadTask: Task<Void, Never>?
    private let languageSupportService: LanguageSupportService
    private var hasRestoredWorkspaceGeometry = false
    private var lastExpandedSidebarWidth = WorkspaceViewController.defaultSidebarWidth
    private var lastNormalWindowFrame: NSRect?
    private var pendingNormalWindowFrame: NSRect?
    private var isApplyingSidebarGeometry = false
    private var pendingExpandedSidebarWidth: CGFloat?

    var layoutState: WorkspaceLayoutState
    var splitContainer: SplitContainerViewController!

    init(
        identity: WorkspaceIdentity,
        trustStore: WorkspaceTrustStore = WorkspaceTrustStore(),
        layoutStore: WorkspaceLayoutStore = WorkspaceLayoutStore(),
        diagnosticsLog: BoundedEventLog = BoundedEventLog(),
        languageSupportService: LanguageSupportService = LanguageSupportService()
    ) {
        self.identity = identity
        self.trustStore = trustStore
        self.layoutStore = layoutStore
        self.diagnosticsLog = diagnosticsLog
        self.languageSupportService = languageSupportService
        let restoredLayout = layoutStore.load(for: identity) ?? .singleGroup()
        self.layoutState = restoredLayout
        self.lastExpandedSidebarWidth = Self.clampedSidebarWidth(
            restoredLayout.geometry?.sidebarWidth
        )
        self.multiLanguageServicesCoordinator = MultiLanguageServicesCoordinator(
            identity: identity,
            trustStore: trustStore,
            profileRegistry: languageSupportService.profileRegistry,
            overrideStore: languageSupportService.overrideStore,
            diagnosticsLog: diagnosticsLog
        )
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageProfilesDidChange(_:)),
            name: .kodLanguageProfilesDidChange,
            object: languageSupportService.profileStore
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLanguageSupportChanged(_:)),
            name: .kodLanguageSupportChanged,
            object: languageSupportService
        )
        self.gitCoordinator = GitWorkspaceCoordinator(root: identity.root, diagnosticsLog: diagnosticsLog) { [weak self] snapshot in
            self?.sourceControlSidebarController.update(snapshot: snapshot)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        discoveryTask?.cancel()
        sourceLoadTask?.cancel()
        externalReloadTask?.cancel()
        fileWatcher?.stop()
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func languageProfilesDidChange(_ notification: Notification) {
        languageSupportPromptGeneration &+= 1
        languageSupportService.profileRegistry.reload()
        reloadChangedSyntaxDefinitions()
    }

    @objc
    private func handleLanguageSupportChanged(_ notification: Notification) {
        guard let languageKey = notification.languageSupportChangedKey else {
            return
        }
        switch notification.languageSupportChangeKind {
        case .profileConfiguration:
            handleLanguageProfileConfigurationChanged(languageKey: languageKey)
        case .executableDiscovery:
            handleLanguageServerExecutableDiscovered(languageKey: languageKey)
        }
    }

    /// A profile's configuration changed (edited, enabled/disabled,
    /// reset, deleted, or given an explicit executable). Reloads the
    /// profile registry and, if this affects the currently displayed
    /// missing-server/unknown-type prompt, re-resolves it — resolving a
    /// configuration change may require re-running discovery, so this is
    /// the one path allowed to call `languageSupportService.refresh()`.
    private func handleLanguageProfileConfigurationChanged(
        languageKey: String
    ) {
        languageSupportPromptGeneration &+= 1
        languageSupportService.profileRegistry.reload()
        queuedMissingLanguageKeys.removeAll { $0 == languageKey }
        if currentMissingLanguageKey == languageKey {
            Task { [weak self] in
                guard let self else {
                    return
                }
                await self.languageSupportService.refresh()
                guard self.currentMissingLanguageKey == languageKey else {
                    return
                }
                guard let item = self.languageSupportService.items.first(
                    where: { $0.id == languageKey }
                ) else {
                    self.finishMissingLanguagePrompt(
                        suppressForSession: false
                    )
                    return
                }
                switch item.serverState {
                case .available, .notConfigured:
                    self.finishMissingLanguagePrompt(
                        suppressForSession: false
                    )
                case .checking, .missing:
                    break
                }
            }
        } else if let currentUnknownLanguageURL,
                  languageSupportService.profileRegistry.resolve(
                      url: currentUnknownLanguageURL
                  ) != nil {
            finishMissingLanguagePrompt(suppressForSession: false)
        }
        multiLanguageServicesCoordinator.handleLanguageSupportChanged(
            languageKey: languageKey
        )
    }

    /// `LanguageSupportService.refresh()` discovered that `languageKey`'s
    /// executable, previously unavailable, is now available. Nothing
    /// about the profile's configuration changed, so this never reloads
    /// the profile registry or calls `refresh()` again (which would risk
    /// a notify → refresh → notify loop) — it only clears the now-stale
    /// missing-server queue/banner for this key and asks the coordinator
    /// to retry/restart the affected service. An unrelated unknown-type
    /// or different-profile prompt currently on screen is left alone.
    private func handleLanguageServerExecutableDiscovered(
        languageKey: String
    ) {
        queuedMissingLanguageKeys.removeAll { $0 == languageKey }
        if currentMissingLanguageKey == languageKey,
           let item = languageSupportService.items.first(
               where: { $0.id == languageKey }
           ),
           item.serverState.isAvailable {
            finishMissingLanguagePrompt(suppressForSession: false)
        }
        multiLanguageServicesCoordinator.handleLanguageServerExecutableAvailable(
            languageKey: languageKey
        )
    }



    override func loadView() {
        let container = NSView()
        collapseEmptyGroupsKeepingOne()

        configureTrustBanner()
        configureLanguageSupportBanner()
        configureWorkspaceBannerStack()
        trustBanner.translatesAutoresizingMaskIntoConstraints = false

        let outerSplit = NSSplitViewController()
        workspaceSplitViewController = outerSplit
        addChild(outerSplit)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(workspaceSplitViewDidResize(_:)),
            name: NSSplitView.didResizeSubviewsNotification,
            object: outerSplit.splitView
        )
        outerSplit.view.translatesAutoresizingMaskIntoConstraints = false
        let statusBar = makeStatusBar()
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        let titleOverlay = WorkspaceTitleOverlayView()
        titleOverlay.translatesAutoresizingMaskIntoConstraints = false
        workspaceTitleLabel.stringValue = identity.root.lastPathComponent
        workspaceTitleLabel.identifier = NSUserInterfaceItemIdentifier("workspace.directoryName")
        workspaceTitleLabel.alignment = .center
        workspaceTitleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        workspaceTitleLabel.lineBreakMode = .byTruncatingMiddle
        workspaceTitleLabel.setAccessibilityLabel(identity.root.lastPathComponent)
        workspaceTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        workspaceTitleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        titleOverlay.addSubview(workspaceTitleLabel)

        let sidebarController = NSViewController()
        sidebarController.view = makeSidebar()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true
        sidebarItem.titlebarSeparatorStyle = .none
        outerSplit.addSplitViewItem(sidebarItem)

        splitContainer = SplitContainerViewController(
            root: layoutState.root,
            makeGroupController: { [weak self] id in
                self?.makeGroupController(for: id)
                    ?? EditorGroupViewController(groupID: id, state: EditorGroupState(id: id))
            }
        )
        splitContainer.view.translatesAutoresizingMaskIntoConstraints = false

        let editorController = NSViewController()
        let editorContainer = NSView()
        editorContainer.identifier = NSUserInterfaceItemIdentifier("workspace.editorArea")
        editorController.view = editorContainer
        editorController.addChild(splitContainer)
        workspaceBannerStack.translatesAutoresizingMaskIntoConstraints = false
        editorContainer.addSubview(workspaceBannerStack)
        editorContainer.addSubview(splitContainer.view)
        outerSplit.addSplitViewItem(NSSplitViewItem(viewController: editorController))

        container.addSubview(outerSplit.view)
        container.addSubview(statusBar)
        container.addSubview(titleOverlay)

        let contentTopWithTrustBannerConstraint = splitContainer.view.topAnchor.constraint(
            equalTo: workspaceBannerStack.bottomAnchor,
            constant: 8
        )
        let contentTopWithoutTrustBannerConstraint = splitContainer.view.topAnchor.constraint(
            equalTo: editorContainer.safeAreaLayoutGuide.topAnchor
        )
        self.contentTopWithTrustBannerConstraint = contentTopWithTrustBannerConstraint
        self.contentTopWithoutTrustBannerConstraint = contentTopWithoutTrustBannerConstraint

        NSLayoutConstraint.activate([
            workspaceBannerStack.topAnchor.constraint(
                equalTo: editorContainer.safeAreaLayoutGuide.topAnchor,
                constant: 8
            ),
            workspaceBannerStack.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor, constant: 8),
            workspaceBannerStack.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor, constant: -8),
            trustBanner.heightAnchor.constraint(equalTo: trustActionButton.heightAnchor, constant: 12),
            splitContainer.view.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
            splitContainer.view.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
            splitContainer.view.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor),
            outerSplit.view.topAnchor.constraint(equalTo: container.topAnchor),
            outerSplit.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            outerSplit.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            outerSplit.view.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 29),
            titleOverlay.topAnchor.constraint(equalTo: container.topAnchor),
            titleOverlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            titleOverlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            titleOverlay.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            workspaceTitleLabel.centerXAnchor.constraint(equalTo: titleOverlay.centerXAnchor),
            workspaceTitleLabel.centerYAnchor.constraint(equalTo: titleOverlay.centerYAnchor)
        ])
        updateTrustBannerVisibility()

        view = container
        refreshActiveGroupHighlighting()
        refreshLanguageServerStateUI()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        configureWindowChrome()
        view.window?.delegate = self
        restoreWorkspaceGeometryIfNeeded()
        guard !hasStartedDiscovery else {
            return
        }
        hasStartedDiscovery = true
        startDiscovery()
        configureLanguageServicesCoordinator()
        startGitCoordinator()
    }

    @objc
    func toggleSidebar(_ sender: Any?) {
        let sidebarItem = workspaceSplitViewController.splitViewItems.first
        let wasCollapsed = sidebarItem?.isCollapsed == true
        let widthToRestore = lastExpandedSidebarWidth
        if !wasCollapsed {
            pendingExpandedSidebarWidth = nil
            isApplyingSidebarGeometry = false
            captureExpandedSidebarWidth()
        }
        if wasCollapsed {
            isApplyingSidebarGeometry = true
            pendingExpandedSidebarWidth = widthToRestore
            prepareSidebarWidth(widthToRestore)
        }
        workspaceSplitViewController.toggleSidebar(sender)
        if wasCollapsed {
            DispatchQueue.main.async { [weak self] in
                self?.applyPendingExpandedSidebarWidthIfPossible()
            }
        }
    }

    fileprivate func makePreviewSourceControlView(toolbarItem: NSToolbarItem) -> NSView {
        let control = WorkspacePreviewSourceControlView(target: self, toolbarItem: toolbarItem)
        previewSourceControlView = control
        refreshPreviewSourceToolbar()
        return control
    }

    private func refreshPreviewSourceToolbar() {
        previewSourceControlView?.update(
            activeGroupController?.previewSourceControlState ?? .unavailable
        )
    }

    private func configureWindowChrome() {
        guard let window = view.window else {
            return
        }

        window.styleMask.insert(.fullSizeContentView)
        window.title = identity.root.lastPathComponent
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified

        let delegate = WorkspaceToolbarDelegate(target: self)
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("workspace.toolbar"))
        toolbar.delegate = delegate
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        windowToolbarDelegate = delegate
        window.toolbar = toolbar
        window.layoutIfNeeded()
        refreshPreviewSourceToolbar()
    }

    func restoreWorkspaceGeometryIfNeeded() {
        guard !hasRestoredWorkspaceGeometry, let window = view.window else {
            return
        }
        hasRestoredWorkspaceGeometry = true

        guard let geometry = layoutState.geometry else {
            if !window.styleMask.contains(.fullScreen) {
                lastNormalWindowFrame = window.frame
            }
            return
        }

        let restoredFrame = Self.constrainedWindowFrame(
            geometry.windowFrame,
            minimumSize: window.minSize,
            visibleScreenFrames: NSScreen.screens.map(\.visibleFrame),
            fallbackVisibleFrame: window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        )
        if let restoredFrame {
            if window.styleMask.contains(.fullScreen) {
                pendingNormalWindowFrame = restoredFrame
            } else {
                window.setFrame(restoredFrame, display: true)
            }
            lastNormalWindowFrame = restoredFrame
        }

        window.layoutIfNeeded()
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.view.window === window else {
                return
            }
            window.layoutIfNeeded()
            self.restoreSidebarGeometry(geometry)
        }
    }

    private func restoreSidebarGeometry(_ geometry: WorkspaceGeometryState) {
        guard let sidebarItem = workspaceSplitViewController.splitViewItems.first else {
            return
        }

        let width = Self.clampedSidebarWidth(geometry.sidebarWidth)
        isApplyingSidebarGeometry = true
        defer {
            isApplyingSidebarGeometry = false
        }
        lastExpandedSidebarWidth = width
        sidebarItem.isCollapsed = false
        applySidebarWidth(width)
        sidebarItem.isCollapsed = geometry.isSidebarCollapsed
        lastExpandedSidebarWidth = width
    }

    private func applySidebarWidth(_ width: CGFloat) {
        prepareSidebarWidth(width)
        guard let sidebarItem = workspaceSplitViewController.splitViewItems.first else {
            return
        }
        guard !sidebarItem.isCollapsed else {
            return
        }
        let splitView = workspaceSplitViewController.splitView
        workspaceSplitViewController.view.layoutSubtreeIfNeeded()
        splitView.adjustSubviews()
        if splitView.arrangedSubviews.count >= 2 {
            splitView.setPosition(width, ofDividerAt: 0)
        }
        lastExpandedSidebarWidth = width
    }

    private func prepareSidebarWidth(_ width: CGFloat) {
        lastExpandedSidebarWidth = width
        let splitView = workspaceSplitViewController.splitView
        guard splitView.bounds.width > 0 else {
            return
        }
        workspaceSplitViewController.splitViewItems.first?.preferredThicknessFraction =
            min(max(width / splitView.bounds.width, 0), 1)
    }

    private func applyPendingExpandedSidebarWidthIfPossible() {
        guard let width = pendingExpandedSidebarWidth,
              workspaceSplitViewController.splitViewItems.first?.isCollapsed == false else {
            return
        }
        pendingExpandedSidebarWidth = nil
        applySidebarWidth(width)
        isApplyingSidebarGeometry = false
    }

    @objc
    private func workspaceSplitViewDidResize(_ notification: Notification) {
        if pendingExpandedSidebarWidth != nil {
            applyPendingExpandedSidebarWidthIfPossible()
            return
        }
        guard !isApplyingSidebarGeometry else {
            return
        }
        captureExpandedSidebarWidth()
    }

    private func captureExpandedSidebarWidth() {
        guard let sidebarItem = workspaceSplitViewController?.splitViewItems.first,
              !sidebarItem.isCollapsed else {
            return
        }
        let width = sidebarPaneWidth(for: sidebarItem)
        guard width.isFinite, width > 0 else {
            return
        }
        lastExpandedSidebarWidth = Self.clampedSidebarWidth(Double(width))
        let totalWidth = workspaceSplitViewController.splitView.bounds.width
        if totalWidth > 0 {
            sidebarItem.preferredThicknessFraction = min(
                max(lastExpandedSidebarWidth / totalWidth, 0),
                1
            )
        }
    }

    private func sidebarPaneWidth(for sidebarItem: NSSplitViewItem) -> CGFloat {
        let splitView = workspaceSplitViewController.splitView
        return splitView.arrangedSubviews.first?.frame.width
            ?? sidebarItem.viewController.view.frame.width
    }

    private func captureWorkspaceGeometry() {
        guard isViewLoaded, let window = view.window else {
            return
        }

        let isFullScreen = window.styleMask.contains(.fullScreen)
        let normalFrame = Self.normalWindowFrame(
            currentFrame: window.frame,
            isFullScreen: isFullScreen,
            lastNormalFrame: lastNormalWindowFrame,
            persistedFrame: layoutState.geometry?.windowFrame
        )
        if !isFullScreen {
            lastNormalWindowFrame = window.frame
        }
        guard let normalFrame else {
            return
        }

        captureExpandedSidebarWidth()
        let isSidebarCollapsed = workspaceSplitViewController.splitViewItems.first?.isCollapsed ?? false
        layoutState.geometry = WorkspaceGeometryState(
            windowFrame: WorkspaceWindowFrame(
                x: Double(normalFrame.origin.x),
                y: Double(normalFrame.origin.y),
                width: Double(normalFrame.width),
                height: Double(normalFrame.height)
            ),
            sidebarWidth: Double(lastExpandedSidebarWidth),
            isSidebarCollapsed: isSidebarCollapsed
        )
    }

    static func normalWindowFrame(
        currentFrame: NSRect,
        isFullScreen: Bool,
        lastNormalFrame: NSRect?,
        persistedFrame: WorkspaceWindowFrame?
    ) -> NSRect? {
        if !isFullScreen {
            return currentFrame
        }
        return lastNormalFrame ?? persistedFrame.flatMap(rect(from:))
    }

    static func constrainedWindowFrame(
        _ savedFrame: WorkspaceWindowFrame,
        minimumSize: NSSize,
        visibleScreenFrames: [NSRect],
        fallbackVisibleFrame: NSRect?
    ) -> NSRect? {
        guard let candidate = rect(from: savedFrame) else {
            return nil
        }
        let screens = visibleScreenFrames.filter(isValidScreenFrame)
        guard !screens.isEmpty else {
            return nil
        }

        let bestIntersectingScreen = screens.max {
            intersectionArea(candidate, $0) < intersectionArea(candidate, $1)
        }
        let targetScreen: NSRect
        if let bestIntersectingScreen,
           intersectionArea(candidate, bestIntersectingScreen) > 0 {
            targetScreen = bestIntersectingScreen
        } else if let fallbackVisibleFrame,
                  isValidScreenFrame(fallbackVisibleFrame) {
            targetScreen = fallbackVisibleFrame
        } else {
            targetScreen = screens[0]
        }

        let width = min(max(candidate.width, minimumSize.width), targetScreen.width)
        let height = min(max(candidate.height, minimumSize.height), targetScreen.height)
        let x = min(
            max(candidate.minX, targetScreen.minX),
            targetScreen.maxX - width
        )
        let y = min(
            max(candidate.minY, targetScreen.minY),
            targetScreen.maxY - height
        )
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private static func rect(from frame: WorkspaceWindowFrame) -> NSRect? {
        let values = [frame.x, frame.y, frame.width, frame.height]
        guard values.allSatisfy(\.isFinite), frame.width > 0, frame.height > 0 else {
            return nil
        }
        return NSRect(
            x: frame.x,
            y: frame.y,
            width: frame.width,
            height: frame.height
        )
    }

    private static func isValidScreenFrame(_ frame: NSRect) -> Bool {
        let values = [
            frame.origin.x,
            frame.origin.y,
            frame.width,
            frame.height
        ]
        return values.allSatisfy(\.isFinite) && frame.width > 0 && frame.height > 0
    }

    private static func intersectionArea(_ first: NSRect, _ second: NSRect) -> CGFloat {
        let intersection = first.intersection(second)
        guard !intersection.isNull else {
            return 0
        }
        return max(0, intersection.width) * max(0, intersection.height)
    }

    private static func clampedSidebarWidth(_ width: Double?) -> CGFloat {
        guard let width, width.isFinite else {
            return defaultSidebarWidth
        }
        return min(max(CGFloat(width), minimumSidebarWidth), maximumSidebarWidth)
    }

    // MARK: - Git (SPEC 9)

    private func startGitCoordinator() {
        Task { [weak self] in
            await self?.gitCoordinator.start()
        }
    }

    /// Reveals the Source Control sidebar (mirrors `searchWorkspace(_:)`).
    @objc
    func showSourceControl(_ sender: Any?) {
        sidebarModeControl.selectedSegment = 4
        sidebarModeChanged(nil)
    }

    /// Reveals the Problems sidebar — the "diagnose" step of the primary
    /// open → search → navigate → diagnose → diff → preview workflow
    /// (SPEC 5.7) — as a real, menu-reachable command rather than only
    /// via Tab-then-arrow-keys to `sidebarModeControl`.
    @objc
    func showProblems(_ sender: Any?) {
        sidebarModeControl.selectedSegment = 2
        sidebarModeChanged(nil)
    }

    /// Reveals the Symbols sidebar (mirrors `showProblems(_:)`).
    @objc
    func showSymbols(_ sender: Any?) {
        sidebarModeControl.selectedSegment = 3
        sidebarModeChanged(nil)
    }

    /// Toggles the active tab's Source/Preview mode from the window toolbar,
    /// main menu, or keyboard shortcut (SPEC 5.7).
    @objc
    func togglePreviewSource(_ sender: Any?) {
        activeGroupController?.togglePreviewSource(sender)
    }

    private func openDiff(for selection: SourceControlSidebarViewController.FileSelection) {
        guard let context = gitCoordinator.context, let groupController = activeGroupController else {
            return
        }
        Task {
            do {
                let diff = try await context.diff(
                    path: selection.path,
                    target: selection.target,
                    isUntracked: selection.isUntracked,
                    knownOldPath: selection.originalPath
                )
                groupController.openDiffTab(relativePath: selection.path, diff: diff)
            } catch {
                await diagnosticsLog.record(
                    subsystem: .git,
                    level: .warning,
                    message: Localized.string(
                        "Git diff loading failed",
                        comment: "Diagnostics log message recorded when loading a Git diff fails"
                    ),
                    context: [
                        DiagnosticContextField(name: "workspaceRoot", category: .fullPath, value: identity.root.path),
                        DiagnosticContextField(
                            name: "path",
                            category: .fullPath,
                            value: identity.root.appendingPathComponent(selection.path).path
                        ),
                        DiagnosticContextField(name: "reason", category: .diagnosticMessage, value: String(describing: error))
                    ]
                )
            }
        }
    }

    /// Shows blame for the currently selected Explorer file (wired to the
    /// Explorer outline's contextual menu).
    @objc
    func showGitBlameForSelectedFile(_ sender: Any?) {
        guard let node = outlineView.item(atRow: outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow) as? WorkspaceTreeNode,
              node.entry.kind == .file,
              let context = gitCoordinator.context,
              let window = view.window else {
            return
        }
        let relativePath = node.entry.relativePath
        Task {
            guard let result = try? await context.blame(path: relativePath) else {
                return
            }
            let panel = GitBlamePanelController(title: relativePath)
            gitBlamePanelController = panel
            panel.show(result: result, asSheetFor: window)
        }
    }

    // MARK: - Language services (LSP)

    private func workspaceSymbols(query: String) async throws -> [WorkspaceSymbolLocation] {
        guard let url = activeGroupController?.currentDocumentController?.snapshot.url else {
            return []
        }
        return try await multiLanguageServicesCoordinator.workspaceSymbols(
            forURL: url,
            query: query
        )
    }

    private func configureLanguageServicesCoordinator() {
        multiLanguageServicesCoordinator.onStateChange = { [weak self] in
            self?.languageServerStateDidChange()
        }
        multiLanguageServicesCoordinator.onDiagnostics = { [weak self] url, diagnostics in
            self?.problemsViewController.update(url: url, diagnostics: diagnostics)
        }
        multiLanguageServicesCoordinator.onMissingServer = { [weak self] profile in
            self?.enqueueMissingLanguageServer(profile)
        }
        multiLanguageServicesCoordinator.onUnknownFileType = { [weak self] url in
            self?.enqueueUnknownLanguageProfile(for: url)
        }
        refreshLanguageServerStateUI()
    }

    private func enqueueMissingLanguageServer(
        _ profile: LanguageProfile
    ) {
        let languageKey = profile.identifier
        guard trustStore.isTrusted(identity),
              !suppressedMissingLanguageKeys.contains(languageKey),
              currentMissingLanguageKey != languageKey,
              !queuedMissingLanguageKeys.contains(languageKey) else {
            return
        }
        queuedMissingLanguageKeys.append(languageKey)
        Task {
            await presentNextMissingLanguageServerIfNeeded()
        }
    }

    private func enqueueUnknownLanguageProfile(for url: URL) {
        let key = unknownLanguageKey(for: url)
        guard trustStore.isTrusted(identity),
              !url.pathExtension.isEmpty,
              !suppressedMissingLanguageKeys.contains(key),
              currentMissingLanguageKey != key,
              !queuedUnknownLanguageURLs.contains(url) else {
            return
        }
        queuedUnknownLanguageURLs.append(url)
        Task {
            await presentNextMissingLanguageServerIfNeeded()
        }
    }

    private func presentNextMissingLanguageServerIfNeeded() async {
        guard currentMissingLanguageKey == nil,
              !isPreparingMissingLanguagePrompt else {
            return
        }
        isPreparingMissingLanguagePrompt = true
        defer { isPreparingMissingLanguagePrompt = false }

        while trustStore.isTrusted(identity),
              !queuedMissingLanguageKeys.isEmpty {
            let languageKey = queuedMissingLanguageKeys.removeFirst()
            guard !suppressedMissingLanguageKeys.contains(languageKey) else {
                continue
            }

            let promptGeneration = languageSupportPromptGeneration
            await languageSupportService.refresh()
            guard !Task.isCancelled, trustStore.isTrusted(identity) else {
                return
            }
            guard promptGeneration == languageSupportPromptGeneration else {
                if !queuedMissingLanguageKeys.contains(languageKey) {
                    queuedMissingLanguageKeys.insert(languageKey, at: 0)
                }
                continue
            }
            guard let item = languageSupportService.items.first(where: {
                $0.id == languageKey
            }) else {
                continue
            }
            if case .available = item.serverState {
                continue
            }

            currentMissingLanguageKey = languageKey
            currentUnknownLanguageURL = nil
            languageSupportChooseButton.title = Localized.string(
                "Choose Executable...",
                comment: "Button title selecting a local executable from the missing language-server banner"
            )
            languageSupportBannerLabel.stringValue = Localized.string(
                "No \(item.profile.displayName) server was found. Syntax highlighting remains available.",
                comment: "Missing language-server banner message"
            )
            languageSupportBannerLabel.toolTip = languageSupportBannerLabel.stringValue
            if let guide = item.profile.origin == .default
                ? DefaultLanguageServerInstallationGuides.guide(
                    for: item.profile
                )
                : nil {
                currentMissingLanguageInstallationDocumentationURL =
                    guide.documentationURL
                languageSupportFindButton.title = Localized.string(
                    "Installation Help...",
                    comment: "Button title opening a known language server's official installation documentation from the missing-server banner"
                )
                languageSupportFindButton.toolTip = Localized.string(
                    "Opens \(item.profile.displayName)'s official installation documentation.",
                    comment: "Tooltip for the missing language-server Installation Help button"
                )
            } else {
                currentMissingLanguageInstallationDocumentationURL = nil
                languageSupportFindButton.title = Localized.string(
                    "Find a Server...",
                    comment: "Button title opening the public language-server directory from the missing-server banner"
                )
                languageSupportFindButton.toolTip = Localized.string(
                    "Open the public LSP server directory.",
                    comment: "Tooltip for the missing language-server Find a Server button"
                )
            }
            languageSupportBanner.setAccessibilityLabel(
                languageSupportBannerLabel.stringValue
            )
            languageSupportBanner.isHidden = false
            updateWorkspaceBannerVisibility()
            return
        }

        while trustStore.isTrusted(identity),
              !queuedUnknownLanguageURLs.isEmpty {
            let url = queuedUnknownLanguageURLs.removeFirst()
            let key = unknownLanguageKey(for: url)
            guard !suppressedMissingLanguageKeys.contains(key) else {
                continue
            }
            guard languageSupportService.profileRegistry.resolve(url: url) == nil else {
                continue
            }
            currentMissingLanguageKey = key
            currentUnknownLanguageURL = url
            currentMissingLanguageInstallationDocumentationURL = nil
            languageSupportChooseButton.title = Localized.string(
                "Add Profile...",
                comment: "Button title creating a language profile for an unknown file type"
            )
            languageSupportBannerLabel.stringValue = Localized.string(
                "No language profile matches *.\(url.pathExtension.lowercased()). Plain Text remains available.",
                comment: "Unknown file type banner message"
            )
            languageSupportBannerLabel.toolTip =
                languageSupportBannerLabel.stringValue
            languageSupportFindButton.title = Localized.string(
                "Find a Server...",
                comment: "Button title opening the public language-server directory from the missing-server banner"
            )
            languageSupportFindButton.toolTip = Localized.string(
                "Open the public LSP server directory.",
                comment: "Tooltip for the missing language-server Find a Server button"
            )
            languageSupportBanner.setAccessibilityLabel(
                languageSupportBannerLabel.stringValue
            )
            languageSupportBanner.isHidden = false
            updateWorkspaceBannerVisibility()
            return
        }
    }

    private func finishMissingLanguagePrompt(
        suppressForSession: Bool
    ) {
        if suppressForSession, let currentMissingLanguageKey {
            suppressedMissingLanguageKeys.insert(currentMissingLanguageKey)
        }
        currentMissingLanguageKey = nil
        currentUnknownLanguageURL = nil
        currentMissingLanguageInstallationDocumentationURL = nil
        languageSupportBanner.isHidden = true
        updateWorkspaceBannerVisibility()
        Task {
            await presentNextMissingLanguageServerIfNeeded()
        }
    }

    @objc
    private func dismissMissingLanguageServer(_ sender: Any?) {
        finishMissingLanguagePrompt(suppressForSession: true)
    }

    @objc
    private func openLanguageSupportSettings(_ sender: Any?) {
        if let currentUnknownLanguageURL {
            languageSupportService.beginAddingProfile(
                prefilling: currentUnknownLanguageURL
            )
        } else {
            languageSupportService.focusProfile(
                identifier: currentMissingLanguageKey
            )
        }
        NSApp.sendAction(
            #selector(AppDelegate.showLanguageSupportSettings(_:)),
            to: nil,
            from: self
        )
    }

    @objc
    private func chooseMissingLanguageServer(_ sender: Any?) {
        if currentUnknownLanguageURL != nil {
            openLanguageSupportSettings(sender)
            return
        }
        guard let languageKey = currentMissingLanguageKey,
              let window = view.window else {
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = Localized.string(
            "Choose an existing language-server executable.",
            comment: "Open panel message for selecting a missing language server"
        )
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else {
                return
            }
            do {
                try self.languageSupportService.setSelectedExecutable(
                    profileIdentifier: languageKey,
                    url: url
                )
            } catch {
                self.languageSupportBannerLabel.stringValue =
                    error.localizedDescription
            }
        }
    }

    @objc
    private func findMissingLanguageServer(_ sender: Any?) {
        NSWorkspace.shared.open(
            currentMissingLanguageInstallationDocumentationURL
                ?? LanguageSupportService.serverDirectoryURL
        )
    }

    private func unknownLanguageKey(for url: URL) -> String {
        "unknown:\(url.pathExtension.lowercased())"
    }

    private func languageServerStateDidChange() {
        for status in multiLanguageServicesCoordinator.states {
            recordLanguageServerState(
                providerIdentifier: status.profile.identifier,
                state: status.state
            )
        }
        refreshLanguageServerStateUI()
    }

    private func recordLanguageServerState(
        providerIdentifier: String,
        state: LanguageServerState
    ) {
        defer { lastLanguageServerStates[providerIdentifier] = state }
        guard lastLanguageServerStates[providerIdentifier] != state else {
            return
        }
        switch state {
        case .missing, .starting, .stopping, .stopped, .crashed, .disabled:
            languageHoverController.invalidateCache(
                forProvider: providerIdentifier
            )
        case .indexing, .ready, .busy:
            break
        }
    }

    private func refreshLanguageServerStateUI() {
        let status = activeLanguageServerStatus()
        let state = status.state
        let prefix = status.languageName.map { "\($0) LSP" } ?? "LSP"
        languageServerStateLabel.stringValue = Localized.string(
            "\(prefix): \(state.displayName)",
            comment: "Status label showing the current language server state"
        )
        languageServerStateLabel.toolTip = stateReason(state)
        // Explicit label/value pair (SPEC 14): color alone (`.systemRed`
        // for crashed/disabled) never carries the state — the label text
        // already spells it out, but an explicit accessibility label
        // distinct from the raw `stringValue` makes clear *what* the
        // value describes ("Language server status", not just "LSP:
        // Crashed" read as an opaque string).
        languageServerStateLabel.setAccessibilityLabel(
            Localized.string("Language server status", comment: "Accessibility label describing what the language server state value represents")
        )
        languageServerStateLabel.setAccessibilityValue(state.displayName)
        switch state {
        case .crashed, .disabled:
            languageServerStateLabel.textColor = .systemRed
            languageServerRestartButton.isEnabled = trustStore.isTrusted(identity)
        case .missing:
            languageServerStateLabel.textColor = .secondaryLabelColor
            languageServerRestartButton.isEnabled = status.languageName != nil
                && trustStore.isTrusted(identity)
        default:
            languageServerStateLabel.textColor = .secondaryLabelColor
            languageServerRestartButton.isEnabled = true
        }
    }

    @objc
    private func restartLanguageServer(_ sender: Any?) {
        guard let url = activeGroupController?.currentDocumentController?.snapshot.url else {
            return
        }
        languageHoverController.invalidateCache(
            forProvider: languageProviderIdentifier(for: url)
        )
        multiLanguageServicesCoordinator.restart(forURL: url)
    }

    private func activeLanguageServerStatus() -> (languageName: String?, state: LanguageServerState) {
        guard let url = activeGroupController?.currentDocumentController?.snapshot.url else {
            return (nil, .missing(reason: "No active source document"))
        }
        if let status = multiLanguageServicesCoordinator.status(forURL: url) {
            return status
        }
        return (nil, .missing(reason: "No language server is registered for this file type"))
    }

    private func stateReason(_ state: LanguageServerState) -> String? {
        switch state {
        case .missing(let reason), .crashed(let reason), .disabled(let reason):
            return reason
        case .starting, .indexing, .ready, .busy, .stopping, .stopped:
            return nil
        }
    }

    private func configureLanguageInteractions(for controller: CodeDocumentViewController) {
        controller.viewport.onCommandClick = { [weak self, weak controller] utf8Offset in
            guard let self, let controller else {
                return
            }
            self.performDefinitionNavigation(from: controller, utf8Offset: utf8Offset)
        }
        controller.viewport.onLinkClick = { [weak self, weak controller] utf8Offset in
            guard let self, let controller else {
                return
            }
            self.performDefinitionNavigation(from: controller, utf8Offset: utf8Offset)
        }
        controller.viewport.onHover = { [weak self, weak controller] utf8Offset, targetRange, anchorRect in
            guard let self, let controller else {
                return
            }
            self.languageHoverController.update(
                controller: controller,
                providerIdentifier: self.languageProviderIdentifier(
                    for: controller.snapshot.url
                ),
                utf8Offset: utf8Offset,
                targetRange: targetRange,
                anchorRect: anchorRect
            )
        }
        controller.viewport.onHoverExit = { [weak self, weak controller] in
            guard let controller else {
                return
            }
            self?.cancelHover(for: controller)
        }
    }

    private func cancelHover(for controller: CodeDocumentViewController? = nil) {
        languageHoverController.cancel(for: controller)
    }

    private func hover(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> Hover? {
        return try await multiLanguageServicesCoordinator.hover(
            snapshot: snapshot,
            utf8Offset: utf8Offset
        )
    }

    private func definitionTargets(
        snapshot: SourceSnapshot,
        utf8Offset: Int
    ) async throws -> [NavigationTarget] {
        return try await multiLanguageServicesCoordinator.definition(
            snapshot: snapshot,
            utf8Offset: utf8Offset
        )
    }

    private func performDefinitionNavigation(
        from controller: CodeDocumentViewController,
        utf8Offset: Int
    ) {
        definitionNavigationTask?.cancel()
        definitionNavigationTask = nil
        let providerIdentifier = languageProviderIdentifier(
            for: controller.snapshot.url
        )
        switch languageHoverController.cachedDefinitions(
            controller: controller,
            providerIdentifier: providerIdentifier,
            utf8Offset: utf8Offset
        ) {
        case .resolved(let targets):
            cancelHover()
            guard let target = targets.first else {
                return
            }
            navigateToLSPLocation(url: target.url, range: target.range)
            return
        case .missing:
            break
        }
        cancelHover()
        let snapshot = controller.snapshot
        definitionNavigationTask = Task { [weak self, weak controller] in
            guard let self else {
                return
            }
            guard let targets = try? await self.definitionTargets(
                snapshot: snapshot,
                utf8Offset: utf8Offset
            ) else {
                return
            }
            guard !Task.isCancelled,
                  let controller,
                  controller.snapshot.version == snapshot.version,
                  controller.view.window != nil,
                  let target = targets.first else {
                return
            }
            self.navigateToLSPLocation(url: target.url, range: target.range)
        }
    }

    private func languageProviderIdentifier(for url: URL) -> String {
        return multiLanguageServicesCoordinator.languageKey(forURL: url)
            ?? url.pathExtension.lowercased()
    }

    /// Opens `relativePath` in the active editor group and selects the
    /// UTF-8 range corresponding to `range`, used by both the Problems and
    /// Symbols sidebars to navigate to a server-reported location without
    /// changing the originating list (SPEC 6.4).
    private func navigateToLSPLocation(url: URL, range: LSPRange) {
        guard let relativePath = relativePath(of: url) else {
            return
        }
        sourceLoadTask?.cancel()
        sourceLoadTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let snapshot = try await self.loadSnapshot(relativePath: relativePath)
                guard !Task.isCancelled,
                      let groupController = self.splitContainer.controller(for: self.layoutState.activeGroupID) else {
                    return
                }
                let utf8Range = (try? snapshot.utf8Offset(for: SourcePosition(line: range.start.line, character: range.start.character), encoding: .utf16))
                    .flatMap { start -> Range<Int>? in
                        guard let end = try? snapshot.utf8Offset(
                            for: SourcePosition(line: range.end.line, character: range.end.character),
                            encoding: .utf16
                        ), start <= end else {
                            return nil
                        }
                        return start..<end
                    }
                groupController.openTab(
                    relativePath: relativePath,
                    pinned: true,
                    snapshot: snapshot,
                    selectingUTF8Range: utf8Range ?? (0..<0)
                )
            } catch is CancellationError {
                return
            } catch {
                // Best-effort navigation: a since-deleted or unreadable
                // file simply does not navigate; the Problems/Symbols
                // list itself is unaffected.
            }
        }
    }

    // MARK: - Peek Definition / References, Call / Type Hierarchy (Phase 7)
    //
    // Commands require a currently-selected position in the active
    // document — capability-gated: an absent/not-yet-started
    // server, or a server that never advertised the relevant capability,
    // simply produces no panel rather than an error dialog (SPEC:
    // "unsupported features are hidden/disabled, not errors").

    private func currentPositionForActiveDocument() -> (snapshot: SourceSnapshot, utf8Offset: Int)? {
        guard let documentController = activeGroupController?.currentDocumentController else {
            return nil
        }
        let offset = documentController.viewport.selectedUTF8Range?.lowerBound
            ?? documentController.viewport.focusedUTF8Offset
        return (documentController.snapshot, offset)
    }

    @objc
    func showPeekDefinition(_ sender: Any?) {
        guard let window = view.window, let position = currentPositionForActiveDocument() else {
            return
        }
        Task { [weak self] in
            guard let self else {
                return
            }
            guard let targets = try? await self.definitionTargets(
                snapshot: position.snapshot,
                utf8Offset: position.utf8Offset
            ), !targets.isEmpty else {
                return
            }
            let results = targets.map { PeekResult(navigationTarget: $0) }
            let panel = PeekPanelController(
                title: Localized.string("Peek Definition", comment: "Title of the Peek Definition panel"),
                results: results,
                onSelect: { [weak self] result in
                    self?.navigateToLSPLocation(url: result.url, range: result.range)
                }
            )
            self.peekPanelController = panel
            panel.show(asSheetFor: window)
        }
    }

    @objc
    func showCallHierarchy(_ sender: Any?) {
        guard let window = view.window,
              let position = currentPositionForActiveDocument() else {
            return
        }
        Task { [weak self] in
            guard let self else {
                return
            }
            guard let items = try? await self.multiLanguageServicesCoordinator.prepareCallHierarchy(
                snapshot: position.snapshot,
                utf8Offset: position.utf8Offset
            ), let root = items.first else {
                return
            }
            let modes = [
                HierarchyViewController.Mode(title: Localized.string("Callers", comment: "Call hierarchy mode segment title showing incoming callers")) { [weak self] item in
                    guard let self else { return [] }
                    return (try? await self.multiLanguageServicesCoordinator.callHierarchyIncomingCalls(item: item))?.map(\.from) ?? []
                },
                HierarchyViewController.Mode(title: Localized.string("Callees", comment: "Call hierarchy mode segment title showing outgoing callees")) { [weak self] item in
                    guard let self else { return [] }
                    return (try? await self.multiLanguageServicesCoordinator.callHierarchyOutgoingCalls(item: item))?.map(\.to) ?? []
                }
            ]
            let panel = HierarchyPanelController(
                title: Localized.string("Call Hierarchy", comment: "Title of the Call Hierarchy panel"),
                root: root,
                modes: modes,
                onSelectItem: { [weak self] item in
                    self?.navigateToLSPLocation(url: item.url, range: item.selectionRange)
                }
            )
            self.hierarchyPanelController = panel
            panel.show(asSheetFor: window)
        }
    }

    @objc
    func showQuickOpen(_ sender: Any?) {
        guard let window = view.window else {
            return
        }

        let controller = QuickOpenPanelController(
            filenameIndex: filenameIndex,
            onSelect: { [weak self] entry in
                self?.open(entry)
            }
        )
        quickOpenController = controller
        controller.show(asSheetFor: window)
    }

    // MARK: - Commands (Find, Go to Line, Word Wrap, Split, Navigate)

    @objc
    func findInFile(_ sender: Any?) {
        activeGroupController?.toggleFindBar()
    }

    @objc
    func showGoToLinePanel(_ sender: Any?) {
        guard let window = view.window else {
            return
        }
        let controller = GoToLinePanelController(onSubmit: { [weak self] line in
            self?.activeGroupController?.goToLine(line)
        })
        goToLinePanelController = controller
        controller.show(asSheetFor: window)
    }

    @objc
    func toggleWordWrap(_ sender: Any?) {
        layoutState.wordWrapEnabled.toggle()
        splitContainer.allGroupControllers.forEach { $0.wordWrapEnabled = layoutState.wordWrapEnabled }
        persistLayout()
    }

    @objc
    func splitActiveGroupRight(_ sender: Any?) {
        handleSplit(groupID: layoutState.activeGroupID, orientation: .horizontal)
    }

    @objc
    func splitActiveGroupDown(_ sender: Any?) {
        handleSplit(groupID: layoutState.activeGroupID, orientation: .vertical)
    }

    @objc
    func closeActiveGroup(_ sender: Any?) {
        handleCloseGroup(groupID: layoutState.activeGroupID)
    }

    @objc
    func closeActiveTab(_ sender: Any?) {
        guard let groupController = activeGroupController, let tabID = groupController.state.selectedTabID else {
            view.window?.performClose(sender)
            return
        }
        groupController.closeTab(tabID)
    }

    @objc
    func navigateBack(_ sender: Any?) {
        activeGroupController?.goBack()
    }

    @objc
    func navigateForward(_ sender: Any?) {
        activeGroupController?.goForward()
    }

    @objc
    func goToDefinition(_ sender: Any?) {
        guard let controller = activeGroupController?.currentDocumentController else {
            return
        }
        let offset = controller.viewport.selectedUTF8Range?.lowerBound
            ?? controller.viewport.focusedUTF8Offset
        performDefinitionNavigation(from: controller, utf8Offset: offset)
    }

    @objc
    func showCommandPalette(_ sender: Any?) {
        guard let window = view.window else {
            return
        }
        let controller = CommandPaletteController(commands: buildPaletteCommands())
        commandPaletteController = controller
        controller.show(asSheetFor: window)
    }

    private func buildPaletteCommands() -> [PaletteCommand] {
        [
            PaletteCommand(id: "command.quickOpen", title: Localized.string("Quick Open...", comment: "Command palette entry that opens Quick Open")) { [weak self] in
                self?.showQuickOpen(nil)
            },
            PaletteCommand(id: "command.findInFile", title: Localized.string("Find in File", comment: "Command palette entry that opens in-file find")) { [weak self] in
                self?.findInFile(nil)
            },
            PaletteCommand(id: "command.searchWorkspace", title: Localized.string("Search Workspace", comment: "Command palette entry that opens workspace-wide search")) { [weak self] in
                self?.searchWorkspace(nil)
            },
            PaletteCommand(id: "command.goToLine", title: Localized.string("Go to Line...", comment: "Command palette entry that opens the Go to Line panel")) { [weak self] in
                self?.showGoToLinePanel(nil)
            },
            PaletteCommand(id: "command.toggleWordWrap", title: Localized.string("Toggle Word Wrap", comment: "Command palette entry that toggles word wrap")) { [weak self] in
                self?.toggleWordWrap(nil)
            },
            PaletteCommand(id: "command.splitRight", title: Localized.string("Split Editor Right", comment: "Command palette entry that splits the active editor group to the right")) { [weak self] in
                self?.splitActiveGroupRight(nil)
            },
            PaletteCommand(id: "command.splitDown", title: Localized.string("Split Editor Down", comment: "Command palette entry that splits the active editor group downward")) { [weak self] in
                self?.splitActiveGroupDown(nil)
            },
            PaletteCommand(id: "command.closeGroup", title: Localized.string("Close Editor Group", comment: "Command palette entry that closes the active editor group")) { [weak self] in
                self?.closeActiveGroup(nil)
            },
            PaletteCommand(id: "command.closeTab", title: Localized.string("Close Tab", comment: "Command palette entry that closes the active tab")) { [weak self] in
                self?.closeActiveTab(nil)
            },
            PaletteCommand(id: "command.navigateBack", title: Localized.string("Navigate Back", comment: "Command palette entry that navigates back in history")) { [weak self] in
                self?.navigateBack(nil)
            },
            PaletteCommand(id: "command.navigateForward", title: Localized.string("Navigate Forward", comment: "Command palette entry that navigates forward in history")) { [weak self] in
                self?.navigateForward(nil)
            },
            PaletteCommand(id: "command.goToDefinition", title: Localized.string("Go to Definition", comment: "Command palette entry that navigates to the selected symbol's definition")) { [weak self] in
                self?.goToDefinition(nil)
            },
            PaletteCommand(id: "command.peekDefinition", title: Localized.string("Peek Definition", comment: "Command palette entry that shows Peek Definition")) { [weak self] in
                self?.showPeekDefinition(nil)
            },
            PaletteCommand(id: "command.showCallHierarchy", title: Localized.string("Show Call Hierarchy", comment: "Command palette entry that shows the Call Hierarchy panel")) { [weak self] in
                self?.showCallHierarchy(nil)
            }
        ]
    }

    private var activeGroupController: EditorGroupViewController? {
        splitContainer.controller(for: layoutState.activeGroupID)
    }

    /// Pushes `layoutState.activeGroupID` onto every live group
    /// controller's `isActive` flag, so exactly one group is marked
    /// active — called any time the active group changes or the split
    /// tree is rebuilt (a rebuild can create new controllers that
    /// default to `isActive == true` and would otherwise leave two
    /// groups simultaneously claiming to be active).
    private func refreshActiveGroupHighlighting() {
        for controller in splitContainer.allGroupControllers {
            controller.isActive = (controller.groupID == layoutState.activeGroupID)
        }
        refreshPreviewSourceToolbar()
    }

    private func handleSplit(groupID: EditorGroupID, orientation: SplitOrientation) {
        guard layoutState.groups[groupID]?.selectedTab != nil else {
            return
        }
        if let sourceController = splitContainer.controller(for: groupID) {
            sourceController.captureLatestAnchorIntoState()
            layoutState.groups[groupID] = sourceController.state
        }
        layoutState.split(groupID, orientation: orientation)
        splitContainer.rebuild(root: layoutState.root)
        refreshActiveGroupHighlighting()
        persistLayout()
    }

    private func handleCloseGroup(groupID: EditorGroupID) {
        layoutState.closeGroup(groupID)
        splitContainer.rebuild(root: layoutState.root)
        refreshActiveGroupHighlighting()
        persistLayout()
    }

    private func collapseEmptyGroupsKeepingOne() {
        let groupIDs = layoutState.root.groupIDs
        let nonEmptyGroupIDs = groupIDs.filter {
            layoutState.groups[$0]?.tabs.isEmpty == false
        }
        let preservedEmptyGroupID = nonEmptyGroupIDs.isEmpty
            ? (groupIDs.contains(layoutState.activeGroupID) ? layoutState.activeGroupID : groupIDs.first)
            : nil
        for groupID in groupIDs where layoutState.groups.count > 1 {
            guard layoutState.groups[groupID]?.tabs.isEmpty == true,
                  groupID != preservedEmptyGroupID else {
                continue
            }
            layoutState.closeGroup(groupID)
        }
    }

    private func updateTabDrag(
        from sourceGroupID: EditorGroupID,
        tabID _: EditorTabID,
        windowLocation: NSPoint
    ) -> EditorTabDropPreview? {
        var targetPreview: EditorTabDropPreview?
        for controller in splitContainer.allGroupControllers {
            guard controller.groupID != sourceGroupID else {
                controller.clearTabDropPreview()
                continue
            }
            if targetPreview == nil,
               let preview = controller.showTabDropPreview(at: windowLocation) {
                targetPreview = preview
            } else {
                controller.clearTabDropPreview()
            }
        }
        return targetPreview
    }

    private func completeTabDrop(
        from sourceGroupID: EditorGroupID,
        tabID: EditorTabID,
        preview: EditorTabDropPreview
    ) -> Bool {
        guard let sourceController = splitContainer.controller(for: sourceGroupID),
              preview.groupID != sourceGroupID,
              let targetController = splitContainer.controller(for: preview.groupID) else {
            clearTabDropPreviews()
            return false
        }
        guard let payload = sourceController.detachTabForTransfer(tabID) else {
            clearTabDropPreviews()
            return false
        }
        splitContainer.allGroupControllers
            .filter { $0.groupID != preview.groupID }
            .forEach { $0.clearTabDropPreview() }
        targetController.consumeTabDropPreview()
        targetController.insertTransferredTab(payload, at: preview.insertionIndex)
        layoutState.activeGroupID = targetController.groupID
        refreshActiveGroupHighlighting()
        cancelHover()
        refreshLanguageServerStateUI()
        persistLayout()
        return true
    }

    private func clearTabDropPreviews() {
        splitContainer.allGroupControllers.forEach { $0.clearTabDropPreview() }
    }

    private func makeGroupController(for id: EditorGroupID) -> EditorGroupViewController {
        let state = layoutState.groups[id] ?? EditorGroupState(id: id)
        let controller = EditorGroupViewController(groupID: id, state: state)
        controller.wordWrapEnabled = layoutState.wordWrapEnabled
        controller.syntaxLanguageForSnapshot = { [weak self] snapshot in
            self?.languageSupportService.syntaxLanguage(for: snapshot)
        }
        controller.loadSnapshot = { [weak self] relativePath in
            guard let self else {
                throw CocoaError(.fileReadUnknown)
            }
            return try await self.loadSnapshot(relativePath: relativePath)
        }
        controller.loadRawData = { [weak self] relativePath in
            guard let self else {
                throw CocoaError(.fileReadUnknown)
            }
            return try await self.loadRawFileData(relativePath: relativePath)
        }
        controller.isWorkspaceTrusted = { [weak self] in
            guard let self else {
                return false
            }
            return self.trustStore.isTrusted(self.identity)
        }
        controller.onOpenLocalRelativePath = { [weak self, weak controller] relativePath in
            guard let self, let controller else {
                return
            }
            self.sourceLoadTask?.cancel()
            self.sourceLoadTask = Task { [weak self, weak controller] in
                guard let self, let controller else {
                    return
                }
                do {
                    let snapshot = try await self.loadSnapshot(relativePath: relativePath)
                    guard !Task.isCancelled else {
                        return
                    }
                    controller.openTab(relativePath: relativePath, pinned: true, snapshot: snapshot)
                } catch is CancellationError {
                    return
                } catch {
                    // A Markdown local-link target that does not exist
                    // (or is not text) simply does not navigate.
                }
            }
        }
        controller.onStateChange = { [weak self] groupID, state in
            guard let self else {
                return
            }
            self.layoutState.groups[groupID] = state
            if state.tabs.isEmpty, self.layoutState.groups.count > 1 {
                self.handleCloseGroup(groupID: groupID)
            } else {
                self.persistLayout()
            }
        }
        controller.onActivate = { [weak self] groupID in
            self?.layoutState.activeGroupID = groupID
            self?.refreshActiveGroupHighlighting()
            self?.cancelHover()
            self?.refreshLanguageServerStateUI()
            self?.persistLayout()
        }
        controller.onTabDragUpdate = { [weak self] sourceGroupID, tabID, windowLocation in
            self?.updateTabDrag(
                from: sourceGroupID,
                tabID: tabID,
                windowLocation: windowLocation
            )
        }
        controller.onTabDrop = { [weak self] sourceGroupID, tabID, preview in
            self?.completeTabDrop(
                from: sourceGroupID,
                tabID: tabID,
                preview: preview
            ) ?? false
        }
        controller.onTabDragEnd = { [weak self] _ in
            self?.clearTabDropPreviews()
        }
        controller.onPreviewSourceControlChange = { [weak self] groupID, state in
            guard let self, self.layoutState.activeGroupID == groupID else {
                return
            }
            self.previewSourceControlView?.update(state)
        }
        controller.onDocumentReady = { [weak self] relativePath, documentController in
            self?.configureLanguageInteractions(for: documentController)
            self?.multiLanguageServicesCoordinator.handleDocumentReady(
                relativePath: relativePath,
                controller: documentController
            )
            self?.refreshLanguageServerStateUI()
        }
        controller.onActiveDocumentChange = { [weak self] _ in
            self?.cancelHover()
            self?.refreshLanguageServerStateUI()
        }
        return controller
    }

    private func reloadChangedSyntaxDefinitions() {
        splitContainer?.allGroupControllers.forEach {
            $0.reloadChangedSyntaxDefinitions()
        }
    }

    func persistRestorableState() {
        if isViewLoaded, let splitContainer {
            for controller in splitContainer.allGroupControllers {
                controller.captureLatestAnchorIntoState()
                layoutState.groups[controller.groupID] = controller.state
            }
            layoutState.root = splitContainer.captureLayout()
            captureWorkspaceGeometry()
        }
        persistLayout()
    }

    private func persistLayout() {
        layoutStore.save(layoutState, for: identity)
    }

    /// Reads a workspace-relative path's raw bytes, independent of
    /// `SourceSnapshot`'s text-decoding requirement — used only for
    /// SPEC 10.2 image previews (a PNG/JPEG/GIF/HEIC/TIFF file is not
    /// valid UTF-8 text, so `SourceSnapshotLoader` correctly refuses to
    /// load one at all).
    private func loadRawFileData(relativePath: String) async throws -> Data {
        let url = identity.root.appendingPathComponent(relativePath)
        return try await Task.detached(priority: .userInitiated) {
            try LocalReadOnlyFileSystem().readFile(at: url).data
        }.value
    }

    /// Attempts to build a SPEC 10.2 image preview for `relativePath`
    /// from its raw bytes, returning `nil` if the bytes are not a
    /// recognized image format (or cannot be read at all) — the caller's
    /// recovery path for a `SourceSnapshotLoader` failure, never called
    /// speculatively for a file that already loaded as text.
    private func tryMakeImagePreview(forRelativePath relativePath: String) async -> PreviewViewController? {
        guard let data = try? await loadRawFileData(relativePath: relativePath) else {
            return nil
        }
        let kind = PreviewContentDetector.detect(
            pathExtension: (relativePath as NSString).pathExtension,
            contentPrefix: data.prefix(4_096)
        )
        guard case .image = kind else {
            return nil
        }
        return await PreviewViewController.make(
            kind: kind,
            data: data,
            theme: AppearanceSettings.currentTheme(),
            fontSettings: AppearanceSettings.currentFontSettings(),
            isWorkspaceTrusted: { [weak self] in
                guard let self else {
                    return false
                }
                return self.trustStore.isTrusted(self.identity)
            }
        )
    }

    private func loadSnapshot(relativePath: String) async throws -> SourceSnapshot {
        let url = identity.root.appendingPathComponent(relativePath)
        return try await Task.detached(priority: .userInitiated) {
            try SourceSnapshotLoader().load(url: url)
        }.value
    }

    // MARK: - Sidebar / Explorer

    private func configureWorkspaceBannerStack() {
        workspaceBannerStack.orientation = .vertical
        workspaceBannerStack.alignment = .width
        workspaceBannerStack.spacing = 6
        workspaceBannerStack.addArrangedSubview(trustBanner)
        workspaceBannerStack.addArrangedSubview(languageSupportBanner)
        workspaceBannerStack.isHidden = true
    }

    private func configureTrustBanner() {
        trustBanner.identifier = NSUserInterfaceItemIdentifier("workspace.trustBanner")
        trustBanner.orientation = .horizontal
        trustBanner.alignment = .centerY
        trustBanner.spacing = 8
        trustBanner.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 6)
        trustBanner.wantsLayer = true
        trustBanner.layer?.cornerRadius = 6
        trustBanner.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor

        let icon = NSImageView(
            image: NSImage(
                systemSymbolName: "lock.shield",
                accessibilityDescription: Localized.string("Restricted mode", comment: "Accessibility description for the lock icon shown when a workspace is untrusted")
            ) ?? NSImage()
        )

        trustBannerLabel.lineBreakMode = .byTruncatingTail
        trustBannerLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trustBannerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trustActionButton.identifier = NSUserInterfaceItemIdentifier("workspace.trust")
        trustActionButton.setContentHuggingPriority(.required, for: .horizontal)
        trustDismissButton.identifier = NSUserInterfaceItemIdentifier("workspace.trustDismiss")
        trustDismissButton.bezelStyle = .inline
        trustDismissButton.isBordered = false
        trustDismissButton.target = self
        trustDismissButton.action = #selector(dismissTrustBanner(_:))
        trustDismissButton.setAccessibilityLabel(
            Localized.string(
                "Dismiss Workspace Trust Banner",
                comment: "Accessibility label for the button that dismisses the workspace trust banner"
            )
        )
        trustDismissButton.setContentHuggingPriority(.required, for: .horizontal)

        trustBanner.addArrangedSubview(icon)
        trustBanner.addArrangedSubview(trustBannerLabel)
        trustBanner.addArrangedSubview(trustActionButton)
        trustBanner.addArrangedSubview(trustDismissButton)
        refreshTrustBanner()
    }

    private func configureLanguageSupportBanner() {
        languageSupportBanner.identifier = NSUserInterfaceItemIdentifier(
            "workspace.missingLanguageServerBanner"
        )
        languageSupportBanner.orientation = .horizontal
        languageSupportBanner.alignment = .centerY
        languageSupportBanner.spacing = 8
        languageSupportBanner.edgeInsets = NSEdgeInsets(
            top: 6,
            left: 10,
            bottom: 6,
            right: 6
        )
        languageSupportBanner.wantsLayer = true
        languageSupportBanner.layer?.cornerRadius = 6
        languageSupportBanner.layer?.backgroundColor = NSColor.systemOrange
            .withAlphaComponent(0.1)
            .cgColor
        languageSupportBanner.isHidden = true

        let icon = NSImageView(
            image: NSImage(
                systemSymbolName: "puzzlepiece.extension",
                accessibilityDescription: Localized.string(
                    "Missing language server",
                    comment: "Accessibility description for the icon in the missing language-server banner"
                )
            ) ?? NSImage()
        )
        languageSupportBannerLabel.lineBreakMode = .byTruncatingTail
        languageSupportBannerLabel.setContentHuggingPriority(
            .defaultLow,
            for: .horizontal
        )
        languageSupportBannerLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )

        let buttons = [
            languageSupportChooseButton,
            languageSupportSettingsButton,
            languageSupportFindButton,
            languageSupportNotNowButton
        ]
        for button in buttons {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.target = self
        }
        languageSupportFindButton.identifier = NSUserInterfaceItemIdentifier(
            "workspace.missingLanguageServer.findServer"
        )
        languageSupportFindButton.action = #selector(
            findMissingLanguageServer(_:)
        )
        languageSupportChooseButton.identifier = NSUserInterfaceItemIdentifier(
            "workspace.missingLanguageServer.chooseExisting"
        )
        languageSupportChooseButton.action = #selector(
            chooseMissingLanguageServer(_:)
        )
        languageSupportSettingsButton.identifier = NSUserInterfaceItemIdentifier(
            "workspace.missingLanguageServer.openSettings"
        )
        languageSupportSettingsButton.action = #selector(
            openLanguageSupportSettings(_:)
        )
        languageSupportNotNowButton.identifier = NSUserInterfaceItemIdentifier(
            "workspace.missingLanguageServer.notNow"
        )
        languageSupportNotNowButton.action = #selector(
            dismissMissingLanguageServer(_:)
        )

        languageSupportBanner.addArrangedSubview(icon)
        languageSupportBanner.addArrangedSubview(languageSupportBannerLabel)
        for button in buttons {
            languageSupportBanner.addArrangedSubview(button)
        }
    }

    /// Updates the trust banner's copy, button label/action, and
    /// visibility from the trust store's current, live state (SPEC
    /// 13.1: trusting/revoking a workspace must be immediately
    /// reflected). Called on load and again after both `trustWorkspace`
    /// and `revokeTrust` so the banner never shows a stale state.
    private func refreshTrustBanner() {
        let trusted = trustStore.isTrusted(identity)
        if trusted {
            trustBannerLabel.stringValue = Localized.string(
                "This workspace is trusted: language servers and repository tools are enabled.",
                comment: "Trust banner message shown when the current workspace is trusted"
            )
            trustBannerLabel.textColor = .secondaryLabelColor
            trustActionButton.title = Localized.string("Revoke Trust", comment: "Trust banner button title to revoke trust for the current workspace")
            trustActionButton.target = self
            trustActionButton.action = #selector(revokeTrust(_:))
            trustActionButton.setAccessibilityLabel(
                Localized.string("Revoke trust for this workspace, disabling language servers", comment: "Accessibility label for the trust banner's revoke-trust button")
            )
        } else {
            trustBannerLabel.stringValue = Localized.string(
                "Restricted mode: language servers and repository tools are disabled.",
                comment: "Trust banner message shown when the current workspace is untrusted"
            )
            trustBannerLabel.textColor = .secondaryLabelColor
            trustActionButton.title = Localized.string("Trust Workspace", comment: "Trust banner button title to trust the current workspace")
            trustActionButton.target = self
            trustActionButton.action = #selector(trustWorkspace(_:))
            trustActionButton.setAccessibilityLabel(
                Localized.string("Trust this workspace, enabling language servers and repository tools", comment: "Accessibility label for the trust banner's trust-workspace button")
            )
        }
        updateTrustBannerVisibility()
    }

    private func refreshTrustStatusButton() {
        let trusted = trustStore.isTrusted(identity)
        let stateDescription: String
        let actionDescription: String
        let symbolName: String

        if trusted {
            stateDescription = Localized.string(
                "This workspace is trusted: language servers and repository tools are enabled.",
                comment: "Trust status description shown for a trusted workspace"
            )
            actionDescription = Localized.string(
                "Revoke trust for this workspace, disabling language servers",
                comment: "Accessibility help for the status-bar workspace trust control"
            )
            symbolName = "checkmark.shield.fill"
            trustStatusButton.contentTintColor = .systemGreen
        } else {
            stateDescription = Localized.string(
                "Restricted mode: language servers and repository tools are disabled.",
                comment: "Trust status description shown for an untrusted workspace"
            )
            actionDescription = Localized.string(
                "Trust this workspace, enabling language servers and repository tools",
                comment: "Accessibility help for the status-bar workspace trust control"
            )
            symbolName = "exclamationmark.shield.fill"
            trustStatusButton.contentTintColor = .systemOrange
        }

        trustStatusButton.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: stateDescription
        )
        trustStatusButton.toolTip = stateDescription
        trustStatusButton.setAccessibilityLabel(stateDescription)
        trustStatusButton.setAccessibilityHelp(actionDescription)
    }

    private func refreshWorkspaceTrustUI() {
        refreshTrustBanner()
        refreshTrustStatusButton()
    }

    private func updateTrustBannerVisibility() {
        let isVisible = shouldShowInitialTrustBanner && !isTrustBannerDismissed
        trustBanner.isHidden = !isVisible
        updateWorkspaceBannerVisibility()
    }

    private func updateWorkspaceBannerVisibility() {
        let isVisible = !trustBanner.isHidden || !languageSupportBanner.isHidden
        workspaceBannerStack.isHidden = !isVisible
        contentTopWithTrustBannerConstraint?.isActive = isVisible
        contentTopWithoutTrustBannerConstraint?.isActive = !isVisible
    }

    @objc
    func dismissTrustBanner(_ sender: Any?) {
        isTrustBannerDismissed = true
        updateTrustBannerVisibility()
    }


    private func makeSidebar() -> NSView {
        let container = NSView()
        container.identifier = NSUserInterfaceItemIdentifier("workspace.sidebar")

        sidebarModeControl.segmentStyle = .texturedRounded
        sidebarModeControl.selectedSegment = 0
        sidebarModeControl.target = self
        sidebarModeControl.action = #selector(sidebarModeChanged(_:))
        sidebarModeControl.identifier = NSUserInterfaceItemIdentifier("workspace.sidebarMode")
        sidebarModeControl.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        sidebarModeControl.translatesAutoresizingMaskIntoConstraints = false

        explorerContainer = makeExplorerView()
        explorerContainer.translatesAutoresizingMaskIntoConstraints = false

        let searchController = SearchSidebarViewController(
            root: identity.root,
            diagnosticsLog: diagnosticsLog,
            onSelectMatch: { [weak self] selection in
                self?.openMatch(relativePath: selection.relativePath, utf8Range: selection.utf8Range)
            }
        )
        searchSidebarController = searchController
        addChild(searchController)
        searchController.view.translatesAutoresizingMaskIntoConstraints = false
        searchController.view.isHidden = true

        let problemsController = ProblemsViewController(
            root: identity.root,
            onSelectDiagnostic: { [weak self] selection in
                self?.navigateToLSPLocation(url: selection.url, range: selection.range)
            }
        )
        problemsViewController = problemsController
        addChild(problemsController)
        problemsController.view.translatesAutoresizingMaskIntoConstraints = false
        problemsController.view.isHidden = true

        let symbolsController = SymbolsViewController(
            search: { [weak self] query in
                guard let self else {
                    return []
                }
                return try await self.workspaceSymbols(query: query)
            },
            onSelectSymbol: { [weak self] symbol in
                self?.navigateToLSPLocation(url: symbol.url, range: symbol.range)
            }
        )
        symbolsViewController = symbolsController
        addChild(symbolsController)
        symbolsController.view.translatesAutoresizingMaskIntoConstraints = false
        symbolsController.view.isHidden = true

        let sourceControlController = SourceControlSidebarViewController(
            onSelectFile: { [weak self] selection in
                self?.openDiff(for: selection)
            }
        )
        sourceControlSidebarController = sourceControlController
        addChild(sourceControlController)
        sourceControlController.view.translatesAutoresizingMaskIntoConstraints = false
        sourceControlController.view.isHidden = true

        container.addSubview(sidebarModeControl)
        container.addSubview(explorerContainer)
        container.addSubview(searchController.view)
        container.addSubview(problemsController.view)
        container.addSubview(symbolsController.view)
        container.addSubview(sourceControlController.view)
        NSLayoutConstraint.activate([
            sidebarModeControl.topAnchor.constraint(
                equalTo: container.safeAreaLayoutGuide.topAnchor,
                constant: 8
            ),
            sidebarModeControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            sidebarModeControl.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),

            explorerContainer.topAnchor.constraint(equalTo: sidebarModeControl.bottomAnchor, constant: 6),
            explorerContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            explorerContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            explorerContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            searchController.view.topAnchor.constraint(equalTo: sidebarModeControl.bottomAnchor, constant: 6),
            searchController.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            searchController.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            searchController.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            problemsController.view.topAnchor.constraint(equalTo: sidebarModeControl.bottomAnchor, constant: 6),
            problemsController.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            problemsController.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            problemsController.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            symbolsController.view.topAnchor.constraint(equalTo: sidebarModeControl.bottomAnchor, constant: 6),
            symbolsController.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            symbolsController.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            symbolsController.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            sourceControlController.view.topAnchor.constraint(equalTo: sidebarModeControl.bottomAnchor, constant: 6),
            sourceControlController.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sourceControlController.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            sourceControlController.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func makeStatusBar() -> NSView {
        let container = NSVisualEffectView()
        container.identifier = NSUserInterfaceItemIdentifier("workspace.statusBar")
        container.material = .contentBackground
        container.blendingMode = .withinWindow
        container.state = .active

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        languageServerStateLabel.font = .systemFont(ofSize: 11)
        languageServerStateLabel.textColor = .secondaryLabelColor
        languageServerStateLabel.identifier = NSUserInterfaceItemIdentifier("workspace.languageServerState")
        languageServerStateLabel.translatesAutoresizingMaskIntoConstraints = false

        languageServerRestartButton.bezelStyle = .rounded
        languageServerRestartButton.controlSize = .small
        languageServerRestartButton.font = .systemFont(ofSize: 10)
        languageServerRestartButton.target = self
        languageServerRestartButton.action = #selector(restartLanguageServer(_:))
        languageServerRestartButton.identifier = NSUserInterfaceItemIdentifier("workspace.languageServerRestart")
        languageServerRestartButton.setAccessibilityLabel(Localized.string("Restart Language Server", comment: "Accessibility label for the language server restart button"))
        languageServerRestartButton.isEnabled = false
        languageServerRestartButton.translatesAutoresizingMaskIntoConstraints = false

        trustStatusButton.identifier = NSUserInterfaceItemIdentifier("workspace.trustStatus")
        trustStatusButton.bezelStyle = .inline
        trustStatusButton.isBordered = false
        trustStatusButton.imagePosition = .imageOnly
        trustStatusButton.target = self
        trustStatusButton.action = #selector(promptToToggleWorkspaceTrust(_:))
        trustStatusButton.translatesAutoresizingMaskIntoConstraints = false
        refreshTrustStatusButton()

        container.addSubview(separator)
        container.addSubview(languageServerStateLabel)
        container.addSubview(languageServerRestartButton)
        container.addSubview(trustStatusButton)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: container.topAnchor),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            languageServerStateLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            languageServerStateLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            languageServerRestartButton.leadingAnchor.constraint(equalTo: languageServerStateLabel.trailingAnchor, constant: 8),
            languageServerRestartButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            languageServerRestartButton.trailingAnchor.constraint(lessThanOrEqualTo: trustStatusButton.leadingAnchor, constant: -8),
            trustStatusButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            trustStatusButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            trustStatusButton.widthAnchor.constraint(equalToConstant: 24),
            trustStatusButton.heightAnchor.constraint(equalToConstant: 24)
        ])
        return container
    }

    private func makeExplorerView() -> NSView {
        let container = NSView()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("workspace.name"))
        column.title = Localized.string("Files", comment: "Column title for the workspace Explorer's file tree (header is hidden but title remains accessible)")
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .small
        outlineView.indentationPerLevel = 14
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(handleOutlineClick(_:))
        outlineView.identifier = NSUserInterfaceItemIdentifier("workspace.explorer")
        outlineView.menu = makeExplorerContextMenu()
        outlineView.backgroundColor = .clear

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.identifier = NSUserInterfaceItemIdentifier("workspace.discoveryStatus")
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        showHiddenFilesButton.identifier = NSUserInterfaceItemIdentifier("workspace.showHiddenFiles")
        showHiddenFilesButton.target = self
        showHiddenFilesButton.action = #selector(explorerVisibilityChanged(_:))
        showHiddenFilesButton.state = discoveryOptions.includeHidden ? .on : .off
        showHiddenFilesButton.controlSize = .small

        showIgnoredFilesButton.identifier = NSUserInterfaceItemIdentifier("workspace.showIgnoredFiles")
        showIgnoredFilesButton.target = self
        showIgnoredFilesButton.action = #selector(explorerVisibilityChanged(_:))
        showIgnoredFilesButton.state = discoveryOptions.includeIgnored ? .on : .off
        showIgnoredFilesButton.controlSize = .small

        let footer = NSStackView(views: [statusLabel, showHiddenFilesButton, showIgnoredFilesButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scrollView)
        container.addSubview(footer)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -4),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5)
        ])
        return container
    }

    private func makeExplorerContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(
            withTitle: Localized.string("Show Git Blame", comment: "Explorer context menu item that shows Git blame for the selected file"),
            action: #selector(showGitBlameForSelectedFile(_:)),
            keyEquivalent: ""
        )
        return menu
    }

    @objc
    private func sidebarModeChanged(_ sender: Any?) {
        let segment = sidebarModeControl.selectedSegment
        explorerContainer.isHidden = segment != 0
        searchSidebarController.view.isHidden = segment != 1
        problemsViewController.view.isHidden = segment != 2
        symbolsViewController.view.isHidden = segment != 3
        sourceControlSidebarController.view.isHidden = segment != 4
        if segment == 1 {
            searchSidebarController.focusSearchField()
        } else if segment == 3 {
            symbolsViewController.focusSearchField()
            symbolsViewController.refresh()
        }
    }

    /// Reveals the Search sidebar and focuses its search field (Command-
    /// Shift-F, SPEC 5.7).
    @objc
    func searchWorkspace(_ sender: Any?) {
        sidebarModeControl.selectedSegment = 1
        sidebarModeChanged(nil)
    }

    /// Opens a Workspace Search match in the active editor group with the
    /// match selected (SPEC 8.2).
    private func openMatch(relativePath: String, utf8Range: Range<Int>) {
        guard let groupController = splitContainer.controller(for: layoutState.activeGroupID) else {
            return
        }
        sourceLoadTask?.cancel()
        sourceLoadTask = Task { [weak self, weak groupController] in
            guard let self else {
                return
            }
            do {
                let snapshot = try await self.loadSnapshot(relativePath: relativePath)
                guard !Task.isCancelled, let groupController else {
                    return
                }
                groupController.openTab(
                    relativePath: relativePath,
                    pinned: true,
                    snapshot: snapshot,
                    selectingUTF8Range: utf8Range
                )
            } catch is CancellationError {
                return
            } catch {
                guard let window = self.view.window else {
                    return
                }
                let alert = NSAlert(error: error)
                await alert.beginSheetModal(for: window)
            }
        }
    }

    private func startDiscovery() {
        discoveryTask?.cancel()
        discoveryGeneration += 1
        let generation = discoveryGeneration
        entriesByParent.removeAll()
        nodeCache.removeAll()
        outlineView.reloadData()
        statusLabel.stringValue = Localized.string("Discovering files...", comment: "Status label shown in the workspace Explorer while a file scan is in progress")
        let options = discoveryOptions
        discoveryTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                await filenameIndex.removeAll()
                guard self.discoveryGeneration == generation else {
                    return
                }
                for try await batch in scanner.scan(root: identity.root, options: options) {
                    try Task.checkCancellation()
                    guard self.discoveryGeneration == generation else {
                        return
                    }
                    await filenameIndex.append(batch.entries)
                    guard self.discoveryGeneration == generation else {
                        return
                    }
                    apply(batch)
                }
                guard self.discoveryGeneration == generation else {
                    return
                }
                let fileCount = await filenameIndex.count
                statusLabel.stringValue = Localized.string("\(fileCount) files", comment: "Status label reporting the total number of discovered files in the workspace Explorer")
                startWatchingForExternalChanges()
            } catch is CancellationError {
                return
            } catch {
                statusLabel.stringValue = Localized.string(
                    "Discovery failed: \(error.localizedDescription)",
                    comment: "Status label shown in the workspace Explorer when the initial file scan fails"
                )
            }
        }
    }

    private func apply(_ batch: WorkspaceDiscoveryBatch) {
        for entry in batch.entries {
            let parent = (entry.relativePath as NSString).deletingLastPathComponent
            let key = parent == "." ? "" : parent
            entriesByParent[key, default: []].append(entry)
            nodeCache.removeValue(forKey: entry.relativePath)
        }
        statusLabel.stringValue = "\(batch.discoveredCount) items discovered"
        outlineView.reloadData()
    }

    // MARK: - Live filesystem updates (FSEvents)

    private func startWatchingForExternalChanges() {
        guard fileWatcher == nil else {
            return
        }
        let watcher = WorkspaceFileWatcher(root: identity.root) { [weak self] batch in
            Task { @MainActor in
                self?.handleWorkspaceChangeBatch(batch)
            }
        }
        fileWatcher = watcher
        watcher.start()
    }

    func handleWorkspaceChangeBatch(_ batch: WorkspaceChangeBatch) {
        Task { await gitCoordinator.handle(batch) }

        if batch.mayHaveChangedIgnoreRules {
            // An ignore-defining file changed: ignored state anywhere in
            // the tree may now be stale, so re-derive it with a full
            // rescan rather than risk showing/hiding the wrong files.
            startDiscovery()
            return
        }

        for changed in batch.paths {
            handleChangedPath(changed.path)
        }
    }

    func handleChangedPath(_ absolutePath: String) {
        let url = URL(fileURLWithPath: absolutePath)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: absolutePath, isDirectory: &isDirectory)

        guard let relativePath = relativePath(of: url) else {
            return
        }
        invalidateLanguageHoverCache(forChangedURL: url)

        if exists {
            guard let entry = scanner.classify(path: url, root: identity.root) else {
                return
            }
            guard shouldIncludeInExplorer(entry) else {
                removeEntry(relativePath: relativePath)
                Task { await filenameIndex.remove(relativePaths: [relativePath]) }
                return
            }
            addOrUpdateEntry(entry)
            Task { await filenameIndex.remove(relativePaths: [relativePath]) }
            Task { await filenameIndex.append([entry]) }

            guard entry.kind != .directory else {
                return
            }
            reloadOpenTabsIfNeeded(relativePath: relativePath)
        } else {
            removeEntry(relativePath: relativePath)
            Task { await filenameIndex.remove(relativePaths: [relativePath]) }
            tombstoneOpenTabsIfNeeded(relativePath: relativePath)
        }
    }

    private func invalidateLanguageHoverCache(forChangedURL url: URL) {
        let fileName = url.lastPathComponent.lowercased()
        let providerIdentifier: String?
        switch fileName {
        case "package.swift", "package.resolved":
            providerIdentifier = "swift"
        case "package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock",
             "tsconfig.json", "jsconfig.json":
            providerIdentifier = "typescript"
        case "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt",
             "poetry.lock":
            providerIdentifier = "python"
        case "cargo.toml", "cargo.lock":
            providerIdentifier = "rust"
        default:
            if (fileName.hasPrefix("tsconfig.") || fileName.hasPrefix("jsconfig.")),
               fileName.hasSuffix(".json") {
                providerIdentifier = "typescript"
            } else if fileName.hasPrefix("requirements"), fileName.hasSuffix(".txt") {
                providerIdentifier = "python"
            } else {
                providerIdentifier =
                    multiLanguageServicesCoordinator.languageKey(forURL: url)
            }
        }
        guard let providerIdentifier else {
            return
        }
        languageHoverController.invalidateCache(forProvider: providerIdentifier)
    }

    private func shouldIncludeInExplorer(_ entry: WorkspaceFileEntry) -> Bool {
        (!entry.isHidden || discoveryOptions.includeHidden)
            && (!entry.isIgnored || discoveryOptions.includeIgnored)
    }

    @objc
    private func explorerVisibilityChanged(_ sender: Any?) {
        discoveryOptions = WorkspaceDiscoveryOptions(
            includeHidden: showHiddenFilesButton.state == .on,
            includeIgnored: showIgnoredFilesButton.state == .on
        )
        startDiscovery()
    }

    private func relativePath(of url: URL) -> String? {
        let rootPath = identity.root.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard targetPath.hasPrefix(prefix) else {
            return nil
        }
        return String(targetPath.dropFirst(prefix.count))
    }

    private func addOrUpdateEntry(_ entry: WorkspaceFileEntry) {
        let parent = (entry.relativePath as NSString).deletingLastPathComponent
        let key = parent == "." ? "" : parent
        entriesByParent[key, default: []].removeAll { $0.relativePath == entry.relativePath }
        entriesByParent[key, default: []].append(entry)
        nodeCache.removeValue(forKey: entry.relativePath)
        outlineView.reloadData()
    }

    private func removeEntry(relativePath: String) {
        let parent = (relativePath as NSString).deletingLastPathComponent
        let key = parent == "." ? "" : parent
        entriesByParent[key]?.removeAll { $0.relativePath == relativePath }
        nodeCache.removeValue(forKey: relativePath)
        outlineView.reloadData()
    }

    /// Reloads every open tab for `relativePath` into a freshly loaded,
    /// version-bumped snapshot across every split group, preserving the
    /// reading anchor, and clears any tombstone the path previously had.
    private func reloadOpenTabsIfNeeded(relativePath: String) {
        let hasOpenTab = layoutState.groups.values.contains { group in
            group.tabs.contains { $0.relativePath == relativePath }
        }
        guard hasOpenTab else {
            return
        }

        externalReloadTask?.cancel()
        externalReloadTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let snapshot = try await self.loadSnapshot(relativePath: relativePath, bumpingVersion: true)
                guard !Task.isCancelled else {
                    return
                }
                self.layoutState.clearTombstone(relativePath: relativePath)
                for controller in self.splitContainer.allGroupControllers {
                    controller.clearTombstone(relativePath: relativePath)
                    controller.reloadTab(relativePath: relativePath, with: snapshot)
                }
                self.persistLayout()
            } catch is CancellationError {
                return
            } catch {
                // A transient read failure (e.g. a write still in
                // progress) should not tombstone or crash; the next
                // FSEvents batch will retry.
            }
        }
    }

    private func tombstoneOpenTabsIfNeeded(relativePath: String) {
        let hasOpenTab = layoutState.groups.values.contains { group in
            group.tabs.contains { $0.relativePath == relativePath }
        }
        guard hasOpenTab else {
            return
        }
        layoutState.markTombstoned(relativePath: relativePath, reason: .missing)
        for controller in splitContainer.allGroupControllers {
            controller.markTombstoned(relativePath: relativePath, reason: .missing)
        }
        persistLayout()
    }

    private func loadSnapshot(relativePath: String, bumpingVersion: Bool) async throws -> SourceSnapshot {
        let url = identity.root.appendingPathComponent(relativePath)
        let version = bumpingVersion ? nextVersion() : 1
        return try await Task.detached(priority: .userInitiated) {
            try SourceSnapshotLoader().load(url: url, version: version)
        }.value
    }

    private func nextVersion() -> Int {
        nextSnapshotVersion += 1
        return nextSnapshotVersion
    }

    func children(of relativePath: String) -> [WorkspaceTreeNode] {
        (entriesByParent[relativePath] ?? [])
            .sorted {
                if $0.kind == .directory, $1.kind != .directory {
                    return true
                }
                if $0.kind != .directory, $1.kind == .directory {
                    return false
                }
                return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
            .map { entry in
                if let cached = nodeCache[entry.relativePath] {
                    return cached
                }
                let node = WorkspaceTreeNode(entry: entry)
                nodeCache[entry.relativePath] = node
                return node
            }
    }

    /// Opens `entry` as a persistent tab in the currently active editor group.
    private func open(_ entry: WorkspaceFileEntry) {
        guard entry.kind != .directory else {
            return
        }
        guard let groupController = splitContainer.controller(for: layoutState.activeGroupID) else {
            return
        }

        sourceLoadTask?.cancel()
        sourceLoadTask = Task { [weak self, weak groupController] in
            guard let self else {
                return
            }
            do {
                let snapshot = try await self.loadSnapshot(relativePath: entry.relativePath)
                guard !Task.isCancelled, let groupController else {
                    return
                }
                groupController.openTab(relativePath: entry.relativePath, pinned: true, snapshot: snapshot)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let groupController else {
                    return
                }
                // `SourceSnapshotLoader` only ever throws here for a file
                // that is not valid text (SPEC 11.4) — recover by reading
                // its raw bytes and, if they are a recognized image
                // format (SPEC 10.2), showing the built-in image preview
                // instead of an error alert.
                if let preview = await self.tryMakeImagePreview(forRelativePath: entry.relativePath) {
                    groupController.openImagePreviewTab(
                        relativePath: entry.relativePath,
                        pinned: true,
                        kind: preview.kind,
                        preview: preview
                    )
                    return
                }
                guard let window = self.view.window else {
                    return
                }
                let alert = NSAlert(error: error)
                await alert.beginSheetModal(for: window)
            }
        }
    }

    @objc
    private func handleOutlineClick(_ sender: Any?) {
        guard outlineView.clickedRow >= 0,
              let node = outlineView.item(atRow: outlineView.clickedRow) as? WorkspaceTreeNode,
              node.entry.kind != .directory else {
            return
        }
        open(node.entry)
    }

    @objc
    func trustWorkspace(_ sender: Any?) {
        trustStore.trust(identity)
        refreshWorkspaceTrustUI()
        multiLanguageServicesCoordinator.handleTrustGranted()
        refreshLanguageServerStateUI()
        Task {
            await diagnosticsLog.record(
                subsystem: .workspace,
                level: .info,
                message: Localized.string("Workspace trust granted", comment: "Diagnostics log message recorded when a workspace is trusted"),
                context: [
                    DiagnosticContextField(name: "workspaceRoot", category: .fullPath, value: identity.root.path)
                ]
            )
        }
    }

    /// Revokes trust for this workspace (SPEC 13.1) and makes it
    /// immediately effective: unlike the lazy `isTrusted` gate the
    /// language-service coordinators already check before *starting* a
    /// server, revocation must also stop any server already running for
    /// this session, so `handleTrustRevoked()` is called right away rather
    /// than waiting for the next document open.
    @objc
    func revokeTrust(_ sender: Any?) {
        trustStore.revoke(identity)
        languageSupportPromptGeneration &+= 1
        queuedMissingLanguageKeys.removeAll()
        queuedUnknownLanguageURLs.removeAll()
        currentMissingLanguageKey = nil
        currentUnknownLanguageURL = nil
        currentMissingLanguageInstallationDocumentationURL = nil
        languageSupportBanner.isHidden = true
        updateWorkspaceBannerVisibility()
        refreshWorkspaceTrustUI()
        multiLanguageServicesCoordinator.handleTrustRevoked()
        languageHoverController.invalidateCache()
        refreshLanguageServerStateUI()
        Task {
            await diagnosticsLog.record(
                subsystem: .workspace,
                level: .info,
                message: Localized.string("Workspace trust revoked", comment: "Diagnostics log message recorded when a workspace's trust is revoked"),
                context: [
                    DiagnosticContextField(name: "workspaceRoot", category: .fullPath, value: identity.root.path)
                ]
            )
        }
    }

    @objc
    private func promptToToggleWorkspaceTrust(_ sender: Any?) {
        guard let window = view.window else {
            return
        }

        let shouldTrust = !trustStore.isTrusted(identity)
        let alert = NSAlert()
        alert.alertStyle = .warning
        if shouldTrust {
            alert.messageText = Localized.string(
                "Trust Workspace",
                comment: "Title of the confirmation alert for trusting a workspace"
            )
            alert.informativeText = Localized.string(
                "Trusting this workspace enables language servers and repository tools, which may execute code from this directory.",
                comment: "Explanation in the confirmation alert for trusting a workspace"
            )
            alert.addButton(
                withTitle: Localized.string(
                    "Trust Workspace",
                    comment: "Confirmation button title for trusting a workspace"
                )
            )
        } else {
            alert.messageText = Localized.string(
                "Revoke Trust",
                comment: "Title of the confirmation alert for revoking workspace trust"
            )
            alert.informativeText = Localized.string(
                "Revoking trust disables repository tools and stops running language servers for this workspace.",
                comment: "Explanation in the confirmation alert for revoking workspace trust"
            )
            alert.addButton(
                withTitle: Localized.string(
                    "Revoke Trust",
                    comment: "Confirmation button title for revoking workspace trust"
                )
            )
        }
        alert.addButton(
            withTitle: Localized.string(
                "Cancel",
                comment: "Button title canceling a workspace trust change"
            )
        )
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else {
                return
            }
            if shouldTrust {
                self.trustWorkspace(nil)
            } else {
                self.revokeTrust(nil)
            }
        }
    }
}

extension WorkspaceViewController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        cancelHover()
        definitionNavigationTask?.cancel()
        definitionNavigationTask = nil
        persistRestorableState()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }
        lastNormalWindowFrame = window.frame
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }
        if let pendingNormalWindowFrame {
            window.setFrame(pendingNormalWindowFrame, display: true)
            lastNormalWindowFrame = pendingNormalWindowFrame
            self.pendingNormalWindowFrame = nil
        } else {
            lastNormalWindowFrame = window.frame
        }
    }
}

extension WorkspaceViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleWordWrap(_:)):
            menuItem.state = layoutState.wordWrapEnabled ? .on : .off
            return true
        case #selector(navigateBack(_:)):
            return activeGroupController?.canGoBack ?? false
        case #selector(navigateForward(_:)):
            return activeGroupController?.canGoForward ?? false
        case #selector(closeActiveGroup(_:)):
            return layoutState.groups.count > 1
        default:
            return true
        }
    }
}

extension WorkspaceViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(
        _ outlineView: NSOutlineView,
        numberOfChildrenOfItem item: Any?
    ) -> Int {
        let relativePath = (item as? WorkspaceTreeNode)?.entry.relativePath ?? ""
        return children(of: relativePath).count
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        child index: Int,
        ofItem item: Any?
    ) -> Any {
        let relativePath = (item as? WorkspaceTreeNode)?.entry.relativePath ?? ""
        return children(of: relativePath)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? WorkspaceTreeNode)?.entry.kind == .directory
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? WorkspaceTreeNode else {
            return nil
        }

        let identifier = NSUserInterfaceItemIdentifier("workspace.fileCell")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(
            withIdentifier: identifier,
            owner: self
        ) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier

            let imageView = MaterialFileIconView()
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.setAccessibilityElement(false)
            imageView.translatesAutoresizingMaskIntoConstraints = false
            cell.imageView = imageView
            cell.addSubview(imageView)

            let textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingMiddle
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.textField = textField
            cell.addSubview(textField)

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 5),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        cell.textField?.stringValue = node.entry.url.lastPathComponent
        cell.textField?.toolTip = node.entry.relativePath
        cell.textField?.textColor = .labelColor
        var badgeDescription: String?
        if node.entry.kind == .file, let badge = gitCoordinator.badge(forRelativePath: node.entry.relativePath) {
            cell.textField?.stringValue += "  \(badge.letter)"
            cell.textField?.textColor = badgeColor(for: badge)
            badgeDescription = badge.accessibilityDescription
        }
        let displayName = node.entry.url.lastPathComponent
        let materialIconView = cell.imageView as? MaterialFileIconView
        var symbolName: String?
        let kindDescription: String
        switch node.entry.kind {
        case .directory:
            materialIconView?.fileName = nil
            symbolName = "folder"
            kindDescription = Localized.string("folder", comment: "Accessibility kind description for a directory row in the workspace Explorer")
        case .file:
            materialIconView?.fileName = node.entry.relativePath
            if materialIconView == nil {
                cell.imageView?.image = MaterialFileIconProvider.shared.image(
                    forFileName: node.entry.relativePath,
                    appearance: outlineView.effectiveAppearance
                )
            }
            symbolName = nil
            kindDescription = Localized.string("file", comment: "Accessibility kind description for a file row in the workspace Explorer")
        case .symbolicLink:
            materialIconView?.fileName = nil
            symbolName = "link"
            kindDescription = Localized.string("symbolic link", comment: "Accessibility kind description for a symbolic-link row in the workspace Explorer")
        }
        if let symbolName {
            cell.imageView?.image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: nil
            )
        }
        // A dedicated accessibility label — distinct from the visually
        // displayed `stringValue`, which appends a terse single-letter
        // badge — so VoiceOver reads the file/folder's name, its kind,
        // and (when present) its full-word Git status rather than a
        // color-only or letter-only cue (SPEC 14).
        cell.textField?.setAccessibilityLabel(
            [displayName, kindDescription, badgeDescription]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
        return cell
    }

    /// Explorer badge tint (SPEC 9.1: "Explorer badges"), matching most
    /// editors' color convention for added/modified/deleted/renamed/
    /// untracked/conflicted.
    private func badgeColor(for badge: GitExplorerBadge) -> NSColor {
        switch badge {
        case .added:
            return .systemGreen
        case .modified:
            return .systemOrange
        case .deleted:
            return .systemRed
        case .renamed:
            return .systemBlue
        case .untracked:
            return .systemTeal
        case .conflicted:
            return .systemPurple
        }
    }
}

final class WorkspaceTreeNode: NSObject {
    let entry: WorkspaceFileEntry

    init(entry: WorkspaceFileEntry) {
        self.entry = entry
    }
}
