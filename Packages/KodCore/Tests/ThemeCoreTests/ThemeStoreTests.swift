import XCTest
@testable import ThemeCore

final class ThemeStoreTests: XCTestCase {
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "kod.theme-store-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func sampleTheme(identifier: String) -> KodTheme {
        var theme = BundledThemes.theme(forIdentifier: "kod.light")!
        theme.identifier = identifier
        return theme
    }

    @MainActor
    func testImportedThemesEmptyWhenNothingSaved() {
        let store = ThemeStore(defaults: makeIsolatedDefaults())
        XCTAssertEqual(store.importedThemes(), [])
    }

    @MainActor
    func testAddThenLoadImportedThemeRoundTrips() {
        let defaults = makeIsolatedDefaults()
        let store = ThemeStore(defaults: defaults)
        let theme = sampleTheme(identifier: "custom.one")

        store.addImportedTheme(theme)

        XCTAssertEqual(store.importedThemes().map(\.identifier), ["custom.one"])
    }

    @MainActor
    func testCorruptImportedThemesAreQuarantinedAndRebuiltAsEmpty() {
        let defaults = makeIsolatedDefaults()
        defaults.set(Data("not valid json {{{".utf8), forKey: "kod.imported-themes")
        let store = ThemeStore(defaults: defaults)

        let themes = store.importedThemes()

        XCTAssertEqual(themes, [], "corrupt imported themes must fail safe to an empty list")
        XCTAssertEqual(store.quarantine.ledger().count, 1)
        XCTAssertEqual(store.quarantine.ledger()[0].key, "kod.imported-themes")

        // Rebuild must work: importing after quarantine must not resurrect
        // the corrupt bytes or fail again.
        store.addImportedTheme(sampleTheme(identifier: "custom.two"))
        XCTAssertEqual(store.importedThemes().map(\.identifier), ["custom.two"])
    }
}
