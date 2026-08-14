import SettingsCore
@testable import LanguageAdapters

func makeLanguageAdaptersTestRepository() -> CodableSettingsRepository {
    CodableSettingsRepository(store: InMemorySettingsKeyValueStore())
}

func makeLanguageAdaptersTestOverrideStore() -> LanguageServerOverrideStore {
    LanguageServerOverrideStore(
        repository: makeLanguageAdaptersTestRepository()
    )
}
