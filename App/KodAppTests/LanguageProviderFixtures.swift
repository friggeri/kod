import Foundation
import LanguageClient
import SourceModel

/// Shared fixtures for provider-bound LSP results. Cross-file results
/// (definitions, workspace symbols, hierarchy items) only exist bound to
/// the provider that produced them, so App-layer tests build an explicit
/// binding rather than an implicit "whatever owns this URL" one.
enum LanguageProviderFixtures {
    static func providerID(
        _ profileIdentifier: String = "swift"
    ) -> LanguageProviderID {
        LanguageProviderID(profileIdentifier: profileIdentifier)
    }

    static func binding(
        providerID: LanguageProviderID = LanguageProviderFixtures.providerID(),
        generation: Int = 1,
        encoding: SourcePositionEncoding = .utf16
    ) -> LanguageProviderBinding {
        LanguageProviderBinding(
            providerID: providerID,
            generation: generation,
            positionEncoding: encoding
        )
    }

    static func location(
        url: URL,
        range: LSPRange,
        binding: LanguageProviderBinding = LanguageProviderFixtures.binding()
    ) -> ProviderBoundLocation {
        ProviderBoundLocation(provider: binding, url: url, range: range)
    }
}
