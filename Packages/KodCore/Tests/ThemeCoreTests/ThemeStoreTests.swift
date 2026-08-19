import SettingsCore
import XCTest
@testable import ThemeCore

final class ThemeStoreTests: XCTestCase {
    @MainActor
    private func makeStore() -> (
        ThemeStore,
        CodableSettingsRepository,
        InMemorySettingsKeyValueStore
    ) {
        let keyValueStore = InMemorySettingsKeyValueStore()
        let repository = CodableSettingsRepository(store: keyValueStore)
        return (
            ThemeStore(repository: repository),
            repository,
            keyValueStore
        )
    }

    private func sampleTheme(identifier: String) -> KodTheme {
        var theme = BundledThemes.theme(forIdentifier: "kod.light")!
        theme.identifier = identifier
        return theme
    }

    @MainActor
    func testImportedThemesAreAbsentWhenNothingSaved() throws {
        let (store, _, _) = makeStore()
        XCTAssertEqual(try store.importedThemes(), .absent)
    }

    @MainActor
    func testAddThenLoadImportedThemeRoundTrips() throws {
        let (store, _, _) = makeStore()
        let theme = sampleTheme(identifier: "custom.one")

        try store.addImportedTheme(theme)

        guard case .value(let themes, _) = try store.importedThemes() else {
            return XCTFail("Expected persisted themes")
        }
        XCTAssertEqual(themes.map(\.identifier), ["custom.one"])
    }

    @MainActor
    func testLegacyActiveThemeStringMigratesToEnvelope() throws {
        let (store, _, keyValueStore) = makeStore()
        try keyValueStore.setValue(
            .string("kod.dark"),
            forKey: "kod.active-theme-identifier"
        )

        XCTAssertEqual(
            try store.activeThemeIdentifier(),
            .value(
                "kod.dark",
                provenance: .migrated(
                    from: .unversioned,
                    toVersion: 1
                )
            )
        )
        guard let stored = try keyValueStore.value(
            forKey: "kod.active-theme-identifier"
        ),
              case .data = stored else {
            return XCTFail("Expected version envelope after migration")
        }
    }

    @MainActor
    func testResolvedThemeIgnoresPersistedSelectionAndHighContrast() throws {
        let (store, _, _) = makeStore()
        try store.setActiveThemeIdentifier("custom.theme")
        try store.addImportedTheme(sampleTheme(identifier: "custom.theme"))

        XCTAssertEqual(
            try store.resolvedActiveTheme(
                systemIsDark: false,
                systemIsHighContrast: true
            ),
            BundledThemes.light
        )
        XCTAssertEqual(
            try store.resolvedActiveTheme(
                systemIsDark: true,
                systemIsHighContrast: true
            ),
            BundledThemes.dark
        )
    }

    @MainActor
    func testCorruptImportedThemesAreQuarantinedAndCanRebuild() throws {
        let (store, repository, keyValueStore) = makeStore()
        try keyValueStore.setValue(
            .data(Data("not valid json {{{".utf8)),
            forKey: "kod.imported-themes"
        )

        guard case .quarantined(let record) =
                try store.importedThemes() else {
            return XCTFail("Expected quarantine")
        }
        XCTAssertEqual(record.key, "kod.imported-themes")
        XCTAssertEqual(try repository.quarantine.records(), [record])

        try store.addImportedTheme(
            sampleTheme(identifier: "custom.two")
        )
        guard case .value(let rebuilt, _) = try store.importedThemes() else {
            return XCTFail("Expected rebuilt themes")
        }
        XCTAssertEqual(rebuilt.map(\.identifier), ["custom.two"])
    }

    @MainActor
    func testLegacyPersistedThemeWithoutExpandedGitColorsMigrates() throws {
        let (store, repository, keyValueStore) = makeStore()
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
        try keyValueStore.setValue(
            .data(try JSONSerialization.data(withJSONObject: array)),
            forKey: "kod.imported-themes"
        )

        guard case .value(let restoredThemes, let provenance) =
                try store.importedThemes() else {
            return XCTFail("Expected migrated themes")
        }
        let restored = try XCTUnwrap(restoredThemes.first)

        XCTAssertEqual(
            provenance,
            .migrated(from: .unversioned, toVersion: 1)
        )
        XCTAssertTrue(try repository.quarantine.records().isEmpty)
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
