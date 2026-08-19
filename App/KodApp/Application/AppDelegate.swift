import AppKit
import CodeViewport
import DiagnosticsCore
import KodCore
import SourceModel
import SwiftUI
import WorkspaceCore

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var welcomeWindowController: NSWindowController?
    private var settingsWindowController: SettingsWindowController?
    private let environment: AppEnvironment
    let sessionRegistry: AppSessionRegistry
    private var terminationTask: Task<Void, Never>?
    private var terminationReplies: [() -> Void] = []
    private var didFinishTermination = false

    init(
        environment: AppEnvironment,
        sessionRegistry: AppSessionRegistry? = nil
    ) {
        self.environment = environment
        self.sessionRegistry =
            sessionRegistry ?? AppSessionRegistry(environment: environment)
        super.init()
        self.sessionRegistry.onFirstSessionOpened = { [weak self] in
            self?.closeWelcomeWindow()
        }
        self.sessionRegistry.onSessionSetChanged = { [weak self] in
            self?.configureMainMenu()
        }
        self.sessionRegistry.onShowLanguageSupportSettings = {
            [weak self] profileIdentifier in
            self?.presentLanguageSupportSettings(
                profileIdentifier: profileIdentifier
            )
        }
    }

    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let environment: AppEnvironment
        do {
            environment = try .production()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = Localized.string(
                "Kod could not load its settings",
                comment: "Fatal launch error shown when the application settings repository cannot be initialized"
            )
            alert.runModal()
            return
        }
        let delegate = AppDelegate(environment: environment)
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()
        showWelcomeWindow()
        NSApp.activate(ignoringOtherApps: true)

        if let folderURL = commandLineURL(after: "--open-folder") {
            _ = displayWorkspace(at: folderURL)
        } else if let fileURL = commandLineURL(after: "--open-file") {
            Task { @MainActor [weak self] in
                _ = await self?.displayFile(at: fileURL)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        beginTermination {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @discardableResult
    func beginTermination(
        reply: @escaping () -> Void
    ) -> Task<Void, Never> {
        if didFinishTermination {
            reply()
            return Task {}
        }
        terminationReplies.append(reply)
        if terminationTask == nil {
            terminationTask = Task { @MainActor [weak self, sessionRegistry] in
                await sessionRegistry.shutdownAll()
                guard let self else {
                    return
                }
                didFinishTermination = true
                let replies = terminationReplies
                terminationReplies.removeAll()
                replies.forEach { $0() }
            }
        }
        return terminationTask ?? Task {}
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        Task { @MainActor [weak self] in
            guard let self else {
                sender.reply(toOpenOrPrint: .failure)
                return
            }
            let succeeded = await handleOpenFiles(filenames)
            sender.reply(toOpenOrPrint: succeeded ? .success : .failure)
        }
    }

    func handleOpenFiles(_ filenames: [String]) async -> Bool {
        guard !filenames.isEmpty else {
            return false
        }
        var allSucceeded = true
        for filename in filenames {
            let url = URL(fileURLWithPath: filename)
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                let succeeded: Bool
                if values.isDirectory == true {
                    succeeded = displayWorkspace(at: url)
                } else {
                    succeeded = await displayFile(at: url)
                }
                allSucceeded = allSucceeded && succeeded
            } catch {
                allSucceeded = false
            }
        }
        return allSucceeded
    }

    func showWelcomeWindow() {
        let recentRoots = loadRecentWorkspaceRoots()
        let content = WelcomeView(
            buildInfo: .current(),
            recentWorkspace: recentRoots.first,
            onOpenFolder: { [weak self] in
                self?.presentOpenFolderPanel()
            },
            onOpenFile: { [weak self] in
                self?.presentOpenFilePanel()
            },
            onOpenRecent: { [weak self] url in
                self?.displayWorkspace(at: url)
            }
        )
        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hostingController)
        window.identifier = NSUserInterfaceItemIdentifier("welcome.window")
        window.title = Localized.string("Kod", comment: "Title of the Welcome window")
        window.setContentSize(NSSize(width: 720, height: 480))
        window.minSize = NSSize(width: 640, height: 420)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.center()
        window.setFrameAutosaveName("KodWelcomeWindow")

        let windowController = NSWindowController(window: window)
        welcomeWindowController = windowController
        windowController.showWindow(nil)
    }

    private func closeWelcomeWindow() {
        welcomeWindowController?.close()
        welcomeWindowController = nil
    }

    private func configureMainMenu() {
        NSApp.mainMenu = buildMainMenu()
    }

    /// Constructs Kod's complete main-menu tree and returns it, without
    /// touching `NSApp.mainMenu` itself (that assignment is
    /// `configureMainMenu()`'s job). Kept `internal` — not `private` —
    /// so `KeyboardCommandRegistryTests` can build the exact same real
    /// `NSMenu`/`NSMenuItem` tree headlessly (no `NSApp.run()`, no
    /// mouse/keyboard automation) and assert the keyboard-command
    /// registry never drifts from this actual wiring.
    func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        for node in WorkspaceCommandCatalog.shared.mainMenu {
            if let item = buildMenuItem(from: node) {
                mainMenu.addItem(item)
            }
        }
        return mainMenu
    }

    private func buildMenuItem(from node: MenuNode) -> NSMenuItem? {
        switch node {
        case .command(let id):
            guard let metadata = WorkspaceCommandCatalog.shared.metadata(for: id) else { return nil }
            let item = NSMenuItem(
                title: metadata.menuTitle,
                action: metadata.action,
                keyEquivalent: metadata.keyEquivalent
            )
            item.keyEquivalentModifierMask = metadata.modifierMask
            if metadata.target == .appDelegate {
                item.target = self
            }
            return item

        case .separator:
            return .separator()

        case .submenu(let title, let children):
            let root = NSMenuItem()
            let menu = NSMenu(title: title)
            root.submenu = menu
            for child in children {
                if let childItem = buildMenuItem(from: child) {
                    menu.addItem(childItem)
                }
            }
            if title == Localized.string("Window", comment: "Title of the Window menu") {
                NSApp.windowsMenu = menu
            } else if title == Localized.string("Help", comment: "Title of the Help menu") {
                NSApp.helpMenu = menu
            }
            return root

        case .applicationServices:
            let services = NSMenuItem(
                title: Localized.string("Services", comment: "Application menu item exposing the system Services submenu"),
                action: nil,
                keyEquivalent: ""
            )
            services.submenu = NSMenu(title: Localized.string("Services", comment: "Title of the Services submenu"))
            NSApp.servicesMenu = services.submenu
            return services

        case .openRecent:
            let openRecent = NSMenuItem(
                title: Localized.string("Open Recent", comment: "File menu item exposing the recently opened workspaces submenu"),
                action: nil,
                keyEquivalent: ""
            )
            let recentMenu = NSMenu(title: Localized.string("Open Recent", comment: "Title of the Open Recent submenu"))
            let recentRoots = loadRecentWorkspaceRoots()
            for rootPath in recentRoots {
                let item = NSMenuItem(
                    title: rootPath.lastPathComponent,
                    action: #selector(openRecentWorkspace(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = rootPath.path
                item.toolTip = rootPath.path
                recentMenu.addItem(item)
            }
            openRecent.submenu = recentMenu
            openRecent.isEnabled = !recentRoots.isEmpty
            return openRecent
        }
    }

    @objc
    func presentOpenFilePanel(_ sender: Any? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }
            Task { @MainActor [weak self] in
                _ = await self?.displayFile(at: url)
            }
        }
    }

    @objc
    func presentOpenFolderPanel(_ sender: Any? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }
            Task { @MainActor [weak self] in
                _ = self?.displayWorkspace(at: url)
            }
        }
    }

    @objc
    func openRecentWorkspace(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else {
            return
        }
        _ = displayWorkspace(
            at: URL(fileURLWithPath: path, isDirectory: true)
        )
    }

    @objc
    func showSettings(_ sender: Any? = nil) {
        _ = presentSettings()
    }

    @objc
    func showLanguageSupportSettings(_ sender: Any? = nil) {
        presentLanguageSupportSettings(profileIdentifier: nil)
    }

    private func presentLanguageSupportSettings(
        profileIdentifier: String?
    ) {
        guard let controller = presentSettings() else {
            return
        }
        controller.showLanguageSupport(
            profileIdentifier: profileIdentifier
        )
    }

    @discardableResult
    private func presentSettings() -> SettingsWindowController? {
        do {
            let controller: SettingsWindowController
            if let settingsWindowController {
                controller = settingsWindowController
            } else {
                controller = try SettingsWindowController(
                    environment: environment
                )
                settingsWindowController = controller
            }
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return controller
        } catch {
            present(error)
            return nil
        }
    }

    @discardableResult
    func displayWorkspace(at url: URL) -> Bool {
        let identity: WorkspaceIdentity
        do {
            identity = try WorkspaceIdentity(root: url)
        } catch {
            present(error)
            return false
        }
        guard sessionRegistry.openWorkspace(identity) else {
            return false
        }
        do {
            try environment.recentWorkspaceStore.record(identity.root)
        } catch {
            recordSettingsFailure(
                message: "Recent workspace history could not be saved",
                error: error
            )
        }
        configureMainMenu()
        return true
    }

    private func loadRecentWorkspaceRoots() -> [URL] {
        do {
            switch try environment.recentWorkspaceStore.roots() {
            case .value(let roots, _):
                return roots
            case .absent:
                return []
            case .quarantined(let record):
                recordSettingsFailure(
                    message: "Recent workspace history was reset",
                    reason: record.reason
                )
                return []
            }
        } catch {
            recordSettingsFailure(
                message: "Recent workspace history could not be loaded",
                error: error
            )
            return []
        }
    }

    private func recordSettingsFailure(
        message: String,
        error: any Error
    ) {
        recordSettingsFailure(
            message: message,
            reason: String(describing: error)
        )
    }

    private func recordSettingsFailure(
        message: String,
        reason: String
    ) {
        Task {
            await environment.diagnosticsLog.record(
                subsystem: .app,
                level: .error,
                message: message,
                context: [
                    DiagnosticContextField(
                        name: "reason",
                        category: .diagnosticMessage,
                        value: reason
                    )
                ]
            )
        }
    }

    private func present(_ error: any Error) {
        let alert = NSAlert(error: error)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @discardableResult
    func displayFile(at url: URL) async -> Bool {
        await sessionRegistry.openDocument(at: url)
    }

    func persistCurrentWorkspaceState(in window: NSWindow? = nil) {
        let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow
        (window?.contentViewController as? WorkspaceViewController)?
            .persistRestorableState()
    }

    private func commandLineURL(after flag: String) -> URL? {
        let arguments = CommandLine.arguments
        guard let flagIndex = arguments.firstIndex(of: flag) else {
            return nil
        }
        let pathIndex = arguments.index(after: flagIndex)
        guard arguments.indices.contains(pathIndex) else {
            return nil
        }
        return URL(fileURLWithPath: arguments[pathIndex])
    }
}
