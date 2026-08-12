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

    @MainActor
    func testLegacyPersistedThemeWithoutExpandedGitColorsIsNotQuarantined() throws {
        let defaults = makeIsolatedDefaults()
        var theme = sampleTheme(identifier: "legacy.theme")
        theme.git.modified = ThemeColor(hex: "#123456")!
        theme.git.added = ThemeColor(hex: "#234567")!
        theme.git.deleted = ThemeColor(hex: "#345678")!

        let encoded = try JSONEncoder().encode([theme])
        var array = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [[String: Any]]
        )
        var storedTheme = array[0]
        var git = try XCTUnwrap(storedTheme["git"] as? [String: Any])
        [
            "renamed", "untracked", "ignored", "stagedModified", "stagedDeleted",
            "gutterAdded", "gutterModified", "gutterDeleted",
            "insertedBackground", "removedBackground",
            "insertedTextBackground", "removedTextBackground"
        ].forEach {
            git.removeValue(forKey: $0)
        }
        storedTheme["git"] = git
        array[0] = storedTheme
        defaults.set(
            try JSONSerialization.data(withJSONObject: array),
            forKey: "kod.imported-themes"
        )

        let store = ThemeStore(defaults: defaults)
        let restored = try XCTUnwrap(store.importedThemes().first)

        XCTAssertTrue(store.quarantine.ledger().isEmpty)
        XCTAssertEqual(restored.identifier, "legacy.theme")
        XCTAssertEqual(restored.git.renamed, restored.git.modified)
        XCTAssertEqual(restored.git.untracked, restored.git.added)
        XCTAssertEqual(restored.git.ignored, restored.git.modified)
        XCTAssertEqual(restored.git.stagedModified, restored.git.modified)
        XCTAssertEqual(restored.git.stagedDeleted, restored.git.deleted)
        XCTAssertEqual(restored.git.gutterAdded, restored.git.added)
        XCTAssertEqual(restored.git.gutterModified, restored.git.modified)
        XCTAssertEqual(restored.git.gutterDeleted, restored.git.deleted)
    }
}
