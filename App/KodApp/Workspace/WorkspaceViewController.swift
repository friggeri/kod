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
import SyntaxCore
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

enum WorkspaceLocalLinkResolver {
    static func relativePath(for destination: String, root: URL) -> String? {
        guard let components = URLComponents(string: destination),
              components.scheme == nil,
              components.host == nil else {
            return nil
        }
        let path = components.percentEncodedPath.removingPercentEncoding
            ?? components.path
        guard !path.isEmpty, !path.hasPrefix("/") else {
            return nil
        }

        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = canonicalRoot
            .appendingPathComponent(path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPath = canonicalRoot.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard candidate.path.hasPrefix(prefix) else {
            return nil
        }
        return String(candidate.path.dropFirst(prefix.count))
    }
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
            let splitRightLabel = Localized.string(
                "Split Right",
                comment: "Accessibility label for the titlebar split-editor-right button"
            )
            let splitDownLabel = Localized.string(
                "Split Down",
                comment: "Accessibility label for the titlebar split-editor-down button"
            )
            let labels = [splitRightLabel, splitDownLabel]
            let images = [
                NSImage(
                    systemSymbolName: "square.split.2x1",
                    accessibilityDescription: splitRightLabel
                ) ?? NSImage(),
                NSImage(
                    systemSymbolName: "square.split.1x2",
                    accessibilityDescription: splitDownLabel
                ) ?? NSImage()
            ]
            let item = NSToolbarItemGroup(
                itemIdentifier: itemIdentifier,
                images: images,
                selectionMode: .momentary,
                labels: labels,
                target: self,
                action: #selector(performSplit(_:))
            )
            item.label = Localized.string(
                "Split Editor",
                comment: "Label for the grouped titlebar split-editor controls"
            )
            item.controlRepresentation = .expanded
            item.visibilityPriority = .high
            for (subitem, label) in zip(item.subitems, labels) {
                subitem.toolTip = label
            }
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

    @objc
    private func performSplit(_ sender: NSToolbarItemGroup) {
        switch sender.selectedIndex {
        case 0:
            target?.splitActiveGroupRight(sender)
        case 1:
            target?.splitActiveGroupDown(sender)
        default:
            assertionFailure("Unexpected split control index: \(sender.selectedIndex)")
        }
    }
}

@MainActor
final class WorkspaceViewController: NSViewController {
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

    /// Trust status control and confirmation UI.
    private lazy var trustPresenter = makeTrustPresenter()

    /// Queueing/suppression state machine behind the unknown-language prompt.
    private let languagePrompts = LanguageSupportPromptQueue()

    /// One request/projection/error policy for both Quick Diff consumers.
    private lazy var quickDiff = GitQuickDiffCoordinator(
        dependencies: makeQuickDiffDependencies()
    )

    private let workspaceBannerStack = NSStackView()
    private let languageSupportBanner = NSStackView()
    private let languageSupportBannerLabel = NSTextField(labelWithString: "")

    private let languageSupportRequestButton = NSButton(
        title: Localized.string(
            "Request Language...",
            comment: "Button title requesting support for an unknown file type"
        ),
        target: nil,
        action: nil
    )
    private let languageSupportNotNowButton = NSButton(
        title: Localized.string(
            "Not Now",
            comment: "Button title dismissing the unknown-file-type prompt for this session"
        ),
        target: nil,
        action: nil
    )
    private var contentTopWithBannerConstraint: NSLayoutConstraint?
    private var contentTopWithoutBannerConstraint: NSLayoutConstraint?
    private lazy var workspaceHealthPresenter = WorkspaceHealthPresenter(
        session: session
    )
    private var activityBarView: WorkspaceActivityBarView?
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
    private var statusBarView: WorkspaceStatusBarView?
    private weak var statusSelectionViewport: CodeViewport?
    /// The Explorer's tree model, kept on the Explorer collaborator. Still
    /// reachable here because the workspace's live-update pipeline (and its
    /// tests) speak in terms of the workspace, not the sidebar widget.
    var entriesByParent: [String: [WorkspaceFileEntry]] {
        get { explorer.entriesByParent }
        set { explorer.entriesByParent = newValue }
    }
    private var sourceLoadTask: Task<Void, Never>?
    private var explorerRevealTask: Task<Void, Never>?
    private var appearanceObservation: SettingsObservation?
    private var quickOpenController: QuickOpenPanelController?
    private var commandPaletteController: CommandPaletteController?
    private var goToLinePanelController: GoToLinePanelController?
    private var peekPanelController: PeekPanelController?
    private var hierarchyPanelController: HierarchyPanelController?
    private var definitionNavigationTask: Task<Void, Never>?
    private lazy var languageHoverPresenter = LanguageHoverPopoverPresenter(
        isWorkspaceTrusted: { [weak self] in
            guard let self else {
                return false
            }
            return self.trustStore.isTrusted(self.identity)
        },
        openLocalRelativePath: { [weak self] relativePath, documentController in
            guard let self else {
                return
            }
            self.splitContainer?.allGroupControllers
                .first { $0.currentDocumentController === documentController }?
                .onOpenLocalRelativePath?(relativePath)
        }
    )
    private lazy var languageHoverController = LanguageHoverController(
        hoverPresenter: languageHoverPresenter,
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
        let presenter = WorkspaceTrustPresenter()
        presenter.presentingWindow = { [weak self] in
            self?.viewIfLoaded?.window
        }
        presenter.onIntent = { [weak self] intent in
            self?.handleTrustIntent(intent)
        }
        presenter.render(isTrusted: trustStore.isTrusted(identity))
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
        session.onFilenameIndexChanged = { [weak self] in
            self?.quickOpenController?.refreshResults()
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
        session.onLanguageUnknownFileType = { [weak self] url in
            self?.enqueueUnknownFileType(for: url)
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

    /// A shipped profile's Command changed. Clear any unknown-file prompt that
    /// the updated registry can now resolve.
    private func handleLanguageProfileConfigurationChanged(
        languageKey _: String
    ) {
        languageHoverController.invalidateCache()
        definitionNavigationTask?.cancel()
        definitionNavigationTask = nil
        if let currentUnknownLanguageURL =
                languagePrompts.currentUnknownFileTypeURL,
           languageSupportService.profileRegistry.resolve(
               url: currentUnknownLanguageURL
           ) != nil {
            finishUnknownLanguagePrompt(suppressForSession: false)
        }
    }

    /// `LanguageSupportService.refresh()` discovered that `languageKey`'s
    /// executable is now available, so retry the affected service.
    private func handleLanguageServerExecutableDiscovered(
        languageKey: String
    ) {
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
        case .expandDirectory(let entry):
            loadExplorerDirectory(relativePath: entry.relativePath)
        }
    }

    private func handleTrustIntent(_ intent: WorkspaceTrustPresenter.Intent) {
        switch intent {
        case .grantTrust:
            trustWorkspace(nil)
        case .revokeTrust:
            revokeTrust(nil)
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
        sidebarItem.minimumThickness = WorkspaceGeometryController.minimumSidebarWidth
        sidebarItem.maximumThickness = WorkspaceGeometryController.maximumSidebarWidth
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

        let contentTopWithBannerConstraint = splitContainer.view.topAnchor.constraint(
            equalTo: workspaceBannerStack.bottomAnchor,
            constant: 8
        )
        let contentTopWithoutBannerConstraint = splitContainer.view.topAnchor.constraint(
            equalTo: editorContainer.safeAreaLayoutGuide.topAnchor
        )
        self.contentTopWithBannerConstraint = contentTopWithBannerConstraint
        self.contentTopWithoutBannerConstraint = contentTopWithoutBannerConstraint

        NSLayoutConstraint.activate([
            workspaceBannerStack.topAnchor.constraint(
                equalTo: editorContainer.safeAreaLayoutGuide.topAnchor,
                constant: 8
            ),
            workspaceBannerStack.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor, constant: 8),
            workspaceBannerStack.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor, constant: -8),
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
            statusBar.heightAnchor.constraint(equalToConstant: 30),
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
        refreshSourceControlSidebar()
        reloadVisibleExplorerDecorations()
        refreshVisibleQuickDiff(snapshot: snapshot)
        quickDiff.refreshSelection(snapshot: snapshot)
        refreshLanguageServerStateUI()
    }

    private func refreshSourceControlSidebar() {
        switch gitCoordinator.repositoryState {
        case .loading:
            sourceControlSidebarController.showLoading()
        case .noRepository:
            sourceControlSidebarController.update(snapshot: nil)
        case .available(_, let status):
            sourceControlSidebarController.update(
                snapshot: status,
                presentationIndex: gitCoordinator.presentationIndex
            )
        case .unavailable(_, let reason):
            sourceControlSidebarController.showUnavailable(reason: reason)
        }
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
        cancelHover()
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

    @objc
    func showExplorer(_ sender: Any?) {
        selectSidebarSurface(.explorer, focus: true)
    }

    @objc
    func searchWorkspace(_ sender: Any?) {
        selectSidebarSurface(.search, focus: true)
    }

    @objc
    func showSourceControl(_ sender: Any?) {
        selectSidebarSurface(.sourceControl, focus: true)
    }

    @objc
    func showProblems(_ sender: Any?) {
        selectSidebarSurface(.problems, focus: true)
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

    private func enqueueUnknownFileType(for url: URL) {
        guard trustStore.isTrusted(identity),
              languagePrompts.enqueueUnknownFileType(url: url) else {
            return
        }
        presentNextUnknownFileTypeIfNeeded()
    }

    private func presentNextUnknownFileTypeIfNeeded() {
        guard languagePrompts.beginPreparing() else {
            return
        }
        defer { languagePrompts.endPreparing() }

        while trustStore.isTrusted(identity) {
            guard let url = languagePrompts.dequeueUnknownFileTypeCandidate() else {
                break
            }
            guard languageSupportService.profileRegistry.resolve(url: url) == nil else {
                continue
            }
            languagePrompts.activateUnknownFileType(url)
            renderUnknownFileTypePrompt(url: url)
            return
        }
    }

    private func renderUnknownFileTypePrompt(url: URL) {
        languageSupportRequestButton.toolTip = Localized.string(
            "Request support for this file type on GitHub.",
            comment: "Tooltip for requesting support for an unknown file type"
        )
        languageSupportBannerLabel.stringValue = Localized.string(
            "No language profile matches *.\(url.pathExtension.lowercased()). Plain Text remains available.",
            comment: "Unknown file type banner message"
        )
        languageSupportBannerLabel.toolTip =
            languageSupportBannerLabel.stringValue
        languageSupportBanner.setAccessibilityLabel(
            languageSupportBannerLabel.stringValue
        )
        languageSupportBanner.isHidden = false
        updateWorkspaceBannerVisibility()
    }

    private func finishUnknownLanguagePrompt(
        suppressForSession: Bool
    ) {
        languagePrompts.finishCurrent(suppressForSession: suppressForSession)
        languageSupportBanner.isHidden = true
        updateWorkspaceBannerVisibility()
        presentNextUnknownFileTypeIfNeeded()
    }

    @objc
    private func dismissUnknownLanguagePrompt(_ sender: Any?) {
        finishUnknownLanguagePrompt(suppressForSession: true)
    }

    @objc
    private func requestUnknownLanguageSupport(_ sender: Any?) {
        guard let url = languagePrompts.currentUnknownFileTypeURL else {
            return
        }
        NSWorkspace.shared.open(languageRequestURL(for: url))
        finishUnknownLanguagePrompt(suppressForSession: true)
    }

    private func languageRequestURL(for fileURL: URL) -> URL {
        var components = URLComponents(
            string: "https://github.com/friggeri/kod/issues/new"
        )
        let fileType = fileURL.pathExtension.isEmpty
            ? fileURL.lastPathComponent
            : ".\(fileURL.pathExtension.lowercased())"
        components?.queryItems = [
            URLQueryItem(
                name: "title",
                value: "Language support: \(fileType)"
            )
        ]
        guard let url = components?.url else {
            preconditionFailure("The language request URL is invalid")
        }
        return url
    }

    private func languageServerStateDidChange() {
        let statuses = multiLanguageServicesCoordinator.states
        let currentIdentifiers = Set(
            statuses.map(\.profile.identifier)
        )
        let removedIdentifiers = lastLanguageServerStates.keys.filter {
            !currentIdentifiers.contains($0)
        }
        for identifier in removedIdentifiers {
            invalidateLanguageProvider(identifier)
            lastLanguageServerStates.removeValue(forKey: identifier)
        }
        for status in statuses {
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
            invalidateLanguageProvider(providerIdentifier)
        case .indexing, .ready, .busy:
            break
        }
    }

    private func invalidateLanguageProvider(_ providerIdentifier: String) {
        languageHoverController.invalidateCache(
            forProvider: providerIdentifier
        )
        definitionNavigationTask?.cancel()
        definitionNavigationTask = nil
    }

    private func refreshLanguageServerStateUI() {
        observeActiveStatusSelection()
        statusBarView?.update(makeStatusBarModel())
    }

    private func observeActiveStatusSelection() {
        let viewport = activeGroupController?
            .currentStatusDocument?
            .cursorDocument?
            .viewport
        guard statusSelectionViewport !== viewport else {
            return
        }
        statusSelectionViewport?.onSelectionStateChange = nil
        statusSelectionViewport = viewport
        viewport?.onSelectionStateChange = { [weak self, weak viewport] _ in
            guard let self,
                  let viewport,
                  self.activeGroupController?
                    .currentStatusDocument?
                    .cursorDocument?
                    .viewport === viewport else {
                return
            }
            self.statusBarView?.update(self.makeStatusBarModel())
        }
    }

    private func makeStatusBarModel() -> WorkspaceStatusBarView.Model {
        let statusDocument = activeGroupController?.currentStatusDocument
        let fileURL = statusDocument.map {
            activeStatusFileURL(for: $0)
        }
        let languageStatus = fileURL.flatMap {
            multiLanguageServicesCoordinator.status(forURL: $0)
        }
        let languageServerStatus: WorkspaceStatusBarView.LanguageServerStatus?
        if let languageStatus {
            languageServerStatus = WorkspaceStatusBarView.languageServerStatus(
                profileIdentifier: languageStatus.profileIdentifier,
                profileName: languageStatus.languageName,
                state: languageStatus.state
            )
        } else if statusDocument != nil {
            let message = Localized.string(
                "No language server configured",
                comment: "Language server status shown when the active file has no configured server"
            )
            let profileIdentifier = fileURL.flatMap {
                languageSupportService.profileRegistry.resolve(url: $0)?
                    .profile.identifier
            }
            languageServerStatus =
                WorkspaceStatusBarView.unavailableLanguageServerStatus(
                    message,
                    settingsProfileIdentifier: profileIdentifier
                )
        } else {
            languageServerStatus = nil
        }

        let metadataDocument = statusDocument?.metadataDocument
        let metadataSnapshot = metadataDocument?.snapshot
        let languageName = languageStatus?.languageName
            ?? metadataDocument?.viewport.language?.displayName
            ?? statusDocument.flatMap {
                fallbackLanguageName(forRelativePath: $0.relativePath)
            }
        let gitItems = WorkspaceStatusBarView.gitItems(
            for: gitCoordinator.repositoryState
        )
        return WorkspaceStatusBarView.Model(
            branch: gitItems.branch,
            git: gitItems.git,
            languageServer: languageServerStatus,
            language: languageName.map(
                WorkspaceStatusBarView.languageItem
            ),
            encoding: metadataSnapshot.map {
                WorkspaceStatusBarView.encodingItem($0.encoding)
            },
            lineEnding: metadataSnapshot.map {
                WorkspaceStatusBarView.lineEndingItem($0.lineEnding)
            },
            cursor: statusDocument?.cursorDocument.flatMap {
                WorkspaceStatusBarView.cursorItem(
                    snapshot: $0.snapshot,
                    selectionState: $0.viewport.selectionState
                )
            }
        )
    }

    private func activeStatusFileURL(
        for statusDocument: EditorStatusDocument
    ) -> URL {
        statusDocument.metadataDocument?.snapshot.url
            ?? identity.root.appendingPathComponent(
                statusDocument.relativePath
            )
    }

    private func fallbackLanguageName(
        forRelativePath relativePath: String
    ) -> String? {
        let pathExtension = URL(
            fileURLWithPath: relativePath
        ).pathExtension.lowercased()
        if let language = SyntaxLanguage.allCases.first(where: {
            $0.fileExtensions.contains(pathExtension)
        }) {
            return language.displayName
        }
        if ["png", "jpg", "jpeg", "gif", "webp", "svg"].contains(
            pathExtension
        ) {
            return Localized.string(
                "Image",
                comment: "Active-file language label for an image preview"
            )
        }
        guard !pathExtension.isEmpty else {
            return nil
        }
        return pathExtension.uppercased()
    }

    @objc
    private func restartLanguageServer(_ sender: Any?) {
        guard let statusDocument = activeGroupController?.currentStatusDocument else {
            return
        }
        let url = activeStatusFileURL(for: statusDocument)
        languageHoverController.invalidateCache(
            forProvider: languageProviderIdentifier(for: url)
        )
        multiLanguageServicesCoordinator.restart(forURL: url)
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
            self?.languageHoverController.hoverExited(for: controller)
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
                // file simply does not navigate; the Problems list itself
                // is unaffected.
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

        session.startFilenameIndexing()
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
        splitContainer?.controller(for: layoutState.activeGroupID)
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
        refreshLanguageServerStateUI()
        revealActiveFileInExplorer()
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
        controller.loadPreviewResourceData = { [weak self] relativePath in
            guard let self,
                  let confinedPath = WorkspaceLocalLinkResolver.relativePath(
                    for: relativePath,
                    root: self.identity.root
                  ) else {
                throw CocoaError(.fileReadNoPermission)
            }
            return try await self.loadRawFileData(
                relativePath: confinedPath
            )
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
            guard let relativePath = WorkspaceLocalLinkResolver.relativePath(
                for: relativePath,
                root: self.identity.root
            ) else {
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
            if self.layoutState.activeGroupID == groupID {
                self.revealActiveFileInExplorer()
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
            guard let self, self.layoutState.activeGroupID == id else {
                return
            }
            self.cancelHover()
            self.refreshLanguageServerStateUI()
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
        explorerRevealTask?.cancel()
        explorerRevealTask = nil
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

    /// Reads a workspace-relative path's raw bytes independently of
    /// `SourceSnapshot` text decoding, for image and binary-plist previews.
    private func loadRawFileData(relativePath: String) async throws -> Data {
        let url = identity.root.appendingPathComponent(relativePath)
        return try await Task.detached(priority: .userInitiated) {
            try LocalReadOnlyFileSystem().readFile(at: url).data
        }.value
    }

    /// Attempts to build a preview directly from raw bytes after source
    /// decoding failed. Only formats with a meaningful preview-only mode
    /// (images and structured data such as binary plists) are admitted.
    private func tryMakePreviewOnly(forRelativePath relativePath: String) async -> PreviewViewController? {
        guard let data = try? await loadRawFileData(relativePath: relativePath) else {
            return nil
        }
        let kind = PreviewContentDetector.detect(
            pathExtension: (relativePath as NSString).pathExtension,
            contentPrefix: data.prefix(4_096)
        )
        switch kind {
        case .image, .structuredData:
            break
        case .markdown, .html, .none:
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
        workspaceBannerStack.addArrangedSubview(languageSupportBanner)
        workspaceBannerStack.addArrangedSubview(workspaceHealthPresenter.view)
        workspaceHealthPresenter.update(session.health)
        workspaceBannerStack.isHidden = true
    }


    private func configureLanguageSupportBanner() {
        languageSupportBanner.identifier = NSUserInterfaceItemIdentifier(
            "workspace.unknownLanguageBanner"
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
                    "Unknown file type",
                    comment: "Accessibility description for the icon in the unknown-file-type prompt"
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

        let buttons = [languageSupportRequestButton, languageSupportNotNowButton]
        for button in buttons {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.target = self
        }
        languageSupportRequestButton.identifier = NSUserInterfaceItemIdentifier(
            "workspace.unknownLanguage.request"
        )
        languageSupportRequestButton.action = #selector(
            requestUnknownLanguageSupport(_:)
        )
        languageSupportNotNowButton.identifier = NSUserInterfaceItemIdentifier(
            "workspace.unknownLanguage.notNow"
        )
        languageSupportNotNowButton.action = #selector(
            dismissUnknownLanguagePrompt(_:)
        )

        languageSupportBanner.addArrangedSubview(icon)
        languageSupportBanner.addArrangedSubview(languageSupportBannerLabel)
        for button in buttons {
            languageSupportBanner.addArrangedSubview(button)
        }
    }

    /// Re-renders the status control from the store's current, live state.
    private func refreshWorkspaceTrustUI() {
        trustPresenter.render(isTrusted: trustStore.isTrusted(identity))
        refreshLanguageServerStateUI()
    }

    private func updateWorkspaceBannerVisibility() {
        let isVisible = !languageSupportBanner.isHidden
            || !workspaceHealthPresenter.view.isHidden
        workspaceBannerStack.isHidden = !isVisible
        contentTopWithBannerConstraint?.isActive = isVisible
        contentTopWithoutBannerConstraint?.isActive = !isVisible
    }

    private func workspaceHealthDidChange(_ health: WorkspaceHealth) {
        workspaceHealthPresenter.update(health)
        updateWorkspaceBannerVisibility()
    }

    private func makeSidebar() -> NSView {
        let container = NSView()
        container.identifier = NSUserInterfaceItemIdentifier("workspace.sidebar")

        let activityBar = WorkspaceActivityBarView()
        activityBarView = activityBar
        activityBar.onSelectSurface = { [weak self] surface in
            self?.selectSidebarSurface(surface, focus: true)
        }

        let content = NSView()
        content.identifier = NSUserInterfaceItemIdentifier("workspace.sidebarContent")
        content.translatesAutoresizingMaskIntoConstraints = false

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
        refreshSourceControlSidebar()

        container.addSubview(activityBar)
        container.addSubview(content)
        content.addSubview(explorerContainer)
        content.addSubview(searchController.view)
        content.addSubview(problemsController.view)
        content.addSubview(sourceControlController.view)
        NSLayoutConstraint.activate([
            activityBar.topAnchor.constraint(
                equalTo: container.safeAreaLayoutGuide.topAnchor
            ),
            activityBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            activityBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: activityBar.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        for surfaceView in [
            explorerContainer,
            searchController.view,
            problemsController.view,
            sourceControlController.view
        ].compactMap({ $0 }) {
            NSLayoutConstraint.activate([
                surfaceView.topAnchor.constraint(
                    equalTo: content.safeAreaLayoutGuide.topAnchor
                ),
                surfaceView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                surfaceView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                surfaceView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
            ])
        }
        selectSidebarSurface(layoutState.sidebarSurface, focus: false)
        return container
    }

    private func makeStatusBar() -> NSView {
        let statusBar = WorkspaceStatusBarView(
            trustControl: trustPresenter.statusButton
        )
        statusBar.onShowSourceControl = { [weak self] in
            self?.selectSidebarSurface(.sourceControl, focus: true)
        }
        statusBar.onShowLanguageSupportSettings = { [weak self] profileIdentifier in
            self?.onShowLanguageSupportSettings?(profileIdentifier)
        }
        statusBarView = statusBar
        statusBar.update(makeStatusBarModel())
        return statusBar
    }

    func selectSidebarSurface(
        _ surface: WorkspaceSidebarSurface,
        focus: Bool
    ) {
        geometry.revealSidebar(nil)
        let didChange = layoutState.sidebarSurface != surface
        layoutState.sidebarSurface = surface
        activityBarView?.setSelectedSurface(surface)
        explorerContainer?.isHidden = surface != .explorer
        searchSidebarController?.view.isHidden = surface != .search
        problemsViewController?.view.isHidden = surface != .problems
        sourceControlSidebarController?.view.isHidden = surface != .sourceControl

        switch surface {
        case .explorer:
            refreshGitDecorationAppearance()
        case .search:
            break
        case .sourceControl:
            sourceControlSidebarController.refreshAppearance()
        case .problems:
            break
        }

        activityBarView?.setNextKeyViewAfterBar(primaryFocusView(for: surface))
        if didChange {
            persistLayout()
        }
        guard focus else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.layoutState.sidebarSurface == surface else {
                return
            }
            self.focusPrimaryControl(for: surface)
        }
    }

    private func primaryFocusView(
        for surface: WorkspaceSidebarSurface
    ) -> NSView? {
        switch surface {
        case .explorer:
            explorer.primaryFocusView
        case .search:
            searchSidebarController?.primaryFocusView
        case .sourceControl:
            sourceControlSidebarController?.primaryFocusView
        case .problems:
            problemsViewController?.primaryFocusView
        }
    }

    private func focusPrimaryControl(for surface: WorkspaceSidebarSurface) {
        switch surface {
        case .explorer:
            explorer.focusPrimaryControl()
        case .search:
            searchSidebarController.focusSearchField()
        case .sourceControl:
            sourceControlSidebarController.focusPrimaryControl()
        case .problems:
            problemsViewController.focusPrimaryControl()
        }
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

    private func loadExplorerDirectory(relativePath: String) {
        session.runTracked(.discovery) { [weak self] in
            guard let self else {
                return
            }
            do {
                let entries = try await self.session.loadDirectory(
                    relativePath: relativePath
                )
                try Task.checkCancellation()
                self.explorer.applyDirectory(
                    entries,
                    relativePath: relativePath
                )
            } catch is CancellationError {
                return
            } catch {
                self.explorer.directoryLoadFailed(relativePath: relativePath)
                self.session.recordHealthIssue(
                    .discovery,
                    severity: .degraded,
                    message: Localized.string(
                        "An Explorer directory could not be loaded",
                        comment: "Workspace health summary for a lazy Explorer directory load failure"
                    ),
                    reason: error.localizedDescription
                )
            }
        }
    }

    private func revealActiveFileInExplorer() {
        guard isViewLoaded,
              splitContainer != nil,
              let relativePath = activeGroupController?.currentTabRelativePath else {
            return
        }
        explorerRevealTask?.cancel()
        explorerRevealTask = session.runTracked(.discovery) { [weak self] in
            guard let self else {
                return
            }
            await self.revealInExplorer(relativePath: relativePath)
        }
    }

    private func revealInExplorer(relativePath: String) async {
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty else {
            return
        }

        var directoriesToLoad = [""]
        var currentPath = ""
        for component in components.dropLast() {
            currentPath = currentPath.isEmpty
                ? component
                : "\(currentPath)/\(component)"
            directoriesToLoad.append(currentPath)
        }

        do {
            for directoryPath in directoriesToLoad
            where !explorer.isDirectoryLoaded(directoryPath) {
                let entries = try await session.loadDirectory(
                    relativePath: directoryPath
                )
                try Task.checkCancellation()
                explorer.applyDirectory(
                    entries,
                    relativePath: directoryPath
                )
            }
        } catch is CancellationError {
            return
        } catch {
            session.recordHealthIssue(
                .discovery,
                severity: .degraded,
                message: Localized.string(
                    "The active file could not be revealed in Explorer",
                    comment: "Workspace health summary for an active-file Explorer reveal failure"
                ),
                reason: error.localizedDescription
            )
            return
        }

        guard activeGroupController?.currentTabRelativePath == relativePath else {
            return
        }
        _ = explorer.reveal(relativePath: relativePath)
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
        if case .completed = status {
            revealActiveFileInExplorer()
        }
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
                // its raw bytes and showing a supported preview-only format
                // instead of an error alert.
                if let preview = await self.tryMakePreviewOnly(forRelativePath: entry.relativePath) {
                    groupController.openPreviewOnlyTab(
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
