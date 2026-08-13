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
    private var welcomeWindowController: NSWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var sourceLoadTask: Task<Void, Never>?
    private let recentWorkspaceStore = RecentWorkspaceStore()
    /// One shared, app-lifetime bounded diagnostics log (SPEC 15):
    /// every workspace window and the Settings/Diagnostics tab all
    /// record into and read from this same instance, so a support
    /// bundle exported from Settings reflects events from every
    /// workspace opened during this run, not just whichever one is
    /// currently frontmost.
    private let diagnosticsLog = BoundedEventLog()
    private let languageSupportService = LanguageSupportService()

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()
        showWelcomeWindow()
        NSApp.activate(ignoringOtherApps: true)

        if let folderURL = commandLineURL(after: "--open-folder") {
            displayWorkspace(at: folderURL)
        } else if let fileURL = commandLineURL(after: "--open-file") {
            displayFile(at: fileURL)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        persistCurrentWorkspaceState()
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard let filename = filenames.first else {
            sender.reply(toOpenOrPrint: .failure)
            return
        }

        let url = URL(fileURLWithPath: filename)
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                displayWorkspace(at: url)
            } else {
                displayFile(at: url)
            }
            sender.reply(toOpenOrPrint: .success)
        } catch {
            sender.reply(toOpenOrPrint: .failure)
        }
    }

    private func showWelcomeWindow() {
        let content = WelcomeView(
            buildInfo: .current(),
            recentWorkspace: recentWorkspaceStore.roots.first,
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
        mainMenu.addItem(applicationMenuItem())
        mainMenu.addItem(fileMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(viewMenuItem())
        mainMenu.addItem(navigateMenuItem())
        mainMenu.addItem(windowMenuItem())
        mainMenu.addItem(helpMenuItem())
        return mainMenu
    }

    private func applicationMenuItem() -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: Localized.string("Kod", comment: "Title of the application (Kod) main menu"))
        root.submenu = menu

        menu.addItem(
            withTitle: Localized.string("About Kod", comment: "Application menu item that shows the standard About panel"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: Localized.string("Settings...", comment: "Application menu item that opens the Settings window"),
            action: #selector(showSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let services = NSMenuItem(
            title: Localized.string("Services", comment: "Application menu item exposing the system Services submenu"),
            action: nil,
            keyEquivalent: ""
        )
        services.submenu = NSMenu(title: Localized.string("Services", comment: "Title of the Services submenu"))
        menu.addItem(services)
        NSApp.servicesMenu = services.submenu

        menu.addItem(.separator())
        menu.addItem(
            withTitle: Localized.string("Hide Kod", comment: "Application menu item that hides the app"),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )

        let hideOthers = NSMenuItem(
            title: Localized.string("Hide Others", comment: "Application menu item that hides all other apps"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)

        menu.addItem(
            withTitle: Localized.string("Show All", comment: "Application menu item that unhides all apps"),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: Localized.string("Quit Kod", comment: "Application menu item that quits the app"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        return root
    }

    private func fileMenuItem() -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: Localized.string("File", comment: "Title of the File menu"))
        root.submenu = menu

        let openFolder = NSMenuItem(
            title: Localized.string("Open Folder...", comment: "File menu item that opens a folder-selection panel"),
            action: #selector(presentOpenFolderPanel(_:)),
            keyEquivalent: "o"
        )
        openFolder.target = self
        menu.addItem(openFolder)

        let openFile = NSMenuItem(
            title: Localized.string("Open File...", comment: "File menu item that opens a file-selection panel"),
            action: #selector(presentOpenFilePanel(_:)),
            keyEquivalent: "o"
        )
        openFile.target = self
        openFile.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(openFile)

        let openRecent = NSMenuItem(
            title: Localized.string("Open Recent", comment: "File menu item exposing the recently opened workspaces submenu"),
            action: nil,
            keyEquivalent: ""
        )
        let recentMenu = NSMenu(title: Localized.string("Open Recent", comment: "Title of the Open Recent submenu"))
        for root in recentWorkspaceStore.roots {
            // The item title is the workspace's folder name, not a
            // translatable literal — it is out of scope for migration
            // like any other user-provided file-system name.
            let item = NSMenuItem(
                title: root.lastPathComponent,
                action: #selector(openRecentWorkspace(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = root.path
            item.toolTip = root.path
            recentMenu.addItem(item)
        }
        openRecent.submenu = recentMenu
        openRecent.isEnabled = !recentWorkspaceStore.roots.isEmpty
        menu.addItem(openRecent)

        menu.addItem(.separator())
        menu.addItem(
            withTitle: Localized.string("Quick Open...", comment: "File menu item that opens the Quick Open panel"),
            action: #selector(WorkspaceViewController.showQuickOpen(_:)),
            keyEquivalent: "p"
        )
        menu.addItem(
            withTitle: Localized.string("Go to Line...", comment: "File menu item that opens the Go to Line panel"),
            action: #selector(WorkspaceViewController.showGoToLinePanel(_:)),
            keyEquivalent: "g"
        ).keyEquivalentModifierMask = [.control]
        menu.addItem(
            withTitle: Localized.string("Command Palette...", comment: "File menu item that opens the Command Palette"),
            action: #selector(WorkspaceViewController.showCommandPalette(_:)),
            keyEquivalent: "p"
        ).keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(
            withTitle: Localized.string("Close Tab", comment: "File menu item that closes the active editor tab"),
            action: #selector(WorkspaceViewController.closeActiveTab(_:)),
            keyEquivalent: "w"
        )
        menu.addItem(
            withTitle: Localized.string("Close Window", comment: "File menu item that closes the frontmost window"),
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        ).keyEquivalentModifierMask = [.command, .shift]

        return root
    }

    private func editMenuItem() -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: Localized.string("Edit", comment: "Title of the Edit menu"))
        root.submenu = menu

        menu.addItem(
            withTitle: Localized.string("Copy", comment: "Edit menu item that copies the selection"),
            action: #selector(CodeViewport.copy(_:)),
            keyEquivalent: "c"
        )
        menu.addItem(
            withTitle: Localized.string("Select All", comment: "Edit menu item that selects all content"),
            action: #selector(CodeViewport.selectAll(_:)),
            keyEquivalent: "a"
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: Localized.string("Find in File...", comment: "Edit menu item that opens in-file find"),
            action: #selector(WorkspaceViewController.findInFile(_:)),
            keyEquivalent: "f"
        )
        menu.addItem(
            withTitle: Localized.string("Search Workspace...", comment: "Edit menu item that opens workspace-wide search"),
            action: #selector(WorkspaceViewController.searchWorkspace(_:)),
            keyEquivalent: "f"
        ).keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(
            withTitle: Localized.string("Show Source Control", comment: "Edit menu item that reveals the Source Control sidebar"),
            action: #selector(WorkspaceViewController.showSourceControl(_:)),
            keyEquivalent: "g"
        ).keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(
            withTitle: Localized.string("Show Problems", comment: "Edit menu item that reveals the Problems panel"),
            action: #selector(WorkspaceViewController.showProblems(_:)),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: Localized.string("Show Git Blame", comment: "Edit menu item that shows Git blame for the selected file"),
            action: #selector(WorkspaceViewController.showGitBlameForSelectedFile(_:)),
            keyEquivalent: ""
        )

        return root
    }

    private func viewMenuItem() -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: Localized.string("View", comment: "Title of the View menu"))
        root.submenu = menu

        menu.addItem(
            withTitle: Localized.string("Increase Text Size", comment: "View menu item that increases the editor font size"),
            action: #selector(CodeViewport.increaseFontSize(_:)),
            keyEquivalent: "+"
        )
        menu.addItem(
            withTitle: Localized.string("Decrease Text Size", comment: "View menu item that decreases the editor font size"),
            action: #selector(CodeViewport.decreaseFontSize(_:)),
            keyEquivalent: "-"
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: Localized.string("Word Wrap", comment: "View menu item that toggles word wrap"),
            action: #selector(WorkspaceViewController.toggleWordWrap(_:)),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: Localized.string("Minimap", comment: "View menu item that toggles the source minimap"),
            action: #selector(WorkspaceViewController.toggleMinimap(_:)),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: Localized.string("Toggle Fold", comment: "View menu item that toggles the code fold at the current line"),
            action: #selector(CodeViewport.toggleFoldAtCurrentLine(_:)),
            keyEquivalent: "]"
        ).keyEquivalentModifierMask = [.command, .option]
        menu.addItem(.separator())
        menu.addItem(
            withTitle: Localized.string("Split Editor Right", comment: "View menu item that splits the active editor group to the right"),
            action: #selector(WorkspaceViewController.splitActiveGroupRight(_:)),
            keyEquivalent: "\\"
        )
        menu.addItem(
            withTitle: Localized.string("Split Editor Down", comment: "View menu item that splits the active editor group downward"),
            action: #selector(WorkspaceViewController.splitActiveGroupDown(_:)),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: Localized.string("Close Editor Group", comment: "View menu item that closes the active editor group"),
            action: #selector(WorkspaceViewController.closeActiveGroup(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: Localized.string("Toggle Source and Preview", comment: "View menu item that toggles between source and rendered preview"),
            action: #selector(WorkspaceViewController.togglePreviewSource(_:)),
            keyEquivalent: "\r"
        ).keyEquivalentModifierMask = [.command]

        return root
    }

    /// `NSLeftArrowFunctionKey`/`NSRightArrowFunctionKey` and friends are
    /// fixed AppKit `unichar` constants in the private-use area, always a
    /// valid `UnicodeScalar` — but this still avoids a literal force
    /// unwrap at each call site by centralizing the (infallible-in-
    /// practice) conversion in one place with an explicit, documented
    /// fallback rather than crashing if that assumption were ever wrong.
    private static func functionKeyEquivalent(_ key: Int) -> String {
        guard let scalar = UnicodeScalar(key) else {
            return ""
        }
        return String(scalar)
    }

    private func navigateMenuItem() -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: Localized.string("Navigate", comment: "Title of the Navigate menu"))
        root.submenu = menu

        let back = NSMenuItem(
            title: Localized.string("Back", comment: "Navigate menu item that goes back in navigation history"),
            action: #selector(WorkspaceViewController.navigateBack(_:)),
            keyEquivalent: Self.functionKeyEquivalent(NSLeftArrowFunctionKey)
        )
        back.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(back)

        let forward = NSMenuItem(
            title: Localized.string("Forward", comment: "Navigate menu item that goes forward in navigation history"),
            action: #selector(WorkspaceViewController.navigateForward(_:)),
            keyEquivalent: Self.functionKeyEquivalent(NSRightArrowFunctionKey)
        )
        forward.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(forward)

        menu.addItem(.separator())
        let goToDefinition = NSMenuItem(
            title: Localized.string("Go to Definition", comment: "Navigate menu item that opens the selected symbol's definition"),
            action: #selector(WorkspaceViewController.goToDefinition(_:)),
            keyEquivalent: Self.functionKeyEquivalent(NSF12FunctionKey)
        )
        goToDefinition.keyEquivalentModifierMask = []
        menu.addItem(goToDefinition)
        menu.addItem(
            withTitle: Localized.string("Go to Matching Bracket", comment: "Navigate menu item that jumps to the matching bracket"),
            action: #selector(CodeViewport.jumpToMatchingBracket(_:)),
            keyEquivalent: "m"
        ).keyEquivalentModifierMask = [.command, .control]
        menu.addItem(.separator())
        let previousChange = NSMenuItem(
            title: Localized.string("Previous Git Change", comment: "Navigate menu item that opens the previous inline Git change"),
            action: #selector(WorkspaceViewController.showPreviousGitChange(_:)),
            keyEquivalent: Self.functionKeyEquivalent(NSF3FunctionKey)
        )
        previousChange.keyEquivalentModifierMask = [.option, .shift]
        menu.addItem(previousChange)
        let nextChange = NSMenuItem(
            title: Localized.string("Next Git Change", comment: "Navigate menu item that opens the next inline Git change"),
            action: #selector(WorkspaceViewController.showNextGitChange(_:)),
            keyEquivalent: Self.functionKeyEquivalent(NSF3FunctionKey)
        )
        nextChange.keyEquivalentModifierMask = [.option]
        menu.addItem(nextChange)

        return root
    }


    private func windowMenuItem() -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: Localized.string("Window", comment: "Title of the Window menu"))
        root.submenu = menu
        NSApp.windowsMenu = menu

        menu.addItem(
            withTitle: Localized.string("Minimize", comment: "Window menu item that minimizes the frontmost window"),
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        menu.addItem(
            withTitle: Localized.string("Zoom", comment: "Window menu item that zooms the frontmost window"),
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: Localized.string("Bring All to Front", comment: "Window menu item that brings all app windows to the front"),
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )

        return root
    }

    private func helpMenuItem() -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: Localized.string("Help", comment: "Title of the Help menu"))
        root.submenu = menu
        NSApp.helpMenu = menu
        return root
    }

    @objc
    private func presentOpenFilePanel(_ sender: Any? = nil) {
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
                self?.displayFile(at: url)
            }
        }
    }

    @objc
    private func presentOpenFolderPanel(_ sender: Any? = nil) {
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
                self?.displayWorkspace(at: url)
            }
        }
    }

    @objc
    private func openRecentWorkspace(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else {
            return
        }
        displayWorkspace(at: URL(fileURLWithPath: path, isDirectory: true))
    }

    @objc
    private func showSettings(_ sender: Any? = nil) {
        let controller = settingsWindowController ?? SettingsWindowController(
            diagnosticsLog: diagnosticsLog,
            languageSupportService: languageSupportService
        )
        settingsWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    func showLanguageSupportSettings(_ sender: Any? = nil) {
        showSettings(sender)
        settingsWindowController?.showLanguageSupport(
            profileIdentifier: languageSupportService.focusedProfileIdentifier
        )
    }

    private func displayWorkspace(at url: URL) {
        do {
            let identity = try WorkspaceIdentity(root: url)
            recentWorkspaceStore.record(identity.root)
            configureMainMenu()

            guard let window = welcomeWindowController?.window else {
                return
            }
            persistCurrentWorkspaceState(in: window)
            let controller = WorkspaceViewController(
                identity: identity,
                diagnosticsLog: diagnosticsLog,
                languageSupportService: languageSupportService
            )
            window.contentViewController = controller
            window.title = identity.root.lastPathComponent
        } catch {
            guard let window = welcomeWindowController?.window else {
                return
            }
            Task {
                let alert = NSAlert(error: error)
                await alert.beginSheetModal(for: window)
            }
        }
    }

    private func displayFile(at url: URL) {
        sourceLoadTask?.cancel()
        sourceLoadTask = Task { [weak self] in
            do {
                let snapshot = try await Task.detached(priority: .userInitiated) {
                    try SourceSnapshotLoader().load(url: url)
                }.value

                guard !Task.isCancelled, let self else {
                    return
                }
                let controller = StandaloneDocumentViewController(
                    snapshot: snapshot,
                    languageSupportService: self.languageSupportService
                )
                guard let window = self.welcomeWindowController?.window else {
                    return
                }
                self.persistCurrentWorkspaceState(in: window)
                self.restoreStandardWindowChrome(window)
                window.contentViewController = controller
                window.title = url.lastPathComponent
            } catch is CancellationError {
                return
            } catch {
                guard let window = self?.welcomeWindowController?.window else {
                    return
                }
                let alert = NSAlert(error: error)
                await alert.beginSheetModal(for: window)
            }
        }
    }

    private func restoreStandardWindowChrome(_ window: NSWindow) {
        window.delegate = nil
        window.toolbar = nil
        window.styleMask.remove(.fullSizeContentView)
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .automatic
        window.toolbarStyle = .automatic
    }

    func persistCurrentWorkspaceState(in window: NSWindow? = nil) {
        let window = window ?? welcomeWindowController?.window
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
