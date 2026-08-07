import Foundation
import SourceModel
import WorkspaceCore
import XCTest
@testable import LanguageAdapters
@testable import LanguageClient

/// Real, headless `vscode-html-language-server` integration test against
/// `Fixtures/HTMLFixture`. See `TypeScriptLanguageAdapterIntegrationTests`
/// for the shared pattern this follows.
final class HTMLLanguageAdapterIntegrationTests: XCTestCase {
    @MainActor
    private func makeService(root: URL) throws -> LanguageWorkspaceService {
        let executableURL = try PinnedTestLanguageServerLocator.htmlLanguageServer()
        let identity = try WorkspaceIdentity(root: root)
        let suiteName = "HTMLLanguageAdapterIntegrationTests.\(UUID().uuidString)"
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
            languageKey: HTMLLanguageAdapter.languageKey,
            identity: identity
        )
        return LanguageAdapterRegistry.makeService(
            for: HTMLLanguageAdapter.self,
            identity: identity,
            trustStore: trustStore,
            overrideStore: overrideStore
        )
    }

    @MainActor
    func testInitializeHoverDocumentSymbolsAndFoldingAgainstRealHtmlLanguageServer() async throws {
        let root = PinnedTestLanguageServerLocator.fixture("HTMLFixture")
        let service: LanguageWorkspaceService
        do {
            service = try makeService(root: root)
        } catch let error as PinnedExecutableMissing {
            throw XCTSkip("\(error)")
        }

        try await service.start()
        addTeardownBlock { await service.stop() }

        let fileURL = root.appendingPathComponent("index.html")
        let originalChecksum = try Data(contentsOf: fileURL)

        let snapshot = try SourceSnapshotLoader().load(url: fileURL, version: 1)
        try await service.didOpen(snapshot)

        let text = snapshot.text
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let mainLineIndex = try XCTUnwrap(lines.firstIndex { $0.contains("<main") })
        let mainLine = String(lines[mainLineIndex])
        let mainCharacter = try XCTUnwrap(mainLine.range(of: "main"))
        let mainColumn = mainLine.distance(from: mainLine.startIndex, to: mainCharacter.lowerBound) + 1
        let mainOffset = try snapshot.utf8Offset(
            for: SourcePosition(line: mainLineIndex, character: mainColumn),
            encoding: .utf16
        )

        let hover = try await retryUntilNonNil { try await service.hover(snapshot: snapshot, utf8Offset: mainOffset) }
        XCTAssertNotNil(hover, "Expected a real hover response for the <main> tag")

        let symbols = try await service.documentSymbols(snapshot: snapshot)
        XCTAssertFalse(symbols.isEmpty, "Expected at least one real document symbol for this HTML document")

        let maybeCapabilities = await service.capabilities()
        let capabilities = try XCTUnwrap(maybeCapabilities)
        if capabilities.foldingRangeProvider?.isEnabled == true {
            let foldingRanges = try await service.foldingRanges(snapshot: snapshot)
            XCTAssertFalse(foldingRanges.isEmpty, "Expected at least one real folding range for nested HTML elements")
        }
        if capabilities.documentLinkProvider?.isEnabled == true {
            let links = try await service.documentLinks(snapshot: snapshot)
            XCTAssertFalse(links.isEmpty, "Expected the <link href=\"style.css\"> to surface as a document link")
        }

        try await service.didClose(url: fileURL)

        let finalChecksum = try Data(contentsOf: fileURL)
        XCTAssertEqual(originalChecksum, finalChecksum, "Kod must never modify a workspace file via LSP operations")
    }
}
