import AppKit

/// A single primary-workflow command as it actually exists in Kod's
/// native menu bar, expressed as plain, `Equatable` data rather than an
/// `NSMenuItem` reference — so tests can hold onto and compare commands
/// without keeping the (mutable, AppKit-owned) menu tree alive.
///
/// This is deliberately *not* a hand-authored parallel list: every
/// `KeyboardCommand` the registry produces is read straight off a real
/// `NSMenu` built by `AppDelegate.buildMainMenu()` (see
/// `KeyboardCommandRegistry.commands(in:)`), so the registry can never
/// silently drift out of sync with what a user actually sees in the
/// menu bar.
public struct KeyboardCommand: Equatable, Sendable {
    /// Stable path from the menu bar root to this item, e.g.
    /// `["File", "Quick Open..."]` — used as the identifier since Kod's
    /// menu titles are fixed, human-visible text (not indices that
    /// silently shift when a menu is reordered).
    public let menuPath: [String]
    public let displayName: String
    /// `""` when the command has no keyboard shortcut and is reachable
    /// only via the menu itself (still a valid, keyboard-only path: the
    /// menu bar is fully navigable with the keyboard).
    public let keyEquivalent: String
    public let modifierMask: NSEvent.ModifierFlags

    public var identifier: String { menuPath.joined(separator: " > ") }

    /// `true` when there is no key-equivalent shortcut, i.e. this
    /// command is reachable only by navigating the menu itself (still
    /// fully keyboard-operable via the standard menu-bar key-navigation
    /// gesture) rather than by a direct shortcut.
    public var isMenuOnly: Bool { keyEquivalent.isEmpty }
}

/// Builds `KeyboardCommand`s by walking a real `NSMenu` tree and lists
/// which command titles make up Kod's primary "open → search →
/// navigate → diagnose → diff → preview" workflow (SPEC 5.7), so that
/// workflow's keyboard/menu reachability can be asserted headlessly —
/// no `NSApp.run()`, no `XCUIApplication`, no simulated key presses.
enum KeyboardCommandRegistry {
    /// Recursively flattens every actionable item in `menu` (skipping
    /// separators and pure submenu containers, which contribute only
    /// their title to their children's `menuPath`) into `KeyboardCommand`s.
    static func commands(in menu: NSMenu, path: [String] = []) -> [KeyboardCommand] {
        var results: [KeyboardCommand] = []
        for item in menu.items {
            guard !item.isSeparatorItem else {
                continue
            }
            // Top-level menu-bar roots (e.g. the item returned by
            // `AppDelegate.fileMenuItem()`) are constructed with
            // `NSMenuItem()`, whose default `title` is the non-empty,
            // non-localized placeholder string "NSMenuItem" (an AppKit
            // quirk, not a blank string) — the label users actually see
            // is their *submenu's* title ("File", "Edit", ...), so a
            // non-empty submenu title always wins for these roots.
            // Nested items that carry their own real command (like
            // "Open Recent", which also has a submenu) set their own
            // `title` to the same display text as their submenu's
            // title, so preferring the submenu title here is still
            // correct for them too.
            let label: String
            if let submenuTitle = item.submenu?.title, !submenuTitle.isEmpty {
                label = submenuTitle
            } else {
                label = item.title
            }
            let itemPath = path + [label]
            // Any `NSMenuItem` with a submenu is always a pure
            // container to recurse into, never a leaf command — AppKit
            // itself sets `item.action` to `#selector(NSMenu.submenuAction(_:))`
            // on every item that has a submenu (a genuine AppKit quirk,
            // not something specific to this app's menu construction),
            // so `item.action == nil` is never a reliable signal for
            // "this is a real command" and must not gate recursion.
            if let submenu = item.submenu {
                results.append(contentsOf: commands(in: submenu, path: itemPath))
                continue
            }
            guard item.action != nil else {
                continue
            }
            results.append(
                KeyboardCommand(
                    menuPath: itemPath,
                    displayName: item.title,
                    keyEquivalent: item.keyEquivalent,
                    modifierMask: item.keyEquivalentModifierMask
                )
            )
        }
        return results
    }

    /// Menu titles for the primary open → search → navigate → diagnose
    /// → diff → preview workflow this task must keep reachable by
    /// keyboard alone. Matched by title (stable, user-visible text)
    /// rather than by position, so a future reordering of the menu
    /// can't silently desync this set from `AppDelegate`'s real wiring
    /// — a renamed/removed command simply fails
    /// `KeyboardCommandRegistryTests` immediately.
    static let primaryWorkflowTitles: Set<String> = [
        // open
        "Open Folder...",
        "Open File...",
        // search / navigate-to
        "Quick Open...",
        "Find in File...",
        "Search Workspace...",
        "Command Palette...",
        "Go to Line...",
        // navigate
        "Back",
        "Forward",
        "Go to Matching Bracket",
        // diagnose
        "Show Problems",
        "Show Symbols",
        // diff
        "Show Source Control",
        "Show Git Blame",
        // preview
        "Toggle Source and Preview"
    ]

    /// The subset of `commands(in:)` that make up the primary workflow,
    /// matched against `primaryWorkflowTitles`.
    static func primaryWorkflowCommands(in menu: NSMenu) -> [KeyboardCommand] {
        commands(in: menu).filter { primaryWorkflowTitles.contains($0.displayName) }
    }
}
