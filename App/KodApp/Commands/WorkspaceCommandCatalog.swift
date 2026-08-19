import AppKit
import CodeViewport

@MainActor
enum WorkspaceCommandID: String, CaseIterable {
    // --- Application ---
    case applicationAbout = "application.about"
    case applicationSettings = "application.settings"
    case applicationHide = "application.hide"
    case applicationHideOthers = "application.hideOthers"
    case applicationShowAll = "application.showAll"
    case applicationQuit = "application.quit"

    // --- File ---
    case fileOpenFolder = "file.openFolder"
    case fileOpenFile = "file.openFile"
    case fileQuickOpen = "command.quickOpen"
    case fileGoToLine = "command.goToLine"
    case fileCommandPalette = "file.commandPalette"
    case fileCloseTab = "command.closeTab"
    case fileCloseWindow = "file.closeWindow"

    // --- Edit ---
    case editCopy = "edit.copy"
    case editSelectAll = "edit.selectAll"
    case editFindInFile = "command.findInFile"
    case editShowExplorer = "edit.showExplorer"
    case editSearchWorkspace = "command.searchWorkspace"
    case editShowSourceControl = "edit.showSourceControl"
    case editShowProblems = "edit.showProblems"
    case editShowGitBlame = "edit.showGitBlame"

    // --- View ---
    case viewIncreaseTextSize = "view.increaseTextSize"
    case viewDecreaseTextSize = "view.decreaseTextSize"
    case viewWordWrap = "command.toggleWordWrap"
    case viewMinimap = "command.toggleMinimap"
    case viewToggleFold = "view.toggleFold"
    case viewSplitRight = "command.splitRight"
    case viewSplitDown = "command.splitDown"
    case viewCloseGroup = "command.closeGroup"
    case viewTogglePreview = "view.togglePreview"

    // --- Navigate ---
    case navigateBack = "command.navigateBack"
    case navigateForward = "command.navigateForward"
    case navigateGoToDefinition = "command.goToDefinition"
    case navigateGoToMatchingBracket = "navigate.goToMatchingBracket"
    case navigatePreviousChange = "navigate.previousChange"
    case navigateNextChange = "navigate.nextChange"

    // --- Palette Only ---
    case peekDefinition = "command.peekDefinition"
    case showCallHierarchy = "command.showCallHierarchy"

    // --- Window ---
    case windowMinimize = "window.minimize"
    case windowZoom = "window.zoom"
    case windowBringAllToFront = "window.bringAllToFront"
}

enum ReachableSurface: Equatable {
    case menuOnly(exclusionReason: String)
    case paletteOnly
    case menuAndPalette
}

enum CommandTarget: Equatable {
    case responderChain
    case appDelegate
}

enum ValidationRequirement: Equatable {
    case alwaysEnabled
    case requiresActiveGroupCountGreaterThanOne
    case requiresCanGoBack
    case requiresCanGoForward
    case requiresActiveGitQuickDiffController
    case stateWordWrap
    case stateMinimap
    case systemStandard
}

struct WorkspaceCommandMetadata {
    let id: WorkspaceCommandID
    let menuTitle: String
    let paletteTitle: String
    let action: Selector
    let keyEquivalent: String
    let modifierMask: NSEvent.ModifierFlags
    let surface: ReachableSurface
    let target: CommandTarget
    let validation: ValidationRequirement
}

enum MenuNode {
    case command(WorkspaceCommandID)
    case separator
    case submenu(title: String, children: [MenuNode])
    case applicationServices
    case openRecent
}

@MainActor
final class WorkspaceCommandCatalog {
    static let shared = WorkspaceCommandCatalog()

    let commands: [WorkspaceCommandMetadata]
    let paletteOrder: [WorkspaceCommandID]
    let mainMenu: [MenuNode]
    private let commandsByID: [WorkspaceCommandID: WorkspaceCommandMetadata]
    private let commandsByAction: [Selector: WorkspaceCommandMetadata]

    private init() {
        var cmds: [WorkspaceCommandMetadata] = []

        func add(
            id: WorkspaceCommandID,
            menuTitle: String,
            paletteTitle: String? = nil,
            action: Selector,
            key: String = "",
            modifiers: NSEvent.ModifierFlags = [.command],
            surface: ReachableSurface,
            target: CommandTarget = .responderChain,
            validation: ValidationRequirement = .alwaysEnabled
        ) {
            cmds.append(WorkspaceCommandMetadata(
                id: id,
                menuTitle: menuTitle,
                paletteTitle: paletteTitle ?? menuTitle,
                action: action,
                keyEquivalent: key,
                modifierMask: modifiers,
                surface: surface,
                target: target,
                validation: validation
            ))
        }

        func functionKeyEquivalent(_ key: Int) -> String {
            guard let scalar = UnicodeScalar(key) else { return "" }
            return String(scalar)
        }

        // --- Application ---
        add(id: .applicationAbout,
            menuTitle: Localized.string("About Kod", comment: "Application menu item that shows the standard About panel"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            surface: .menuOnly(exclusionReason: "System standard application command"),
            target: .responderChain,
            validation: .systemStandard)
        add(id: .applicationSettings,
            menuTitle: Localized.string("Settings...", comment: "Application menu item that opens the Settings window"),
            action: #selector(AppDelegate.showSettings(_:)),
            key: ",",
            surface: .menuOnly(exclusionReason: "System standard application command"),
            target: .appDelegate)
        add(id: .applicationHide,
            menuTitle: Localized.string("Hide Kod", comment: "Application menu item that hides the app"),
            action: #selector(NSApplication.hide(_:)),
            key: "h",
            surface: .menuOnly(exclusionReason: "System standard window management"),
            target: .responderChain,
            validation: .systemStandard)
        add(id: .applicationHideOthers,
            menuTitle: Localized.string("Hide Others", comment: "Application menu item that hides all other apps"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            key: "h",
            modifiers: [.command, .option],
            surface: .menuOnly(exclusionReason: "System standard window management"),
            target: .responderChain,
            validation: .systemStandard)
        add(id: .applicationShowAll,
            menuTitle: Localized.string("Show All", comment: "Application menu item that unhides all apps"),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            surface: .menuOnly(exclusionReason: "System standard window management"),
            target: .responderChain,
            validation: .systemStandard)
        add(id: .applicationQuit,
            menuTitle: Localized.string("Quit Kod", comment: "Application menu item that quits the app"),
            action: #selector(NSApplication.terminate(_:)),
            key: "q",
            surface: .menuOnly(exclusionReason: "System standard application command"),
            target: .responderChain,
            validation: .systemStandard)

        // --- File ---
        add(id: .fileOpenFolder,
            menuTitle: Localized.string("Open Folder...", comment: "File menu item that opens a folder-selection panel"),
            action: #selector(AppDelegate.presentOpenFolderPanel(_:)),
            key: "o",
            surface: .menuOnly(exclusionReason: "Requires OS file picker interaction"),
            target: .appDelegate)
        add(id: .fileOpenFile,
            menuTitle: Localized.string("Open File...", comment: "File menu item that opens a file-selection panel"),
            action: #selector(AppDelegate.presentOpenFilePanel(_:)),
            key: "o",
            modifiers: [.command, .option],
            surface: .menuOnly(exclusionReason: "Requires OS file picker interaction"),
            target: .appDelegate)
        add(id: .fileQuickOpen,
            menuTitle: Localized.string("Quick Open...", comment: "File menu item that opens the Quick Open panel"),
            action: #selector(WorkspaceViewController.showQuickOpen(_:)),
            key: "p",
            surface: .menuAndPalette)
        add(id: .fileGoToLine,
            menuTitle: Localized.string("Go to Line...", comment: "File menu item that opens the Go to Line panel"),
            action: #selector(WorkspaceViewController.showGoToLinePanel(_:)),
            key: "g",
            modifiers: [.control],
            surface: .menuAndPalette)
        add(id: .fileCommandPalette,
            menuTitle: Localized.string("Command Palette...", comment: "File menu item that opens the Command Palette"),
            action: #selector(WorkspaceViewController.showCommandPalette(_:)),
            key: "p",
            modifiers: [.command, .shift],
            surface: .menuOnly(exclusionReason: "Cannot trigger palette from palette"))
        add(id: .fileCloseTab,
            menuTitle: Localized.string("Close Tab", comment: "File menu item that closes the active editor tab"),
            action: #selector(WorkspaceViewController.closeActiveTab(_:)),
            key: "w",
            surface: .menuAndPalette)
        add(id: .fileCloseWindow,
            menuTitle: Localized.string("Close Window", comment: "File menu item that closes the frontmost window"),
            action: #selector(NSWindow.performClose(_:)),
            key: "w",
            modifiers: [.command, .shift],
            surface: .menuOnly(exclusionReason: "System standard window management"),
            target: .responderChain,
            validation: .systemStandard)

        // --- Edit ---
        add(id: .editCopy,
            menuTitle: Localized.string("Copy", comment: "Edit menu item that copies the selection"),
            action: #selector(CodeViewport.copy(_:)),
            key: "c",
            surface: .menuOnly(exclusionReason: "Standard text editing handled by system"))
        add(id: .editSelectAll,
            menuTitle: Localized.string("Select All", comment: "Edit menu item that selects all content"),
            action: #selector(CodeViewport.selectAll(_:)),
            key: "a",
            surface: .menuOnly(exclusionReason: "Standard text editing handled by system"))
        add(id: .editFindInFile,
            menuTitle: Localized.string("Find in File...", comment: "Edit menu item that opens in-file find"),
            paletteTitle: Localized.string("Find in File", comment: "Command palette entry that opens in-file find"),
            action: #selector(WorkspaceViewController.findInFile(_:)),
            key: "f",
            surface: .menuAndPalette)
        add(id: .editShowExplorer,
            menuTitle: Localized.string("Show Explorer", comment: "Edit menu item that reveals the Explorer sidebar"),
            action: #selector(WorkspaceViewController.showExplorer(_:)),
            surface: .menuAndPalette)
        add(id: .editSearchWorkspace,
            menuTitle: Localized.string("Search Workspace...", comment: "Edit menu item that opens workspace-wide search"),
            paletteTitle: Localized.string("Search Workspace", comment: "Command palette entry that opens workspace-wide search"),
            action: #selector(WorkspaceViewController.searchWorkspace(_:)),
            key: "f",
            modifiers: [.command, .shift],
            surface: .menuAndPalette)
        add(id: .editShowSourceControl,
            menuTitle: Localized.string("Show Source Control", comment: "Edit menu item that reveals the Source Control sidebar"),
            action: #selector(WorkspaceViewController.showSourceControl(_:)),
            key: "g",
            modifiers: [.command, .shift],
            surface: .menuAndPalette)
        add(id: .editShowProblems,
            menuTitle: Localized.string("Show Problems", comment: "Edit menu item that reveals the Problems panel"),
            action: #selector(WorkspaceViewController.showProblems(_:)),
            surface: .menuAndPalette)
        add(id: .editShowGitBlame,
            menuTitle: Localized.string("Show Git Blame", comment: "Edit menu item that shows Git blame for the selected file"),
            action: #selector(WorkspaceViewController.showGitBlameForSelectedFile(_:)),
            surface: .menuOnly(exclusionReason: "Panel toggles are not currently in palette"))

        // --- View ---
        add(id: .viewIncreaseTextSize,
            menuTitle: Localized.string("Increase Text Size", comment: "View menu item that increases the editor font size"),
            action: #selector(CodeViewport.increaseFontSize(_:)),
            key: "+",
            surface: .menuOnly(exclusionReason: "Font sizing is menu/shortcut only"))
        add(id: .viewDecreaseTextSize,
            menuTitle: Localized.string("Decrease Text Size", comment: "View menu item that decreases the editor font size"),
            action: #selector(CodeViewport.decreaseFontSize(_:)),
            key: "-",
            surface: .menuOnly(exclusionReason: "Font sizing is menu/shortcut only"))
        add(id: .viewWordWrap,
            menuTitle: Localized.string("Word Wrap", comment: "View menu item that toggles word wrap"),
            paletteTitle: Localized.string("Toggle Word Wrap", comment: "Command palette entry that toggles word wrap"),
            action: #selector(WorkspaceViewController.toggleWordWrap(_:)),
            surface: .menuAndPalette,
            validation: .stateWordWrap)
        add(id: .viewMinimap,
            menuTitle: Localized.string("Minimap", comment: "View menu item that toggles the source minimap"),
            paletteTitle: Localized.string("Toggle Minimap", comment: "Command palette entry that toggles the source minimap"),
            action: #selector(WorkspaceViewController.toggleMinimap(_:)),
            surface: .menuAndPalette,
            validation: .stateMinimap)
        add(id: .viewToggleFold,
            menuTitle: Localized.string("Toggle Fold", comment: "View menu item that toggles the code fold at the current line"),
            action: #selector(CodeViewport.toggleFoldAtCurrentLine(_:)),
            key: "]",
            modifiers: [.command, .option],
            surface: .menuOnly(exclusionReason: "Editor inline action better suited for shortcut"))
        add(id: .viewSplitRight,
            menuTitle: Localized.string("Split Editor Right", comment: "View menu item that splits the active editor group to the right"),
            action: #selector(WorkspaceViewController.splitActiveGroupRight(_:)),
            key: "\\",
            surface: .menuAndPalette)
        add(id: .viewSplitDown,
            menuTitle: Localized.string("Split Editor Down", comment: "View menu item that splits the active editor group downward"),
            action: #selector(WorkspaceViewController.splitActiveGroupDown(_:)),
            surface: .menuAndPalette)
        add(id: .viewCloseGroup,
            menuTitle: Localized.string("Close Editor Group", comment: "View menu item that closes the active editor group"),
            action: #selector(WorkspaceViewController.closeActiveGroup(_:)),
            surface: .menuAndPalette,
            validation: .requiresActiveGroupCountGreaterThanOne)
        add(id: .viewTogglePreview,
            menuTitle: Localized.string("Toggle Source and Preview", comment: "View menu item that toggles between source and rendered preview"),
            action: #selector(WorkspaceViewController.togglePreviewSource(_:)),
            key: "\r",
            modifiers: [.command],
            surface: .menuOnly(exclusionReason: "Inline action better suited for shortcut"))

        // --- Navigate ---
        add(id: .navigateBack,
            menuTitle: Localized.string("Back", comment: "Navigate menu item that goes back in navigation history"),
            paletteTitle: Localized.string("Navigate Back", comment: "Command palette entry that navigates back in history"),
            action: #selector(WorkspaceViewController.navigateBack(_:)),
            key: functionKeyEquivalent(NSLeftArrowFunctionKey),
            modifiers: [.command, .option],
            surface: .menuAndPalette,
            validation: .requiresCanGoBack)
        add(id: .navigateForward,
            menuTitle: Localized.string("Forward", comment: "Navigate menu item that goes forward in navigation history"),
            paletteTitle: Localized.string("Navigate Forward", comment: "Command palette entry that navigates forward in history"),
            action: #selector(WorkspaceViewController.navigateForward(_:)),
            key: functionKeyEquivalent(NSRightArrowFunctionKey),
            modifiers: [.command, .option],
            surface: .menuAndPalette,
            validation: .requiresCanGoForward)
        add(id: .navigateGoToDefinition,
            menuTitle: Localized.string("Go to Definition", comment: "Navigate menu item that opens the selected symbol's definition"),
            action: #selector(WorkspaceViewController.goToDefinition(_:)),
            key: functionKeyEquivalent(NSF12FunctionKey),
            modifiers: [],
            surface: .menuAndPalette)
        add(id: .navigateGoToMatchingBracket,
            menuTitle: Localized.string("Go to Matching Bracket", comment: "Navigate menu item that jumps to the matching bracket"),
            action: #selector(CodeViewport.jumpToMatchingBracket(_:)),
            key: "m",
            modifiers: [.command, .control],
            surface: .menuOnly(exclusionReason: "Inline editor action"))
        add(id: .navigatePreviousChange,
            menuTitle: Localized.string("Previous Git Change", comment: "Navigate menu item that opens the previous inline Git change"),
            action: #selector(WorkspaceViewController.showPreviousGitChange(_:)),
            key: functionKeyEquivalent(NSF3FunctionKey),
            modifiers: [.option, .shift],
            surface: .menuOnly(exclusionReason: "Inline editor action better suited for shortcut"),
            validation: .requiresActiveGitQuickDiffController)
        add(id: .navigateNextChange,
            menuTitle: Localized.string("Next Git Change", comment: "Navigate menu item that opens the next inline Git change"),
            action: #selector(WorkspaceViewController.showNextGitChange(_:)),
            key: functionKeyEquivalent(NSF3FunctionKey),
            modifiers: [.option],
            surface: .menuOnly(exclusionReason: "Inline editor action better suited for shortcut"),
            validation: .requiresActiveGitQuickDiffController)
        // --- Palette Only ---
        add(id: .peekDefinition,
            menuTitle: "Peek Definition",
            paletteTitle: Localized.string("Peek Definition", comment: "Command palette entry that shows Peek Definition"),
            action: #selector(WorkspaceViewController.showPeekDefinition(_:)),
            surface: .paletteOnly)
        add(id: .showCallHierarchy,
            menuTitle: "Show Call Hierarchy",
            paletteTitle: Localized.string("Show Call Hierarchy", comment: "Command palette entry that shows the Call Hierarchy panel"),
            action: #selector(WorkspaceViewController.showCallHierarchy(_:)),
            surface: .paletteOnly)

        // --- Window ---
        add(id: .windowMinimize,
            menuTitle: Localized.string("Minimize", comment: "Window menu item that minimizes the frontmost window"),
            action: #selector(NSWindow.performMiniaturize(_:)),
            key: "m",
            surface: .menuOnly(exclusionReason: "System standard window management"),
            target: .responderChain,
            validation: .systemStandard)
        add(id: .windowZoom,
            menuTitle: Localized.string("Zoom", comment: "Window menu item that zooms the frontmost window"),
            action: #selector(NSWindow.performZoom(_:)),
            surface: .menuOnly(exclusionReason: "System standard window management"),
            target: .responderChain,
            validation: .systemStandard)
        add(id: .windowBringAllToFront,
            menuTitle: Localized.string("Bring All to Front", comment: "Window menu item that brings all app windows to the front"),
            action: #selector(NSApplication.arrangeInFront(_:)),
            surface: .menuOnly(exclusionReason: "System standard window management"),
            target: .responderChain,
            validation: .systemStandard)

        self.commands = cmds

        var byID: [WorkspaceCommandID: WorkspaceCommandMetadata] = [:]
        var byAction: [Selector: WorkspaceCommandMetadata] = [:]
        for cmd in cmds {
            byID[cmd.id] = cmd
            byAction[cmd.action] = cmd
        }
        self.commandsByID = byID
        self.commandsByAction = byAction

        self.paletteOrder = [
            .fileQuickOpen,
            .editFindInFile,
            .editShowExplorer,
            .editSearchWorkspace,
            .editShowSourceControl,
            .editShowProblems,
            .fileGoToLine,
            .viewWordWrap,
            .viewMinimap,
            .viewSplitRight,
            .viewSplitDown,
            .viewCloseGroup,
            .fileCloseTab,
            .navigateBack,
            .navigateForward,
            .navigateGoToDefinition,
            .peekDefinition,
            .showCallHierarchy
        ]

        self.mainMenu = [
            .submenu(title: Localized.string("Kod", comment: "Title of the application (Kod) main menu"), children: [
                .command(.applicationAbout),
                .separator,
                .command(.applicationSettings),
                .separator,
                .applicationServices,
                .separator,
                .command(.applicationHide),
                .command(.applicationHideOthers),
                .command(.applicationShowAll),
                .separator,
                .command(.applicationQuit)
            ]),
            .submenu(title: Localized.string("File", comment: "Title of the File menu"), children: [
                .command(.fileOpenFolder),
                .command(.fileOpenFile),
                .openRecent,
                .separator,
                .command(.fileQuickOpen),
                .command(.fileGoToLine),
                .command(.fileCommandPalette),
                .separator,
                .command(.fileCloseTab),
                .command(.fileCloseWindow)
            ]),
            .submenu(title: Localized.string("Edit", comment: "Title of the Edit menu"), children: [
                .command(.editCopy),
                .command(.editSelectAll),
                .separator,
                .command(.editFindInFile),
                .command(.editShowExplorer),
                .command(.editSearchWorkspace),
                .command(.editShowSourceControl),
                .command(.editShowProblems),
                .command(.editShowGitBlame)
            ]),
            .submenu(title: Localized.string("View", comment: "Title of the View menu"), children: [
                .command(.viewIncreaseTextSize),
                .command(.viewDecreaseTextSize),
                .separator,
                .command(.viewWordWrap),
                .command(.viewMinimap),
                .command(.viewToggleFold),
                .separator,
                .command(.viewSplitRight),
                .command(.viewSplitDown),
                .command(.viewCloseGroup),
                .separator,
                .command(.viewTogglePreview)
            ]),
            .submenu(title: Localized.string("Navigate", comment: "Title of the Navigate menu"), children: [
                .command(.navigateBack),
                .command(.navigateForward),
                .separator,
                .command(.navigateGoToDefinition),
                .command(.navigateGoToMatchingBracket),
                .separator,
                .command(.navigatePreviousChange),
                .command(.navigateNextChange)
            ]),
            .submenu(title: Localized.string("Window", comment: "Title of the Window menu"), children: [
                .command(.windowMinimize),
                .command(.windowZoom),
                .separator,
                .command(.windowBringAllToFront)
            ]),
            .submenu(title: Localized.string("Help", comment: "Title of the Help menu"), children: [])
        ]
    }

    func metadata(for id: WorkspaceCommandID) -> WorkspaceCommandMetadata? {
        commandsByID[id]
    }

    func metadata(for action: Selector) -> WorkspaceCommandMetadata? {
        commandsByAction[action]
    }
}
