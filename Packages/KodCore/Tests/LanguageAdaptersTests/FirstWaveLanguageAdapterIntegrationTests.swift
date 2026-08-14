import Foundation
import SourceIO
import SourceModel
import WorkspaceCore
import XCTest

@testable import LanguageAdapters
@testable import LanguageClient

/// Real, headless integration coverage for the first-wave language servers.
/// The pinned executables are provisioned by
/// `Scripts/vendor-test-language-servers/setup.sh`.
final class FirstWaveLanguageAdapterIntegrationTests: XCTestCase {
    private struct CapabilityExerciseError: Error, CustomStringConvertible {
        let stage: String
        let underlyingError: Error

        var description: String {
            "\(stage): \(underlyingError)"
        }
    }

    @MainActor
    private func makeService(
        for profile: LanguageProfile,
        root: URL,
        executableURL: URL,
        arguments: [String]
    ) throws -> LanguageWorkspaceService {
        let identity = try WorkspaceIdentity(root: root)
        let repository = makeLanguageAdaptersTestRepository()
        let trustStore = WorkspaceTrustStore(repository: repository)
        try trustStore.trust(identity)
        let overrideStore = LanguageServerOverrideStore(
            repository: repository
        )
        try overrideStore.setWorkspaceOverride(
            url: executableURL,
            arguments: arguments,
            languageKey: profile.identifier,
            identity: identity
        )
        XCTAssertTrue(
            DefaultLanguageProfiles.all.contains(profile),
            "Integration coverage must exercise a shipped default profile"
        )
        return try LanguageProfileServiceFactory.makeService(
            for: profile,
            identity: identity,
            trustStore: trustStore,
            overrideStore: overrideStore
        )
    }

    @MainActor
    private func exerciseDocumentSymbols(
        service: LanguageWorkspaceService,
        fixtureURL: URL,
        expectedSymbol: String
    ) async throws {
        var stage = "starting the server"
        do {
            try await service.start()
            addTeardownBlock { await service.stop() }

            stage = "loading the fixture"
            let originalContents = try Data(contentsOf: fixtureURL)
            let snapshot = try SourceSnapshotLoader().load(url: fixtureURL, version: 1)
            stage = "opening the document"
            try await service.didOpen(snapshot)

            stage = "reading server capabilities"
            let maybeCapabilities = await service.capabilities()
            let capabilities = try XCTUnwrap(maybeCapabilities)
            XCTAssertEqual(
                capabilities.documentSymbolProvider?.isEnabled,
                true,
                "The pinned server must advertise document symbols"
            )
            stage = "requesting document symbols"
            let symbols = try await retryUntilNonEmpty {
                try await service.documentSymbols(snapshot: snapshot)
            }
            XCTAssertTrue(
                symbols.contains { $0.name.localizedCaseInsensitiveContains(expectedSymbol) },
                "Expected a symbol containing '\(expectedSymbol)', got \(symbols.map(\.name))"
            )

            let match = try XCTUnwrap(
                snapshot.text.range(of: expectedSymbol, options: .caseInsensitive),
                "Expected to find '\(expectedSymbol)' in \(fixtureURL.lastPathComponent)"
            )
            let utf8Offset = snapshot.text[..<match.lowerBound].utf8.count
            if capabilities.hoverProvider?.isEnabled == true {
                stage = "requesting hover"
                _ = try await service.hover(snapshot: snapshot, utf8Offset: utf8Offset)
            }
            if capabilities.definitionProvider?.isEnabled == true {
                stage = "requesting definition"
                _ = try await service.definition(snapshot: snapshot, utf8Offset: utf8Offset)
            }
            if capabilities.declarationProvider?.isEnabled == true {
                stage = "requesting declaration"
                _ = try await service.declaration(snapshot: snapshot, utf8Offset: utf8Offset)
            }
            if capabilities.typeDefinitionProvider?.isEnabled == true {
                stage = "requesting type definition"
                _ = try await service.typeDefinition(snapshot: snapshot, utf8Offset: utf8Offset)
            }
            if capabilities.referencesProvider?.isEnabled == true {
                stage = "requesting references"
                _ = try await service.references(
                    snapshot: snapshot,
                    utf8Offset: utf8Offset,
                    includeDeclaration: true
                )
            }
            if capabilities.documentHighlightProvider?.isEnabled == true {
                stage = "requesting document highlights"
                _ = try await service.documentHighlights(
                    snapshot: snapshot,
                    utf8Offset: utf8Offset
                )
            }
            if capabilities.workspaceSymbolProvider?.isEnabled == true {
                stage = "requesting workspace symbols"
                _ = try await service.workspaceSymbols(query: expectedSymbol)
            }
            if capabilities.semanticTokensProvider?.full?.isEnabled == true {
                stage = "requesting semantic tokens"
                _ = try await service.semanticTokens(snapshot: snapshot)
            }
            if capabilities.diagnosticProvider != nil {
                stage = "requesting pull diagnostics"
                _ = try await service.pullDiagnostics(snapshot: snapshot)
            }
            if capabilities.foldingRangeProvider?.isEnabled == true {
                stage = "requesting folding ranges"
                let ranges = try await service.foldingRanges(snapshot: snapshot)
                XCTAssertFalse(ranges.isEmpty, "Expected a folding range from the pinned server")
            }
            if capabilities.selectionRangeProvider?.isEnabled == true {
                stage = "requesting selection ranges"
                _ = try await service.selectionRanges(
                    snapshot: snapshot,
                    utf8Offsets: [utf8Offset]
                )
            }
            if capabilities.documentLinkProvider?.isEnabled == true {
                stage = "requesting document links"
                _ = try await service.documentLinks(snapshot: snapshot)
            }
            if capabilities.inlayHintProvider?.isEnabled == true {
                stage = "requesting inlay hints"
                _ = try await service.inlayHints(
                    snapshot: snapshot,
                    utf8Range: 0..<snapshot.utf8Count
                )
            }

            stage = "closing the document"
            try await service.didClose(url: fixtureURL)
            XCTAssertEqual(
                try Data(contentsOf: fixtureURL),
                originalContents,
                "Kod must never modify a workspace file via LSP operations"
            )
        } catch {
            throw CapabilityExerciseError(stage: stage, underlyingError: error)
        }
    }

    @MainActor
    func testShellAgainstPinnedBashLanguageServer() async throws {
        let root = PinnedTestLanguageServerLocator.fixture("ShellFixture")
        let executableURL: URL
        do {
            executableURL = try PinnedTestLanguageServerLocator.bashLanguageServer()
        } catch let error as PinnedExecutableMissing {
            throw XCTSkip("\(error)")
        }
        let service = try makeService(
            for: DefaultLanguageProfiles.shell,
            root: root,
            executableURL: executableURL,
            arguments: ["start"]
        )
        do {
            try await exerciseDocumentSymbols(
                service: service,
                fixtureURL: root.appendingPathComponent("script.sh"),
                expectedSymbol: "greet"
            )
        } catch {
            let stderr = await service.serverStderrLog()
            XCTFail("bash-language-server failed: \(error)\n\(stderr)")
        }
    }

    @MainActor
    func testMarkdownAgainstPinnedMarksman() async throws {
        let root = PinnedTestLanguageServerLocator.fixture("MarkdownFixture")
        let executableURL: URL
        do {
            executableURL = try PinnedTestLanguageServerLocator.marksman()
        } catch let error as PinnedExecutableMissing {
            throw XCTSkip("\(error)")
        }
        let service = try makeService(
            for: DefaultLanguageProfiles.markdown,
            root: root,
            executableURL: executableURL,
            arguments: ["server"]
        )
        try await exerciseDocumentSymbols(
            service: service,
            fixtureURL: root.appendingPathComponent("README.md"),
            expectedSymbol: "Language support"
        )
    }

    @MainActor
    func testJSONAgainstPinnedMicrosoftLanguageServer() async throws {
        let root = PinnedTestLanguageServerLocator.fixture("JSONFixture")
        let executableURL: URL
        do {
            executableURL = try PinnedTestLanguageServerLocator.jsonLanguageServer()
        } catch let error as PinnedExecutableMissing {
            throw XCTSkip("\(error)")
        }
        let service = try makeService(
            for: DefaultLanguageProfiles.json,
            root: root,
            executableURL: executableURL,
            arguments: ["--stdio"]
        )
        try await exerciseDocumentSymbols(
            service: service,
            fixtureURL: root.appendingPathComponent("settings.json"),
            expectedSymbol: "editor"
        )
    }

    @MainActor
    func testYAMLAgainstPinnedYAMLLanguageServer() async throws {
        let root = PinnedTestLanguageServerLocator.fixture("YAMLFixture")
        let executableURL: URL
        do {
            executableURL = try PinnedTestLanguageServerLocator.yamlLanguageServer()
        } catch let error as PinnedExecutableMissing {
            throw XCTSkip("\(error)")
        }
        let service = try makeService(
            for: DefaultLanguageProfiles.yaml,
            root: root,
            executableURL: executableURL,
            arguments: ["--stdio"]
        )
        try await exerciseDocumentSymbols(
            service: service,
            fixtureURL: root.appendingPathComponent("config.yaml"),
            expectedSymbol: "application"
        )
    }

    @MainActor
    func testTOMLAgainstPinnedTombi() async throws {
        let root = PinnedTestLanguageServerLocator.fixture("TOMLFixture")
        let executableURL: URL
        do {
            executableURL = try PinnedTestLanguageServerLocator.tombi()
        } catch let error as PinnedExecutableMissing {
            throw XCTSkip("\(error)")
        }
        let service = try makeService(
            for: DefaultLanguageProfiles.toml,
            root: root,
            executableURL: executableURL,
            arguments: ["lsp"]
        )
        try await exerciseDocumentSymbols(
            service: service,
            fixtureURL: root.appendingPathComponent("config.toml"),
            expectedSymbol: "application"
        )
    }
}
