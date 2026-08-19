import DiagnosticsCore
import Foundation
import LanguageAdapters
import SettingsCore
import XCTest
@testable import Kod

@MainActor
struct KodAppTestEnvironment {
    let environment: AppEnvironment
    let keyValueStore: InMemorySettingsKeyValueStore

    static func make(
        in _: XCTestCase,
        diagnosticsLog: BoundedEventLog = BoundedEventLog(),
        languageSupportService: LanguageSupportService? = nil
    ) throws -> KodAppTestEnvironment {
        let keyValueStore = InMemorySettingsKeyValueStore()
        let repository = CodableSettingsRepository(store: keyValueStore)
        return KodAppTestEnvironment(
            environment: try .testing(
                settingsRepository: repository,
                diagnosticsLog: diagnosticsLog,
                languageSupportService: languageSupportService
            ),
            keyValueStore: keyValueStore
        )
    }

    static func makeOverrideStore(
        in _: XCTestCase
    ) throws -> LanguageServerOverrideStore {
        LanguageServerOverrideStore(
            repository: CodableSettingsRepository(
                store: InMemorySettingsKeyValueStore()
            )
        )
    }
}
