import Foundation
import SourceModel
import WorkspaceCore
import XCTest
@testable import LanguageAdapters
@testable import LanguageClient

/// Real, headless `pyright-langserver` integration test against
/// `Fixtures/PythonFixture`. See
/// `TypeScriptLanguageAdapterIntegrationTests` for the shared pattern
/// this follows.
final class PythonLanguageAdapterIntegrationTests: XCTestCase {
    @MainActor
    private func makeService(root: URL) throws -> LanguageWorkspaceService {
        let executableURL = try PinnedTestLanguageServerLocator.pyrightLangserver()
        let identity = try WorkspaceIdentity(root: root)
        let suiteName = "PythonLanguageAdapterIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        let trustStore = WorkspaceTrustStore(defaults: defaults)
        trustStore.trust(identity)
        let overrideStore = LanguageServerOverrideStore(defaults: defaults)
        overrideStore.setWorkspaceOverride(
            url: executableURL,
            arguments: ["--stdio"],
            languageKey: PythonLanguageAdapter.languageKey,
            identity: identity
        )
        return LanguageAdapterRegistry.makeService(
            for: PythonLanguageAdapter.self,
            identity: identity,
            trustStore: trustStore,
            overrideStore: overrideStore
        )
    }

    @MainActor
    func testInitializeHoverDefinitionAndDocumentSymbolsAgainstRealPyright() async throws {
        let root = PinnedTestLanguageServerLocator.fixture("PythonFixture")
        let service: LanguageWorkspaceService
        do {
            service = try makeService(root: root)
        } catch let error as PinnedExecutableMissing {
            throw XCTSkip("\(error)")
        }

        try await service.start()
        addTeardownBlock { await service.stop() }

        let fileURL = root.appendingPathComponent("greeter.py")
        let originalChecksum = try Data(contentsOf: fileURL)

        let snapshot = try SourceSnapshotLoader().load(url: fileURL, version: 1)
        try await service.didOpen(snapshot)

        let text = snapshot.text
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let hoverLineIndex = try XCTUnwrap(lines.firstIndex { $0.contains("def greet") })
        let hoverLine = String(lines[hoverLineIndex])
        let hoverCharacter = try XCTUnwrap(hoverLine.range(of: "greet"))
        let hoverColumn = hoverLine.distance(from: hoverLine.startIndex, to: hoverCharacter.lowerBound) + 1
        let hoverOffset = try snapshot.utf8Offset(
            for: SourcePosition(line: hoverLineIndex, character: hoverColumn),
            encoding: .utf16
        )

        let hover = try await retryUntilNonNil { try await service.hover(snapshot: snapshot, utf8Offset: hoverOffset) }
        let hoverValue = try XCTUnwrap(hover?.contents.value)
        XCTAssertTrue(hoverValue.contains("greet"), "Expected hover to mention 'greet', got: \(hoverValue)")

        let definitions = try await service.definition(snapshot: snapshot, utf8Offset: hoverOffset)
        XCTAssertFalse(definitions.isEmpty, "Expected at least one real definition location")

        let symbols = try await retryUntilNonEmpty { try await service.documentSymbols(snapshot: snapshot) }
        XCTAssertTrue(symbols.contains { $0.name == "Greeter" }, "Expected a 'Greeter' document symbol, got: \(symbols.map(\.name))")

        let maybeCapabilities = await service.capabilities()
        let capabilities = try XCTUnwrap(maybeCapabilities)
        if capabilities.declarationProvider?.isEnabled == true {
            let declarations = try await service.declaration(snapshot: snapshot, utf8Offset: hoverOffset)
            XCTAssertFalse(declarations.isEmpty, "Expected at least one real declaration location")
        }
        if capabilities.documentHighlightProvider?.isEnabled == true {
            let highlights = try await service.documentHighlights(snapshot: snapshot, utf8Offset: hoverOffset)
            XCTAssertFalse(highlights.isEmpty, "Expected at least one document highlight at 'greet'")
        }

        try await service.didClose(url: fileURL)

        let finalChecksum = try Data(contentsOf: fileURL)
        XCTAssertEqual(originalChecksum, finalChecksum, "Kod must never modify a workspace file via LSP operations")
    }
}
