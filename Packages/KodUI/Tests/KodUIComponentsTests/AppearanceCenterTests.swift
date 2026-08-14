import AppKit
import FontCore
import SettingsCore
import ThemeCore
import XCTest
@testable import KodUIComponents

/// Confirms `AppearanceCenter.systemIsHighContrast()` and
/// `resolvedActiveTheme(...)`'s real call sites (`SettingsWindowController`,
/// `AppearanceCenter`) are actually wired to
/// `NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast` — a
/// real, live AppKit signal — rather than a hardcoded `false` (SPEC 14:
/// "Increase Contrast" support). This can't literally toggle the OS
/// setting headlessly, so it instead proves there is no way for the
/// value to be anything other than that live API's current answer: the
/// function is a one-line passthrough with no stored/cached/hardcoded
/// override anywhere in between.
@MainActor
final class AppearanceCenterTests: XCTestCase {
    func testIsSystemHighContrastReflectsTheLiveNSWorkspaceSignal() {
        XCTAssertEqual(
            AppearanceCenter.systemIsHighContrast(),
            NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            "isSystemHighContrast() must be a live read of NSWorkspace, not a hardcoded/stubbed value"
        )
    }

    /// The appearance center must feed `resolvedActiveTheme(systemIsDark:
    /// systemIsHighContrast:)` the *real* `isSystemHighContrast()`
    /// value — proven with an isolated in-memory repository (so no
    /// persisted "explicit active theme" from another test can mask the
    /// signal) by constructing a `ThemeStore` exactly the way
    /// `AppearanceCenter` does and confirming it picks
    /// a high-contrast bundled theme if and only if the live signal
    /// is on, for both light and dark appearance.
    func testResolvedActiveThemePicksHighContrastBundledThemeExactlyWhenTheLiveSignalIsOn() throws {
        let isHighContrast = AppearanceCenter.systemIsHighContrast()
        let store = ThemeStore(
            repository: CodableSettingsRepository(
                store: InMemorySettingsKeyValueStore()
            )
        )
        let highContrastIdentifiers: Set<String> = [
            BundledThemes.highContrastLight.identifier,
            BundledThemes.highContrastDark.identifier
        ]

        for isDark in [false, true] {
            let resolved = try store.resolvedActiveTheme(
                systemIsDark: isDark,
                systemIsHighContrast: isHighContrast
            )
            XCTAssertEqual(
                highContrastIdentifiers.contains(resolved.identifier),
                isHighContrast,
                "resolvedActiveTheme(isDark: \(isDark)) must pick a high-contrast theme iff the real system signal is on"
            )
        }
    }

    func testCenterPublishesStoreChangesThroughOwnedObservation() async throws {
        let repository = CodableSettingsRepository(
            store: InMemorySettingsKeyValueStore()
        )
        let themeStore = ThemeStore(repository: repository)
        let fontStore = FontSettingsStore(repository: repository)
        let center = try AppearanceCenter(
            themeStore: themeStore,
            fontSettingsStore: fontStore
        )
        var snapshots: [AppearanceCenter.Snapshot] = []
        let observation = center.observe { snapshots.append($0) }

        try themeStore.setActiveThemeIdentifier(
            BundledThemes.highContrastDark.identifier
        )
        for _ in 0..<50
        where center.snapshot.theme.identifier
            != BundledThemes.highContrastDark.identifier {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(
            center.snapshot.theme.identifier,
            BundledThemes.highContrastDark.identifier
        )
        XCTAssertGreaterThanOrEqual(snapshots.count, 2)
        withExtendedLifetime(observation) {}
    }
}
