import AppKit
import XCTest
@testable import Kod

/// Headless coverage for the keyboard-command registry (SPEC 5.7):
/// every primary open → search → navigate → diagnose → diff → preview
/// workflow command must be discoverable in Kod's real native menu bar
/// — not a hand-maintained parallel list that could drift from it — and
/// every command that carries a keyboard shortcut must have a non-empty
/// key equivalent, while menu-only commands are explicitly recognized
/// as such via `isMenuOnly`. `AppDelegate.buildMainMenu()` constructs
/// the exact same `NSMenu`/`NSMenuItem` tree the app installs as
/// `NSApp.mainMenu`, without touching `NSApp` itself or calling
/// `application.run()` — so this never launches a real run loop or any
/// UI automation.
@MainActor
final class KeyboardCommandRegistryTests: XCTestCase {
    private func mainMenu() throws -> NSMenu {
        let fixture = try KodAppTestEnvironment.make(in: self)
        return AppDelegate(environment: fixture.environment).buildMainMenu()
    }

    func testEveryPrimaryWorkflowTitleIsPresentInTheRealMenu() throws {
        let menu = try mainMenu()
        let commands = KeyboardCommandRegistry.primaryWorkflowCommands(in: menu)
        let foundTitles = Set(commands.map(\.displayName))

        for title in KeyboardCommandRegistry.primaryWorkflowTitles {
            XCTAssertTrue(
                foundTitles.contains(title),
                "\"\(title)\" is listed as a primary-workflow command but is missing from AppDelegate's real menu"
            )
        }
        XCTAssertEqual(commands.count, KeyboardCommandRegistry.primaryWorkflowTitles.count)
    }

    func testEveryPrimaryWorkflowCommandHasANonEmptyKeyEquivalentOrIsExplicitlyMenuOnly() throws {
        let commands = KeyboardCommandRegistry.primaryWorkflowCommands(
            in: try mainMenu()
        )
        XCTAssertFalse(commands.isEmpty)

        for command in commands {
            if command.keyEquivalent.isEmpty {
                XCTAssertTrue(
                    command.isMenuOnly,
                    "\(command.identifier) has an empty key equivalent but isMenuOnly reports false"
                )
            } else {
                XCTAssertFalse(
                    command.isMenuOnly,
                    "\(command.identifier) has a real shortcut but isMenuOnly reports true"
                )
            }
        }
    }

    /// Commands that are documented (in `AppDelegate`'s own menu
    /// construction) as carrying a specific keyboard shortcut must
    /// keep exactly that shortcut — regression coverage so a future
    /// edit can't silently drop a shortcut while leaving the menu title
    /// in place.
    func testKnownShortcutsMatchTheirRealMenuItems() throws {
        let commands = KeyboardCommandRegistry.commands(in: try mainMenu())
        func command(titled title: String) -> KeyboardCommand? {
            commands.first { $0.displayName == title }
        }

        XCTAssertEqual(command(titled: "Quick Open...")?.keyEquivalent, "p")
        XCTAssertEqual(command(titled: "Quick Open...")?.modifierMask, [.command])

        XCTAssertEqual(command(titled: "Find in File...")?.keyEquivalent, "f")
        XCTAssertEqual(command(titled: "Find in File...")?.modifierMask, [.command])

        XCTAssertEqual(command(titled: "Search Workspace...")?.keyEquivalent, "f")
        XCTAssertEqual(command(titled: "Search Workspace...")?.modifierMask, [.command, .shift])

        XCTAssertEqual(command(titled: "Go to Line...")?.keyEquivalent, "g")
        XCTAssertEqual(command(titled: "Go to Line...")?.modifierMask, [.control])

        let expectedF12 = UnicodeScalar(NSF12FunctionKey).map(String.init)
        XCTAssertEqual(command(titled: "Go to Definition")?.keyEquivalent, expectedF12)
        XCTAssertEqual(command(titled: "Go to Definition")?.modifierMask, [])

        let expectedF3 = UnicodeScalar(NSF3FunctionKey).map(String.init)
        XCTAssertEqual(command(titled: "Previous Git Change")?.keyEquivalent, expectedF3)
        XCTAssertEqual(command(titled: "Previous Git Change")?.modifierMask, [.option, .shift])
        XCTAssertEqual(command(titled: "Next Git Change")?.keyEquivalent, expectedF3)
        XCTAssertEqual(command(titled: "Next Git Change")?.modifierMask, [.option])

        XCTAssertEqual(command(titled: "Toggle Source and Preview")?.keyEquivalent, "\r")
        XCTAssertEqual(command(titled: "Toggle Source and Preview")?.modifierMask, [.command])

        // Explicitly menu-only, per the primary-workflow list above.
        XCTAssertEqual(command(titled: "Show Problems")?.keyEquivalent, "")
        XCTAssertTrue(command(titled: "Show Problems")?.isMenuOnly ?? false)
        XCTAssertEqual(command(titled: "Show Git Blame")?.keyEquivalent, "")
        XCTAssertTrue(command(titled: "Show Git Blame")?.isMenuOnly ?? false)
    }

    /// `KeyboardCommand.identifier` must be unique across the whole
    /// real menu, so a registry consumer (or a future rotor/palette
    /// built on top of it) can safely key off it.
    func testAllMenuCommandIdentifiersAreUnique() throws {
        let identifiers = KeyboardCommandRegistry.commands(
            in: try mainMenu()
        ).map(\.identifier)
        XCTAssertEqual(identifiers.count, Set(identifiers).count, "duplicate command identifiers found: \(identifiers)")
    }

    func testMinimapCommandIsARealCheckedViewMenuAction() throws {
        let command = try XCTUnwrap(
            KeyboardCommandRegistry.commands(in: try mainMenu()).first {
                $0.displayName == "Minimap"
            }
        )
        XCTAssertEqual(command.menuPath.first, "View")
        XCTAssertTrue(command.isMenuOnly)
    }

    /// Every primary-workflow command must have a real, non-empty
    /// display name and resolve to an actual `@objc` action selector on
    /// some object in the app (i.e. it corresponds to a real command,
    /// not a decorative label) — confirmed indirectly here by requiring
    /// a non-empty `menuPath` reaching into a named top-level menu
    /// (File/Edit/View/Navigate), matching `AppDelegate`'s real menu
    /// structure.
    func testPrimaryWorkflowCommandsHaveMultiSegmentMenuPaths() throws {
        for command in KeyboardCommandRegistry.primaryWorkflowCommands(
            in: try mainMenu()
        ) {
            XCTAssertGreaterThanOrEqual(
                command.menuPath.count,
                2,
                "\(command.identifier) should be nested under a real top-level menu"
            )
        }
    }
    // MARK: - WorkspaceCommandCatalog Tests

    func testCatalogCommandIDsAreUnique() {
        let allIDs = WorkspaceCommandCatalog.shared.commands.map(\.id.rawValue)
        XCTAssertEqual(allIDs.count, Set(allIDs).count, "duplicate command IDs found in catalog")
        XCTAssertEqual(
            Set(allIDs),
            Set(WorkspaceCommandID.allCases.map(\.rawValue)),
            "Every stable command ID must have catalog metadata"
        )
    }

    func testEveryRequiredWorkflowHasADeclaredReachableSurface() {
        let requiredTitles = KeyboardCommandRegistry.primaryWorkflowTitles
        let catalogCommands = WorkspaceCommandCatalog.shared.commands

        for title in requiredTitles {
            let matches = catalogCommands.filter { $0.menuTitle == title || $0.paletteTitle == title }
            XCTAssertFalse(matches.isEmpty, "Required workflow title '\(title)' is missing from catalog")
        }
    }

    func testPaletteExclusionsAreIntentional() {
        for command in WorkspaceCommandCatalog.shared.commands {
            if case .menuOnly(let reason) = command.surface {
                XCTAssertFalse(reason.isEmpty, "Command \(command.id) is excluded from the palette without a documented reason")
            }
        }
    }

    func testPaletteOrderPreservesStableCommandIDs() {
        let catalog = WorkspaceCommandCatalog.shared
        let paletteIDs = catalog.commands.compactMap { command -> WorkspaceCommandID? in
            switch command.surface {
            case .menuAndPalette, .paletteOnly:
                return command.id
            case .menuOnly:
                return nil
            }
        }

        XCTAssertEqual(catalog.paletteOrder.count, Set(catalog.paletteOrder).count)
        XCTAssertEqual(Set(catalog.paletteOrder), Set(paletteIDs))
        XCTAssertEqual(
            catalog.paletteOrder.map(\.rawValue),
            [
                "command.quickOpen",
                "command.findInFile",
                "command.searchWorkspace",
                "command.goToLine",
                "command.toggleWordWrap",
                "command.toggleMinimap",
                "command.splitRight",
                "command.splitDown",
                "command.closeGroup",
                "command.closeTab",
                "command.navigateBack",
                "command.navigateForward",
                "command.goToDefinition",
                "command.peekDefinition",
                "command.showCallHierarchy"
            ]
        )
    }

    func testCatalogDeclaresTargetRoutingAndValidation() {
        let catalog = WorkspaceCommandCatalog.shared
        let appDelegateIDs = Set(
            catalog.commands
                .filter { $0.target == .appDelegate }
                .map(\.id)
        )
        XCTAssertEqual(
            appDelegateIDs,
            [.applicationSettings, .fileOpenFolder, .fileOpenFile]
        )
        XCTAssertEqual(
            catalog.metadata(for: .viewWordWrap)?.validation,
            .stateWordWrap
        )
        XCTAssertEqual(
            catalog.metadata(for: .viewMinimap)?.validation,
            .stateMinimap
        )
        XCTAssertEqual(
            catalog.metadata(for: .viewCloseGroup)?.validation,
            .requiresActiveGroupCountGreaterThanOne
        )
    }
}
