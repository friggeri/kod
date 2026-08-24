import AppKit
import Combine
import FontCore
import LanguageAdapters
import SettingsCore
import XCTest
@testable import Kod

@MainActor
final class SettingsModelTests: XCTestCase {
    private func makeStore() -> FontSettingsStore {
        FontSettingsStore(
            repository: CodableSettingsRepository(
                store: InMemorySettingsKeyValueStore()
            )
        )
    }

    func testLoadsAndPersistsCurrentFontSettings() throws {
        let store = makeStore()
        let persisted = FontSettings(
            familyName: "Menlo",
            pointSize: 19,
            weight: .semibold,
            ligaturesEnabled: true,
            lineHeightMultiplier: 1.4,
            letterSpacing: 0.5
        )
        try store.save(persisted)

        let model = try SettingsModel(fontSettingsStore: store)

        XCTAssertEqual(model.fontSettings, persisted)

        model.fontSettings.pointSize = 21
        guard case .value(let reloaded, _) = try store.load() else {
            return XCTFail("Expected the edited font settings to persist")
        }
        XCTAssertEqual(reloaded.pointSize, 21)
    }

    func testNavigationModelPublishesDestinationChanges() {
        let model = SettingsNavigationModel()
        var selections: [SettingsDestination?] = []
        let subscription = model.$selectedDestination
            .dropFirst()
            .sink { selections.append($0) }

        model.selectedDestination = .language("swift")
        model.selectedDestination = .font

        XCTAssertEqual(selections, [.language("swift"), .font])
        withExtendedLifetime(subscription) {}
    }

    func testReloadsFontSettingsChangedThroughTheStore() async throws {
        let store = makeStore()
        let model = try SettingsModel(fontSettingsStore: store)
        let updated = FontSettings(
            familyName: "Monaco",
            pointSize: 24,
            weight: .bold,
            ligaturesEnabled: true
        )
        let reloaded = expectation(description: "Settings model reloaded")
        let subscription = model.$fontSettings
            .dropFirst()
            .filter { $0 == updated }
            .sink { _ in reloaded.fulfill() }

        try store.save(updated)

        await fulfillment(of: [reloaded], timeout: 1)
        XCTAssertEqual(model.fontSettings, updated)
        withExtendedLifetime(subscription) {}
    }

    func testWindowUsesPermanentNativeSidebar() throws {
        let repository = CodableSettingsRepository(
            store: InMemorySettingsKeyValueStore()
        )
        let overrideStore = LanguageServerOverrideStore(
            repository: repository
        )
        let languageService = LanguageSupportService(
            profileStore: try LanguageProfileStore(
                defaultProfiles: [DefaultLanguageProfiles.swift],
                repository: repository,
                overrideStore: overrideStore
            ),
            overrideStore: overrideStore
        )
        let controller = try SettingsWindowController(
            fontSettingsStore: FontSettingsStore(repository: repository),
            languageSupportService: languageService
        )
        let window = try XCTUnwrap(controller.window)
        let splitController = try XCTUnwrap(
            window.contentViewController as? NSSplitViewController
        )

        XCTAssertEqual(splitController.splitViewItems.count, 2)
        let sidebar = splitController.splitViewItems[0]
        XCTAssertFalse(sidebar.canCollapse)
        XCTAssertEqual(sidebar.minimumThickness, 210)
        XCTAssertEqual(sidebar.maximumThickness, 260)
        XCTAssertEqual(
            splitController.splitViewItems[1].minimumThickness,
            570
        )
        XCTAssertGreaterThanOrEqual(window.minSize.width, 800)
        XCTAssertGreaterThanOrEqual(window.minSize.height, 560)
        XCTAssertTrue(window.styleMask.contains(.resizable))

        controller.showLanguageSupport(profileIdentifier: "swift")
        XCTAssertEqual(window.title, "Swift")
    }
}
