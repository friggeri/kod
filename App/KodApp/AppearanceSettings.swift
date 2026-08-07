import AppKit
import FontCore
import ThemeCore

extension Notification.Name {
    /// Posted after the user changes the active theme (including a fresh
    /// VS Code import) or any font setting, so every open window can
    /// re-apply live without restarting Kod.
    static let kodAppearanceSettingsChanged = Notification.Name("kod.appearanceSettingsChanged")
}

/// Resolves the theme/font settings that should currently be applied,
/// reading directly from the same `UserDefaults`-backed stores
/// `SettingsWindowController` writes to. Each call constructs a fresh,
/// stateless store instance (the same pattern `RecentWorkspaceStore` and
/// `WorkspaceLayoutStore` already use elsewhere in the app), so there is
/// nothing to keep in sync beyond observing the change notification.
enum AppearanceSettings {
    @MainActor
    static func currentTheme() -> KodTheme {
        ThemeStore().resolvedActiveTheme(
            systemIsDark: isSystemDark(),
            systemIsHighContrast: isSystemHighContrast()
        )
    }

    @MainActor
    static func currentFontSettings() -> FontSettings {
        FontSettingsStore().load()
    }

    @MainActor
    static func isSystemDark() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func isSystemHighContrast() -> Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    @MainActor
    static func broadcastChange() {
        NotificationCenter.default.post(name: .kodAppearanceSettingsChanged, object: nil)
    }
}
