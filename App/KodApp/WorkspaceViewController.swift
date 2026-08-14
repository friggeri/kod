import AppKit
import CodeViewport
import DiagnosticsCore
import EditorUI
import GitCore
import GitUI
import KodUIComponents
import LanguageAdapters
import LanguageClient
import PreviewCore
import PreviewUI
import SearchCore
import SearchUI
import SettingsCore
import SourceIO
import SourceModel
import ThemeCore
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
private final class WorkspaceRootView: NSView {
    var onEffectiveAppearanceChanged: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChanged?()
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
final class WorkspaceToolbarDelegate: NSObject, NSToolbarDelegate {
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
    private enum SidebarMode: Int {
        case explorer
        case sourceControl
        case search
        case problems
    }

    /// The headless owner of this workspace's non-view subsystems
    /// (discovery, filename index, watcher, search, Git, language
    /// services, layout persistence). The controller subscribes to its
    /// events and delegates lifecycle to it; it owns none of that
    /// lifetime itself.
    let session: WorkspaceSession

    var identity: WorkspaceIdentity {
        session.identity
    }

    var filenameIndex: FilenameIndex {
        session.filenameIndex
    }

    private var scanner: WorkspaceScanner {
        session.scanner
    }

    var trustStore: WorkspaceTrustStore {
        session.dependencies.trustStore
    }

    var layoutStore: WorkspaceLayoutStore {
        session.dependencies.layoutStore
    }

    /// Shared, app-lifetime bounded diagnostics log (SPEC 15), supplied by
    /// `AppEnvironment` and threaded into every subsystem the session
    /// owns — never a silently-created per-workspace instance.
    var diagnosticsLog: BoundedEventLog {
        session.dependencies.diagnosticsLog
    }

    private var appearanceCenter: AppearanceCenter {
        session.dependencies.appearanceCenter
    }

    // MARK: - Collaborators
    //
    // This controller is composition plus the `NSResponder` action
    // surface: every cohesive policy/presentation concern below owns its
    // own state and views, and this class only wires their intents to the
    // session and to each other.

    /// Window/split geometry: frame validation, sidebar width, fullscreen
    /// bookkeeping. Driven by `WorkspaceWindowController` for window-level
    /// events and by this controller for the split it owns.
    let geometry: WorkspaceGeometryController

    /// The Explorer tree: outline view, node cache, filtering, decoration.
    let explorer: WorkspaceExplorerController

    /// Trust banner, status control and confirmation UI. Built lazily so
    /// the one-time "show the banner on first open" claim is made when the
    /// banner is actually built, exactly as before.
    private lazy var trustPresenter = makeTrustPresenter()

    /// Queueing/suppression state machine behind the language-support
    /// banner. The banner itself is rendered here.
    private let languagePrompts = LanguageSupportPromptQueue()

    /// One request/projection/error policy for both Quick Diff consumers.
    private lazy var quickDiff = GitQuickDiffCoordinator(
        dependencies: makeQuickDiffDependencies()
    )

    private let workspaceBannerStack = NSStackView()
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
    private lazy var workspaceHealthPresenter = WorkspaceHealthPresenter(
        session: session
    )
    /// The official installation-documentation URL to open when the
    /// banner's "Find a Server.../Installation Help..." button is
    /// pressed for the *currently presented* missing-server prompt. Set
    /// only when that prompt is for a known default profile with
    /// shipped guidance (`DefaultLanguageServerInstallationGuides`);
    /// `nil` for unknown/custom profiles or default profiles without
    /// guidance, which fall back to the public LSP directory.
    private var currentMissingLanguageInstallationDocumentationURL: URL?
    private let sidebarModeControl = NSSegmentedControl(
        labels: [
            Localized.string("Explorer", comment: "Sidebar mode segment title for the file Explorer"),
            Localized.string("Source Control", comment: "Sidebar mode segment title for the Source Control panel"),
            Localized.string("Search", comment: "Sidebar mode segment title for workspace Search"),
            Localized.string("Problems", comment: "Sidebar mode segment title for the Problems panel")
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let workspaceTitleLabel = NSTextField(labelWithString: "")
    private var workspaceSplitViewController: NSSplitViewController!
    private var previewSourceControlView: WorkspacePreviewSourceControlView?
    private var explorerContainer: NSView!
    private var searchSidebarController: SearchSidebarViewController!
    private var problemsViewController: ProblemsViewController!
    private var sourceControlSidebarController: SourceControlSidebarViewController!
    /// Read-only Git context for this workspace (SPEC 9): `nil` for
    /// non-Git folders, kept fresh from the same FSEvents pipeline that
    /// drives Explorer/index live updates. Owned by the session.
    private var gitCoordinator: GitWorkspaceCoordinator {
        session.gitCoordinator
    }
    var workspaceDiagnosticsStore: WorkspaceDiagnosticsStore {
        session.dependencies.diagnosticsStore
    }
    private var gitBlamePanelController: GitBlamePanelController?
    var multiLanguageServicesCoordinator: MultiLanguageServicesCoordinator {
        session.languageServices
    }
    private let languageServerStateLabel = NSTextField(labelWithString: "")
    private let languageServerRestartButton = NSButton(
        title: Localized.string("Restart", comment: "Button title to restart the language server"),
        target: nil,
        action: nil
    )
    /// The Explorer's tree model, kept on the Explorer collaborator. Still
    /// reachable here because the workspace's live-update pipeline (and its
    /// tests) speak in terms of the workspace, not the sidebar widget.
    var entriesByParent: [String: [WorkspaceFileEntry]] {
        get { explorer.entriesByParent }
        set { explorer.entriesByParent = newValue }
    }
    private var sourceLoadTask: Task<Void, Never>?
    private var appearanceObservation: SettingsObservation?
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
    private var hasStartedSession = false
    private var lastLanguageServerStates: [String: LanguageServerState] = [:]

    /// Every loaded/reloaded snapshot gets a strictly increasing version so
    /// stale in-flight syntax/navigation work for a superseded snapshot is
    /// rejected rather than shown (SPEC 5.6).
    private var nextSnapshotVersion = 1
    var languageSupportService: LanguageSupportService {
        session.dependencies.languageSupportService
    }
    var onShowLanguageSupportSettings: ((String?) -> Void)?

    var layoutState: WorkspaceLayoutState
    var splitContainer: SplitContainerViewController!

    init(session: WorkspaceSession) {
        self.session = session
        let restoredLayout = session.loadLayoutState()
        self.layoutState = restoredLayout
        self.geometry = WorkspaceGeometryController(
            restoredSidebarWidth: restoredLayout.geometry?.sidebarWidth
        )
        self.explorer = WorkspaceExplorerController(
            discoveryOptions: { session.discoveryOptions },
            gitDecoration: { relativePath, isDirectory in
                session.gitCoordinator.explorerDecoration(
                    forRelativePath: relativePath,
                    isDirectory: isDirectory
                )
            }
        )
        super.init(nibName: nil, bundle: nil)
        geometry.windowProvider = { [weak self] in
            self?.viewIfLoaded?.window
        }
        explorer.setDecorationColors(appearanceCenter.snapshot.theme.git)
        explorer.onIntent = { [weak self] intent in
            self?.handleExplorerIntent(intent)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLanguageSupportChanged(_:)),
            name: .kodLanguageSupportChanged,
            object: session.dependencies.languageSupportService
        )
        appearanceObservation = appearanceCenter.observe {
            [weak self] snapshot in
            self?.refreshGitDecorationAppearance(snapshot)
        }
        configureSessionEventHandlers()
    }

    /// Convenience composition path used by the app's single-window
    /// construction and by tests: builds the workspace's session from
    /// explicit dependencies, then wires this controller to it.
    convenience init(
        identity: WorkspaceIdentity,
        dependencies: WorkspaceDependencies
    ) {
        self.init(
            session: dependencies.makeWorkspaceSession(identity: identity)
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        sourceLoadTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    private func makeTrustPresenter() -> WorkspaceTrustPresenter {
        let isBannerEligible: Bool
        do {
            isBannerEligible = try trustStore
                .claimInitialTrustBannerPresentation(for: identity)
        } catch {
            isBannerEligible = true
            recordTrustPersistenceFailure(
                message: Localized.string(
                    "Workspace trust state could not be saved",
                    comment: "Workspace health summary when trust banner persistence fails"
                ),
                error: error
            )
        }
        let presenter = WorkspaceTrustPresenter(
            isBannerEligible: isBannerEligible
        )
        presenter.presentingWindow = { [weak self] in
            self?.viewIfLoaded?.window
        }
        presenter.onIntent = { [weak self] intent in
            self?.handleTrustIntent(intent)
        }
        presenter.render(isTrusted: trustStore.isTrusted(identity))
        // Assigned only after the initial render so the workspace's banner
        // stack is never asked about a presenter that is still being
        // constructed.
        presenter.onBannerVisibilityChanged = { [weak self] in
            self?.updateWorkspaceBannerVisibility()
        }
        return presenter
    }

    private func makeQuickDiffDependencies() -> GitQuickDiffCoordinator.Dependencies {
        GitQuickDiffCoordinator.Dependencies(
            workspaceRoot: identity.root,
            diagnosticsLog: diagnosticsLog,
            gitContext: { [weak self] in self?.gitCoordinator.context },
            latestStatus: { [weak self] in self?.gitCoordinator.latestStatus },
            loadSnapshot: { [weak self] relativePath in
                guard let self else {
                    throw CancellationError()
                }
                return try await self.loadSnapshot(
                    relativePath: relativePath,
                    bumpingVersion: true
                )
            },
            nextSnapshotVersion: { [weak self] in
                self?.nextVersion() ?? 1
            },
            groupController: { [weak self] groupID in
                self?.splitContainer?.controller(for: groupID)
            },
            allGroupControllers: { [weak self] in
                self?.splitContainer?.allGroupControllers ?? []
            }
        )
    }

    /// Subscribes to the session's narrow event surface. Every subsystem
    /// lifetime stays with the session; this controller only reacts.
    private func configureSessionEventHandlers() {
        session.onDiscoveryStatus = { [weak self] status in
            self?.discoveryStatusDidChange(status)
        }
        session.onDiscoveryBatch = { [weak self] batch in
            self?.apply(batch)
        }
        session.onFileChangeBatch = { [weak self] batch in
            self?.handleWorkspaceChangeBatch(batch)
        }
        session.onGitStatusChanged = { [weak self] snapshot in
            self?.gitStatusDidChange(snapshot)
        }
        session.onLanguageStateChanged = { [weak self] in
            self?.languageServerStateDidChange()
        }
        session.onHealthChanged = { [weak self] health in
            self?.workspaceHealthDidChange(health)
        }
        // Problems is driven by the raw workspace diagnostics store; only
        // snapshot-normalized diagnostics reach the open editors.
        session.onLanguageDiagnostics = { [weak self] url, diagnostics in
            self?.splitContainer?.allGroupControllers.forEach {
                $0.applyDiagnostics(url: url, diagnostics: diagnostics)
            }
        }
        session.onLanguageMissingServer = { [weak self] profile in
            self?.enqueueMissingLanguageServer(profile)
        }
        session.onLanguageUnknownFileType = { [weak self] url in
            self?.enqueueUnknownLanguageProfile(for: url)
        }
        session.persistState = { [weak self] in
            self?.persistRestorableState()
        }
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
    /// reset, deleted, or given an explicit executable). The registry has
    /// already reloaded itself from its own store observation, so this
    /// reads the current snapshot and, if the change affects the
    /// currently displayed missing-server/unknown-type prompt, re-resolves
    /// it — resolving a configuration change may require re-running
    /// discovery, so this is the one path allowed to call
    /// `languageSupportService.refresh()`.
    private func handleLanguageProfileConfigurationChanged(
        languageKey: String
    ) {
        languagePrompts.bumpGeneration()
        reloadChangedSyntaxDefinitions()
        languagePrompts.removeQueuedMissingServer(languageKey: languageKey)
        if languagePrompts.currentMissingServerKey == languageKey {
            Task { [weak self] in
                guard let self else {
                    return
                }
                await self.languageSupportService.refresh()
                guard self.languagePrompts.currentMissingServerKey == languageKey else {
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
        } else if let currentUnknownLanguageURL = languagePrompts.currentUnknownFileTypeURL,
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
    /// about the profile's configuration changed, so this never calls
    /// `refresh()` again (which would risk a notify → refresh → notify
    /// loop) — it only clears the now-stale missing-server queue/banner
    /// for this key and asks the coordinator to retry/restart the
    /// affected service. An unrelated unknown-type or different-profile
    /// prompt currently on screen is left alone.
    private func handleLanguageServerExecutableDiscovered(
        languageKey: String
    ) {
        languagePrompts.removeQueuedMissingServer(languageKey: languageKey)
        if languagePrompts.currentMissingServerKey == languageKey,
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

    // MARK: - Collaborator intents

    private func handleExplorerIntent(_ intent: WorkspaceExplorerController.Intent) {
        switch intent {
        case .openFile(let entry):
            open(entry)
        case .changeVisibility(let options):
            startDiscovery(options: options)
        }
    }

    private func handleTrustIntent(_ intent: WorkspaceTrustPresenter.Intent) {
        switch intent {
        case .grantTrust:
            trustWorkspace(nil)
        case .revokeTrust:
            revokeTrust(nil)
        case .dismissBanner:
            break
        }
    }


    override func loadView() {
        let container = WorkspaceRootView()
        container.onEffectiveAppearanceChanged = { [weak self] in
            self?.appearanceCenter.refresh()
        }
        collapseEmptyGroupsKeepingOne()

        configureLanguageSupportBanner()
        configureWorkspaceBannerStack()
        trustPresenter.bannerView.translatesAutoresizingMaskIntoConstraints = false

        let outerSplit = NSSplitViewController()
        workspaceSplitViewController = outerSplit
        geometry.attach(splitViewController: outerSplit)
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

        let groupAppearanceCenter = appearanceCenter
        splitContainer = SplitContainerViewController(
            root: layoutState.root,
            makeGroupController: { [weak self, groupAppearanceCenter] id in
                self?.makeGroupController(for: id)
                    ?? EditorGroupViewController(
                        groupID: id,
                        state: EditorGroupState(id: id),
                        appearanceCenter: groupAppearanceCenter
                    )
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
            trustPresenter.bannerView.heightAnchor.constraint(
                equalTo: trustPresenter.bannerHeightReferenceView.heightAnchor,
                constant: 12
            ),
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
        updateWorkspaceBannerVisibility()

        view = container
        refreshActiveGroupHighlighting()
        refreshLanguageServerStateUI()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !hasStartedSession else {
            return
        }
        hasStartedSession = true
        session.begin()
        refreshLanguageServerStateUI()
    }

    /// Sidebar visibility is a window-geometry concern; the geometry
    /// controller owns the width bookkeeping that survives a collapse.
    @objc
    func toggleSidebar(_ sender: Any?) {
        geometry.toggleSidebar(sender)
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

    func restoreWorkspaceGeometryIfNeeded() {
        geometry.restoreIfNeeded(geometry: layoutState.geometry)
    }

    @objc
    private func workspaceSplitViewDidResize(_ notification: Notification) {
        geometry.splitViewDidResize()
    }

    private func captureWorkspaceGeometry() {
        guard isViewLoaded else {
            return
        }
        guard let captured = geometry.captureGeometry(
            persistedFrame: layoutState.geometry?.windowFrame
        ) else {
            return
        }
        layoutState.geometry = captured
    }


    // MARK: - Git (SPEC 9)

    private func gitStatusDidChange(_ snapshot: GitStatusSnapshot?) {
        guard isViewLoaded else {
            return
        }
        sourceControlSidebarController.update(
            snapshot: snapshot,
            presentationIndex: gitCoordinator.presentationIndex
        )
        reloadVisibleExplorerDecorations()
        refreshVisibleQuickDiff(snapshot: snapshot)
        quickDiff.refreshSelection(snapshot: snapshot)
    }

    private func reloadVisibleExplorerDecorations() {
        guard isViewLoaded else {
            return
        }
        explorer.reloadVisibleDecorations()
    }

    private func refreshGitDecorationAppearance(
        _ snapshot: AppearanceCenter.Snapshot? = nil
    ) {
        let appearance = snapshot ?? appearanceCenter.snapshot
        explorer.setDecorationColors(appearance.theme.git)
        splitContainer?.allGroupControllers.compactMap(\.currentDocumentController).forEach {
            $0.theme = appearance.theme
            $0.fontSettings = appearance.fontSettings
        }
        quickDiff.refreshTheme()
        reloadVisibleExplorerDecorations()
    }

    /// Refreshes the gutter decorations of every visible editor. Guarded
    /// here (not in the coordinator) because the split container only
    /// exists once this controller's view is loaded.
    private func refreshVisibleQuickDiff(snapshot: GitStatusSnapshot?) {
        guard isViewLoaded, splitContainer != nil else {
            return
        }
        quickDiff.refreshVisibleEditors(snapshot: snapshot)
    }

    /// Reveals the Source Control sidebar (mirrors `searchWorkspace(_:)`).
    @objc
    func showSourceControl(_ sender: Any?) {
        sidebarModeControl.selectedSegment = SidebarMode.sourceControl.rawValue
        sidebarModeChanged(nil)
    }

    /// Reveals the Problems sidebar — the "diagnose" step of the primary
    /// open → search → navigate → diagnose → diff → preview workflow
    /// (SPEC 5.7) — as a real, menu-reachable command rather than only
    /// via Tab-then-arrow-keys to `sidebarModeControl`.
    @objc
    func showProblems(_ sender: Any?) {
        sidebarModeControl.selectedSegment = SidebarMode.problems.rawValue
        sidebarModeChanged(nil)
    }

    /// Toggles the active tab's Source/Preview mode from the window toolbar,
    /// main menu, or keyboard shortcut (SPEC 5.7).
    @objc
    func togglePreviewSource(_ sender: Any?) {
        activeGroupController?.togglePreviewSource(sender)
    }

    @objc
    func showPreviousGitChange(_ sender: Any?) {
        activeGitQuickDiffController?.showPreviousHunk()
    }

    @objc
    func showNextGitChange(_ sender: Any?) {
        activeGitQuickDiffController?.showNextHunk()
    }

    /// The Quick Diff controller the next/previous-change commands act
    /// on: an open Quick Diff tab first, otherwise the gutter decoration
    /// of the visible document.
    private var activeGitQuickDiffController: GitQuickDiffController? {
        guard let groupController = activeGroupController else {
            return nil
        }
        if let controller = groupController.currentQuickDiffController {
            return controller
        }
        guard let documentController = groupController.currentVisibleDocumentController else {
            return nil
        }
        return quickDiff.visibleController(for: documentController)
    }

    private func openQuickDiff(for selection: SourceControlSidebarViewController.FileSelection) {
        guard let groupController = activeGroupController else {
            return
        }
        quickDiff.openSelection(selection, in: groupController)
    }

    /// Shows blame for the currently selected Explorer file (wired to the
    /// Explorer outline's contextual menu).
    @objc
    func showGitBlameForSelectedFile(_ sender: Any?) {
        guard let relativePath = explorer.actionTargetFileRelativePath,
              let context = gitCoordinator.context,
              let window = view.window else {
            return
        }
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

    /// Queues a missing-server prompt. Trust is the gate; the queue owns
    /// de-duplication and per-session suppression.
    private func enqueueMissingLanguageServer(
        _ profile: LanguageProfile
    ) {
        guard trustStore.isTrusted(identity),
              languagePrompts.enqueueMissingServer(languageKey: profile.identifier) else {
            return
        }
        Task {
            await presentNextMissingLanguageServerIfNeeded()
        }
    }

    private func enqueueUnknownLanguageProfile(for url: URL) {
        guard trustStore.isTrusted(identity),
              languagePrompts.enqueueUnknownFileType(url: url) else {
            return
        }
        Task {
            await presentNextMissingLanguageServerIfNeeded()
        }
    }

    /// Drains the prompt queue until something is actually worth showing,
    /// re-running discovery for each candidate. Queueing, suppression and
    /// generation rules live in `LanguageSupportPromptQueue`; this method
    /// only performs the awaits it cannot, and renders the result.
    private func presentNextMissingLanguageServerIfNeeded() async {
        guard languagePrompts.beginPreparing() else {
            return
        }
        defer { languagePrompts.endPreparing() }

        while trustStore.isTrusted(identity) {
            guard let languageKey = languagePrompts.dequeueMissingServerCandidate() else {
                break
            }

            let promptGeneration = languagePrompts.generation
            await languageSupportService.refresh()
            guard !Task.isCancelled, trustStore.isTrusted(identity) else {
                return
            }
            guard promptGeneration == languagePrompts.generation else {
                languagePrompts.requeueMissingServerCandidate(languageKey)
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

            languagePrompts.activate(.missingServer(languageKey: languageKey))
            renderMissingServerPrompt(item: item)
            return
        }

        while trustStore.isTrusted(identity) {
            guard let url = languagePrompts.dequeueUnknownFileTypeCandidate() else {
                break
            }
            guard languageSupportService.profileRegistry.resolve(url: url) == nil else {
                continue
            }
            languagePrompts.activate(.unknownFileType(url: url))
            renderUnknownFileTypePrompt(url: url)
            return
        }
    }

    private func renderMissingServerPrompt(item: LanguageSupportItem) {
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
    }

    private func renderUnknownFileTypePrompt(url: URL) {
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
    }

    private func finishMissingLanguagePrompt(
        suppressForSession: Bool
    ) {
        languagePrompts.finishCurrent(suppressForSession: suppressForSession)
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
        let profileIdentifier: String?
        if let unknownFileTypeURL = languagePrompts.currentUnknownFileTypeURL {
            languageSupportService.beginAddingProfile(
                prefilling: unknownFileTypeURL
            )
            profileIdentifier = nil
        } else {
            profileIdentifier = languagePrompts.currentMissingServerKey
        }
        onShowLanguageSupportSettings?(profileIdentifier)
    }

    @objc
    private func chooseMissingLanguageServer(_ sender: Any?) {
        if languagePrompts.currentUnknownFileTypeURL != nil {
            openLanguageSupportSettings(sender)
            return
        }
        guard let languageKey = languagePrompts.currentMissingServerKey,
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
            navigate(to: target.location)
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
            self.navigate(to: target.location)
        }
    }

    private func languageProviderIdentifier(for url: URL) -> String {
        return multiLanguageServicesCoordinator.languageKey(forURL: url)
            ?? url.pathExtension.lowercased()
    }

    /// Opens a provider-bound cross-file location (a definition, a Peek
    /// result, a workspace symbol, a hierarchy item) in the active editor
    /// group and selects it, converting its wire range through the
    /// position encoding negotiated by the provider that produced it —
    /// never one inferred from the target file, which can belong to a
    /// different language profile entirely.
    private func navigate(to location: ProviderBoundLocation) {
        openLSPLocation(url: location.url) { snapshot in
            location.utf8Range(in: snapshot)
        }
    }

    /// Navigates to a published diagnostic from the Problems list. A
    /// diagnostic is always reported for the file it belongs to, by that
    /// file's own provider, so its wire range is converted through the
    /// service that owns the file (SPEC 6.4).
    private func navigateToDiagnostic(url: URL, range: LSPRange) {
        openLSPLocation(url: url) { [weak self] snapshot in
            guard let self else {
                return nil
            }
            return await self.multiLanguageServicesCoordinator.utf8Range(
                for: range,
                in: snapshot
            )
        }
    }

    /// Opens `url`'s relative path in the active editor group and selects
    /// whatever UTF-8 range `resolveUTF8Range` produces for the loaded
    /// snapshot, without changing the originating list (SPEC 6.4).
    private func openLSPLocation(
        url: URL,
        resolveUTF8Range: @escaping @MainActor (SourceSnapshot) async -> Range<Int>?
    ) {
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
                guard !Task.isCancelled else {
                    return
                }
                let utf8Range = await resolveUTF8Range(snapshot)
                guard !Task.isCancelled,
                      let groupController = self.splitContainer.controller(
                        for: self.layoutState.activeGroupID
                      ) else {
                    return
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
                await diagnosticsLog.record(
                    subsystem: .languageServer,
                    level: .warning,
                    message: Localized.string(
                        "Diagnostic navigation failed",
                        comment: "Diagnostics log message recorded when a Problems item cannot be opened"
                    ),
                    context: [
                        DiagnosticContextField(
                            name: "path",
                            category: .fullPath,
                            value: url.path
                        ),
                        DiagnosticContextField(
                            name: "reason",
                            category: .diagnosticMessage,
                            value: String(describing: error)
                        )
                    ]
                )
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
                    self?.navigate(to: result.location)
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
                    self?.navigate(to: item.selectionLocation)
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
    func toggleMinimap(_ sender: Any?) {
        layoutState.minimapEnabled.toggle()
        splitContainer.allGroupControllers.forEach { $0.minimapEnabled = layoutState.minimapEnabled }
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
        var commands: [PaletteCommand] = []
        let catalog = WorkspaceCommandCatalog.shared
        for id in catalog.paletteOrder {
            guard let metadata = catalog.metadata(for: id) else {
                continue
            }
            switch metadata.surface {
            case .menuAndPalette, .paletteOnly:
                let command = PaletteCommand(
                    id: metadata.id.rawValue,
                    title: metadata.paletteTitle
                ) { [weak self] in
                    guard let self else {
                        return
                    }
                    NSApp.sendAction(metadata.action, to: self, from: nil)
                }
                commands.append(command)
            case .menuOnly:
                break
            }
        }
        return commands
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
        reportDocumentsClosedForGroupsRemovedFromLayout()
        splitContainer.rebuild(root: layoutState.root)
        refreshActiveGroupHighlighting()
        persistLayout()
    }

    /// Reports every document still held by a group that `layoutState` no
    /// longer contains, before `SplitContainerViewController.rebuild`
    /// releases its controller. Without this the language services
    /// coordinator would only learn about those panes whenever a later
    /// registration change swept the released weak entries.
    private func reportDocumentsClosedForGroupsRemovedFromLayout() {
        let survivingGroupIDs = Set(layoutState.root.groupIDs)
        for controller in splitContainer.allGroupControllers
        where !survivingGroupIDs.contains(controller.groupID) {
            controller.prepareForRemovalFromWorkspace()
        }
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
        let controller = EditorGroupViewController(
            groupID: id,
            state: state,
            appearanceCenter: appearanceCenter
        )
        controller.wordWrapEnabled = layoutState.wordWrapEnabled
        controller.minimapEnabled = layoutState.minimapEnabled
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
        controller.onStateChange = { [weak self, weak controller] groupID, state in
            guard let self, let controller else {
                return
            }
            self.layoutState.groups[groupID] = state
            if state.tabs.isEmpty, self.layoutState.groups.count > 1 {
                self.handleCloseGroup(groupID: groupID)
            } else {
                self.persistLayout()
            }
            self.quickDiff.handleGroupStateChange(
                groupID: groupID,
                controller: controller
            )
            self.refreshVisibleQuickDiff(snapshot: self.gitCoordinator.latestStatus)
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
            guard let self else {
                return
            }
            self.refreshVisibleQuickDiff(snapshot: self.gitCoordinator.latestStatus)
            guard self.layoutState.activeGroupID == groupID else {
                return
            }
            self.previewSourceControlView?.update(state)
        }
        controller.onDocumentReady = { [weak self] relativePath, documentController in
            guard let self else {
                return
            }
            self.quickDiff.handleDocumentReady(
                groupID: id,
                relativePath: relativePath,
                controller: controller
            )
            self.configureLanguageInteractions(for: documentController)
            self.multiLanguageServicesCoordinator.handleDocumentReady(
                relativePath: relativePath,
                controller: documentController
            )
            self.refreshLanguageServerStateUI()
            self.refreshVisibleQuickDiff(snapshot: self.gitCoordinator.latestStatus)
        }
        controller.onActiveDocumentChange = { [weak self] _ in
            self?.cancelHover()
            self?.refreshLanguageServerStateUI()
        }
        controller.onDocumentClosed = { [weak self] relativePath, documentController in
            self?.multiLanguageServicesCoordinator.handleDocumentClosed(
                relativePath: relativePath,
                controller: documentController
            )
        }
        return controller
    }

    private func reloadChangedSyntaxDefinitions() {
        splitContainer?.allGroupControllers.forEach {
            $0.reloadChangedSyntaxDefinitions()
        }
    }

    /// Starts (once) the explicit shutdown of this workspace's session —
    /// including its language services. Never blocks the close: no alert,
    /// no modal wait. The returned task retains the session, so every
    /// subsystem's teardown runs to completion after the window is gone,
    /// regardless of when ARC releases this controller.
    @discardableResult
    func beginLanguageServicesShutdown() -> Task<Void, Never> {
        session.beginShutdown()
    }

    /// Headless seam: awaits the shutdown `windowWillClose` starts, so
    /// tests can assert it actually completes rather than sleeping.
    func shutdownLanguageServices() async {
        await session.shutdown()
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

    func prepareForWindowClose() {
        cancelHover()
        definitionNavigationTask?.cancel()
        definitionNavigationTask = nil
        if isViewLoaded {
            quickDiff.cancelAll()
        }
        persistRestorableState()
    }

    /// Layout persistence is best effort from the UI's point of view: a
    /// state that fails validation or encoding must not interrupt
    /// editing. The session owns the persistence boundary, including
    /// recording the failure into health/diagnostics.
    private func persistLayout() {
        session.persistLayout(layoutState)
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
            theme: appearanceCenter.snapshot.theme,
            fontSettings: appearanceCenter.snapshot.fontSettings,
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
            try SourceSnapshotLoader(
                renderingSafetyPolicy: .codeViewportDefault
            ).load(url: url)
        }.value
    }

    // MARK: - Sidebar / Explorer

    private func configureWorkspaceBannerStack() {
        workspaceBannerStack.orientation = .vertical
        workspaceBannerStack.alignment = .width
        workspaceBannerStack.spacing = 6
        workspaceBannerStack.addArrangedSubview(trustPresenter.bannerView)
        workspaceBannerStack.addArrangedSubview(languageSupportBanner)
        workspaceBannerStack.addArrangedSubview(workspaceHealthPresenter.view)
        workspaceHealthPresenter.update(session.health)
        workspaceBannerStack.isHidden = true
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

    /// Re-renders both trust surfaces from the store's current, live
    /// state (SPEC 13.1: trusting/revoking a workspace must be
    /// immediately reflected). Called after both `trustWorkspace` and
    /// `revokeTrust` so neither control shows a stale state.
    private func refreshWorkspaceTrustUI() {
        trustPresenter.render(isTrusted: trustStore.isTrusted(identity))
    }

    private func updateWorkspaceBannerVisibility() {
        let isVisible = !trustPresenter.isBannerHidden
            || !languageSupportBanner.isHidden
            || !workspaceHealthPresenter.view.isHidden
        workspaceBannerStack.isHidden = !isVisible
        contentTopWithTrustBannerConstraint?.isActive = isVisible
        contentTopWithoutTrustBannerConstraint?.isActive = !isVisible
    }

    private func workspaceHealthDidChange(_ health: WorkspaceHealth) {
        workspaceHealthPresenter.update(health)
        updateWorkspaceBannerVisibility()
    }

    private func makeSidebar() -> NSView {
        let container = NSView()
        container.identifier = NSUserInterfaceItemIdentifier("workspace.sidebar")

        sidebarModeControl.segmentStyle = .texturedRounded
        sidebarModeControl.selectedSegment = SidebarMode.explorer.rawValue
        sidebarModeControl.target = self
        sidebarModeControl.action = #selector(sidebarModeChanged(_:))
        sidebarModeControl.identifier = NSUserInterfaceItemIdentifier("workspace.sidebarMode")
        sidebarModeControl.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        sidebarModeControl.translatesAutoresizingMaskIntoConstraints = false

        explorerContainer = explorer.makeView()
        explorerContainer.translatesAutoresizingMaskIntoConstraints = false

        let workspaceSession = session
        let searchController = SearchSidebarViewController(
            root: identity.root,
            diagnosticsLog: diagnosticsLog,
            makeSearcher: { try workspaceSession.textSearcher() },
            runSearchTask: { operation in
                workspaceSession.runSearch(operation)
            },
            reportSearchHealth: { reason in
                if let reason {
                    workspaceSession.reportSearchFailure(reason: reason)
                } else {
                    workspaceSession.reportSearchSuccess()
                }
            },
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
            diagnosticsStore: workspaceDiagnosticsStore,
            onSelectDiagnostic: { [weak self] selection in
                self?.navigateToDiagnostic(url: selection.url, range: selection.range)
            }
        )
        problemsViewController = problemsController
        addChild(problemsController)
        problemsController.view.translatesAutoresizingMaskIntoConstraints = false
        problemsController.view.isHidden = true

        let sourceControlController = SourceControlSidebarViewController(
            appearanceCenter: appearanceCenter,
            onSelectFile: { [weak self] selection in
                self?.openQuickDiff(for: selection)
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
        container.addSubview(sourceControlController.view)
        NSLayoutConstraint.activate([
            sidebarModeControl.topAnchor.constraint(
                equalTo: container.safeAreaLayoutGuide.topAnchor,
                constant: 8
            ),
            sidebarModeControl.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            sidebarModeControl.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 8),
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

        let trustStatusButton = trustPresenter.statusButton

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

    @objc
    private func sidebarModeChanged(_ sender: Any?) {
        let mode = SidebarMode(rawValue: sidebarModeControl.selectedSegment) ?? .explorer
        explorerContainer.isHidden = mode != .explorer
        searchSidebarController.view.isHidden = mode != .search
        problemsViewController.view.isHidden = mode != .problems
        sourceControlSidebarController.view.isHidden = mode != .sourceControl
        if mode == .explorer {
            refreshGitDecorationAppearance()
        } else if mode == .search {
            searchSidebarController.focusSearchField()
        } else if mode == .sourceControl {
            sourceControlSidebarController.refreshAppearance()
        }
    }

    /// Reveals the Search sidebar and focuses its search field (Command-
    /// Shift-F, SPEC 5.7).
    @objc
    func searchWorkspace(_ sender: Any?) {
        sidebarModeControl.selectedSegment = SidebarMode.search.rawValue
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

    private func startDiscovery(
        options: WorkspaceDiscoveryOptions? = nil
    ) {
        session.startDiscovery(options: options)
    }

    /// Reflects the session's discovery lifecycle in the Explorer. The
    /// Explorer holds only the presentation state (tree + status text);
    /// the scan, its generation, and the filename index live in the
    /// session.
    private func discoveryStatusDidChange(_ status: WorkspaceDiscoveryStatus) {
        explorer.applyDiscoveryStatus(status)
    }

    private func apply(_ batch: WorkspaceDiscoveryBatch) {
        explorer.apply(batch)
    }

    // MARK: - Live filesystem updates (FSEvents)

    func handleWorkspaceChangeBatch(_ batch: WorkspaceChangeBatch) {
        session.handleFileSystemChanges(batch)

        if batch.mayHaveChangedIgnoreRules {
            for changed in batch.paths {
                let url = URL(fileURLWithPath: changed.path)
                if !FileManager.default.fileExists(atPath: changed.path) {
                    workspaceDiagnosticsStore.clear(resource: url)
                }
            }
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
            let outcome: WorkspaceClassificationOutcome
            do {
                outcome = try scanner.classify(path: url, root: identity.root)
            } catch {
                session.recordHealthIssue(
                    .discovery,
                    severity: .degraded,
                    message: Localized.string(
                        "A changed workspace path could not be classified",
                        comment: "Workspace health summary for an incremental file classification failure"
                    ),
                    reason: String(describing: error)
                )
                return
            }
            guard case .entry(let entry) = outcome else {
                explorer.removeEntry(relativePath: relativePath)
                session.updateFilenameIndex(removing: [relativePath])
                if outcome == .absent {
                    workspaceDiagnosticsStore.clear(resource: url)
                    tombstoneOpenTabsIfNeeded(relativePath: relativePath)
                }
                return
            }
            guard explorer.shouldInclude(entry) else {
                explorer.removeEntry(relativePath: relativePath)
                session.updateFilenameIndex(removing: [relativePath])
                return
            }
            explorer.addOrUpdate(entry)
            session.updateFilenameIndex(
                removing: [relativePath],
                appending: [entry]
            )

            guard entry.kind != .directory else {
                return
            }
            reloadOpenTabsIfNeeded(relativePath: relativePath)
        } else {
            workspaceDiagnosticsStore.clear(resource: url)
            explorer.removeEntry(relativePath: relativePath)
            session.updateFilenameIndex(removing: [relativePath])
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

    private func relativePath(of url: URL) -> String? {
        let rootPath = identity.root.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard targetPath.hasPrefix(prefix) else {
            return nil
        }
        return String(targetPath.dropFirst(prefix.count))
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

        session.beginExternalReload { [weak self] in
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
            try SourceSnapshotLoader(
                renderingSafetyPolicy: .codeViewportDefault
            ).load(url: url, version: version)
        }.value
    }

    private func nextVersion() -> Int {
        nextSnapshotVersion += 1
        return nextSnapshotVersion
    }

    func children(of relativePath: String) -> [WorkspaceTreeNode] {
        explorer.children(of: relativePath)
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
    func trustWorkspace(_ sender: Any?) {
        do {
            try trustStore.trust(identity)
            session.clearHealthIssue(.trust)
        } catch {
            recordTrustPersistenceFailure(
                message: Localized.string(
                    "Workspace trust could not be granted",
                    comment: "Workspace health summary when granting trust cannot be persisted"
                ),
                error: error
            )
            refreshWorkspaceTrustUI()
            return
        }
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
        do {
            try trustStore.revoke(identity)
            session.clearHealthIssue(.trust)
        } catch {
            recordTrustPersistenceFailure(
                message: Localized.string(
                    "Workspace trust revocation could not be saved",
                    comment: "Workspace health summary when revoking trust cannot be persisted"
                ),
                error: error
            )
        }
        languagePrompts.cancelAll()
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

    private func recordTrustPersistenceFailure(
        message: String,
        error: any Error
    ) {
        session.recordHealthIssue(
            scope: .subsystem(.trust),
            severity: .degraded,
            message: message,
            reason: String(describing: error),
            recoveryActionIDs: []
        )
    }

}

extension WorkspaceViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action,
              let metadata = WorkspaceCommandCatalog.shared.metadata(for: action) else {
            return true
        }

        switch metadata.validation {
        case .stateWordWrap:
            menuItem.state = layoutState.wordWrapEnabled ? .on : .off
            return true
        case .stateMinimap:
            menuItem.state = layoutState.minimapEnabled ? .on : .off
            return true
        case .requiresCanGoBack:
            return activeGroupController?.canGoBack ?? false
        case .requiresCanGoForward:
            return activeGroupController?.canGoForward ?? false
        case .requiresActiveGitQuickDiffController:
            return activeGitQuickDiffController != nil
        case .requiresActiveGroupCountGreaterThanOne:
            return layoutState.groups.count > 1
        case .alwaysEnabled, .systemStandard:
            return true
        }
    }
}
