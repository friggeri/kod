import AppKit
import WorkspaceCore

@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate {
    struct Services {
        var makeWindow: @MainActor (NSViewController) -> NSWindow
        var present: @MainActor (NSWindowController) -> Void
        var focus: @MainActor (NSWindow) -> Void
        var activate: @MainActor () -> Void
        var beginSession: @MainActor (WorkspaceSession) -> Void
        var shutdownSession: @MainActor (WorkspaceSession) async -> Void

        static let production = Services(
            makeWindow: { contentViewController in
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 720),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                window.contentViewController = contentViewController
                window.minSize = NSSize(width: 640, height: 420)
                window.center()
                return window
            },
            present: { $0.showWindow(nil) },
            focus: { $0.makeKeyAndOrderFront(nil) },
            activate: { NSApp.activate(ignoringOtherApps: true) },
            beginSession: { _ = $0.begin() },
            shutdownSession: { await $0.shutdown() }
        )
    }

    let identity: WorkspaceIdentity
    let session: WorkspaceSession
    let workspaceViewController: WorkspaceViewController
    var onWindowWillClose: ((WorkspaceWindowController) -> Void)?

    private let services: Services
    private var toolbarDelegate: WorkspaceToolbarDelegate?
    private var hasPresented = false
    private var hasPreparedForClose = false
    private var shutdownTask: Task<Void, Never>?

    init(
        identity: WorkspaceIdentity,
        session: WorkspaceSession,
        workspaceViewController: WorkspaceViewController? = nil,
        services: Services = .production
    ) {
        self.identity = identity
        self.session = session
        self.workspaceViewController =
            workspaceViewController ?? WorkspaceViewController(session: session)
        self.services = services
        let window = services.makeWindow(self.workspaceViewController)
        super.init(window: window)
        window.identifier = NSUserInterfaceItemIdentifier(
            "workspace.window.\(identity.persistenceKey)"
        )
        window.title = identity.root.lastPathComponent
        window.isReleasedWhenClosed = false
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func showSessionWindow() {
        guard let window else {
            return
        }
        if hasPresented {
            focusSessionWindow()
            return
        }
        hasPresented = true
        _ = workspaceViewController.view
        configureWindowChrome(window)
        window.delegate = self
        services.present(self)
        window.layoutIfNeeded()
        workspaceViewController.restoreWorkspaceGeometryIfNeeded()
        services.beginSession(session)
        services.activate()
    }

    func focusSessionWindow() {
        guard let window else {
            return
        }
        services.focus(window)
        services.activate()
    }

    func closeSessionWindow() {
        window?.close()
    }

    func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        prepareForClose()
        let task = Task { @MainActor [services, session] in
            await services.shutdownSession(session)
        }
        shutdownTask = task
        await task.value
    }

    func windowWillClose(_ notification: Notification) {
        prepareForClose()
        onWindowWillClose?(self)
    }

    /// Fullscreen transitions are pure window geometry: they go straight
    /// to the geometry controller, which owns the "last normal frame"
    /// bookkeeping that decides what gets persisted.
    func windowWillEnterFullScreen(_ notification: Notification) {
        workspaceViewController.geometry.windowWillEnterFullScreen(notification)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        workspaceViewController.geometry.windowDidExitFullScreen(notification)
    }

    private func prepareForClose() {
        guard !hasPreparedForClose else {
            return
        }
        hasPreparedForClose = true
        workspaceViewController.prepareForWindowClose()
    }

    private func configureWindowChrome(_ window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.title = identity.root.lastPathComponent
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified

        let delegate = WorkspaceToolbarDelegate(
            target: workspaceViewController
        )
        let toolbar = NSToolbar(
            identifier: NSToolbar.Identifier("workspace.toolbar")
        )
        toolbar.delegate = delegate
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbarDelegate = delegate
        window.toolbar = toolbar
        window.layoutIfNeeded()
    }
}
