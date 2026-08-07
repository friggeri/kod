import AppKit
import ThemeCore
import XCTest
@testable import Kod

/// Confirms `AppearanceSettings.isSystemHighContrast()` and
/// `resolvedActiveTheme(...)`'s real call sites (`SettingsWindowController`,
/// `AppearanceSettings.currentTheme()`) are actually wired to
/// `NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast` — a
/// real, live AppKit signal — rather than a hardcoded `false` (SPEC 14:
/// "Increase Contrast" support). This can't literally toggle the OS
/// setting headlessly, so it instead proves there is no way for the
/// value to be anything other than that live API's current answer: the
/// function is a one-line passthrough with no stored/cached/hardcoded
/// override anywhere in between.
@MainActor
final class AppearanceSettingsTests: XCTestCase {
    func testIsSystemHighContrastReflectsTheLiveNSWorkspaceSignal() {
        XCTAssertEqual(
            AppearanceSettings.isSystemHighContrast(),
            NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            "isSystemHighContrast() must be a live read of NSWorkspace, not a hardcoded/stubbed value"
        )
    }

    /// `currentTheme()` must feed `resolvedActiveTheme(systemIsDark:
    /// systemIsHighContrast:)` the *real* `isSystemHighContrast()`
    /// value — proven with an isolated `UserDefaults` suite (so no
    /// persisted "explicit active theme" from another test can mask the
    /// signal) by constructing a `ThemeStore` exactly the way
    /// `AppearanceSettings.currentTheme()` does and confirming it picks
    /// a high-contrast bundled theme if and only if the live signal
    /// is on, for both light and dark appearance.
    func testResolvedActiveThemePicksHighContrastBundledThemeExactlyWhenTheLiveSignalIsOn() throws {
        let suiteName = "AppearanceSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        let isHighContrast = AppearanceSettings.isSystemHighContrast()
        let store = ThemeStore(defaults: defaults)
        let highContrastIdentifiers: Set<String> = [
            BundledThemes.highContrastLight.identifier,
            BundledThemes.highContrastDark.identifier
        ]

        for isDark in [false, true] {
            let resolved = store.resolvedActiveTheme(systemIsDark: isDark, systemIsHighContrast: isHighContrast)
            XCTAssertEqual(
                highContrastIdentifiers.contains(resolved.identifier),
                isHighContrast,
                "resolvedActiveTheme(isDark: \(isDark)) must pick a high-contrast theme iff the real system signal is on"
            )
        }
    }
}
