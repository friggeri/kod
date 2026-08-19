import AppKit
import FontCore
import SettingsCore
import ThemeCore
import XCTest
@testable import KodUIComponents

@MainActor
final class AppearanceCenterTests: XCTestCase {
    func testResolvedActiveThemeUsesOnlySystemLightOrDarkAppearance() throws {
        let store = ThemeStore(
            repository: CodableSettingsRepository(
                store: InMemorySettingsKeyValueStore()
            )
        )

        for isDark in [false, true] {
            for isHighContrast in [false, true] {
                let resolved = try store.resolvedActiveTheme(
                    systemIsDark: isDark,
                    systemIsHighContrast: isHighContrast
                )
                XCTAssertEqual(
                    resolved.identifier,
                    isDark
                        ? BundledThemes.dark.identifier
                        : BundledThemes.light.identifier
                )
            }
        }
    }

    func testCenterIgnoresPersistedThemeSelection() async throws {
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
        let expectedIdentifier = center.snapshot.theme.identifier

        try themeStore.setActiveThemeIdentifier(
            BundledThemes.highContrastDark.identifier
        )
        for _ in 0..<4 {
            await Task.yield()
        }

        XCTAssertEqual(center.snapshot.theme.identifier, expectedIdentifier)
        XCTAssertEqual(snapshots.count, 1)
        withExtendedLifetime(observation) {}
    }
}
