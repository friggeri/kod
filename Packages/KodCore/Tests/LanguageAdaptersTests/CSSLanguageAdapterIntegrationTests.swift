import Foundation
import SourceIO
import SourceModel
import WorkspaceCore
import XCTest
@testable import LanguageAdapters
@testable import LanguageClient

/// Real, headless `vscode-css-language-server` integration test against
/// `Fixtures/CSSFixture`. See `TypeScriptLanguageAdapterIntegrationTests`
/// for the shared pattern this follows.
final class CSSLanguageAdapterIntegrationTests: XCTestCase {
    @MainActor
    private func makeService(root: URL) throws -> LanguageWorkspaceService {
        let executableURL = try PinnedTestLanguageServerLocator.cssLanguageServer()
        let identity = try WorkspaceIdentity(root: root)
        let repository = makeLanguageAdaptersTestRepository()
        let trustStore = WorkspaceTrustStore(repository: repository)
        try trustStore.trust(identity)
        let overrideStore = LanguageServerOverrideStore(
            repository: repository
        )
        try overrideStore.setWorkspaceOverride(
            url: executableURL,
            arguments: ["--stdio"],
            languageKey: DefaultLanguageProfiles.css.identifier,
            identity: identity
        )
        return try LanguageProfileServiceFactory.makeService(
            for: DefaultLanguageProfiles.css,
            identity: identity,
            trustStore: trustStore,
            overrideStore: overrideStore
        )
    }

    @MainActor
    func testInitializeHoverAndDocumentSymbolsAgainstRealCssLanguageServer() async throws {
        let root = PinnedTestLanguageServerLocator.fixture("CSSFixture")
        let service: LanguageWorkspaceService
        do {
            service = try makeService(root: root)
        } catch let error as PinnedExecutableMissing {
            throw XCTSkip("\(error)")
        }

        try await service.start()
        addTeardownBlock { await service.stop() }

        let fileURL = root.appendingPathComponent("style.css")
        let originalChecksum = try Data(contentsOf: fileURL)

        let snapshot = try SourceSnapshotLoader().load(url: fileURL, version: 1)
        try await service.didOpen(snapshot)

        let text = snapshot.text
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let displayLineIndex = try XCTUnwrap(lines.firstIndex { $0.contains("display:") })
        let displayLine = String(lines[displayLineIndex])
        let displayCharacter = try XCTUnwrap(displayLine.range(of: "display"))
        let displayColumn = displayLine.distance(from: displayLine.startIndex, to: displayCharacter.lowerBound) + 1
        let displayOffset = try snapshot.utf8Offset(
            for: SourcePosition(line: displayLineIndex, character: displayColumn),
            encoding: .utf16
        )

        let hover = try await retryUntilNonNil { try await service.hover(snapshot: snapshot, utf8Offset: displayOffset) }
        XCTAssertNotNil(hover, "Expected a real hover response for the 'display' CSS property")

        let symbols = try await retryUntilNonEmpty { try await service.documentSymbols(snapshot: snapshot) }
        XCTAssertTrue(symbols.contains { $0.name.contains("greeting") }, "Expected a '.greeting' selector document symbol, got: \(symbols.map(\.name))")

        try await service.didClose(url: fileURL)

        let finalChecksum = try Data(contentsOf: fileURL)
        XCTAssertEqual(originalChecksum, finalChecksum, "Kod must never modify a workspace file via LSP operations")
    }
}
