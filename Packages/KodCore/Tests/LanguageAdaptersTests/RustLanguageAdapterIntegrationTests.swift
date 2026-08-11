import Foundation
import SourceModel
import WorkspaceCore
import XCTest
@testable import LanguageAdapters
@testable import LanguageClient

/// Real, headless `rust-analyzer` integration test against
/// `Fixtures/RustFixture` — a tiny standalone crate so `rust-analyzer`
/// can build its analysis without needing network access for
/// dependencies. Unlike the other adapters, this one is discovered
/// through `RustAdapter`'s real `rustup which rust-analyzer` probe
/// (SPEC 6.5's "language-specific system discovery" tier), not a
/// workspace override, since `Scripts/vendor-test-language-servers/setup.sh`
/// installs it as a genuine rustup component rather than a copied
/// binary. See `TypeScriptLanguageAdapterIntegrationTests` for the
/// shared pattern this otherwise follows.
final class RustLanguageAdapterIntegrationTests: XCTestCase {
    @MainActor
    private func makeService(root: URL) throws -> LanguageWorkspaceService {
        // Fail fast (skip) here rather than inside `discover()` if
        // rust-analyzer genuinely isn't set up, so the failure message
        // names the exact missing executable.
        _ = try PinnedTestLanguageServerLocator.rustAnalyzerViaRustup()

        let identity = try WorkspaceIdentity(root: root)
        let suiteName = "RustLanguageAdapterIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        let trustStore = WorkspaceTrustStore(defaults: defaults)
        trustStore.trust(identity)
        let overrideStore = LanguageServerOverrideStore(defaults: defaults)
        return try LanguageProfileServiceFactory.makeService(
            for: DefaultLanguageProfiles.rust,
            identity: identity,
            trustStore: trustStore,
            overrideStore: overrideStore
        )
    }

    @MainActor
    func testInitializeHoverDefinitionAndDocumentSymbolsAgainstRealRustAnalyzer() async throws {
        let root = PinnedTestLanguageServerLocator.fixture("RustFixture")
        let service: LanguageWorkspaceService
        do {
            service = try makeService(root: root)
        } catch let error as PinnedExecutableMissing {
            throw XCTSkip("\(error)")
        }

        try await service.start()
        addTeardownBlock { await service.stop() }

        let fileURL = root.appendingPathComponent("src/lib.rs")
        let originalChecksum = try Data(contentsOf: fileURL)

        let snapshot = try SourceSnapshotLoader().load(url: fileURL, version: 1)
        try await service.didOpen(snapshot)

        let text = snapshot.text
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let hoverLineIndex = try XCTUnwrap(lines.firstIndex { $0.contains("pub fn greet") })
        let hoverLine = String(lines[hoverLineIndex])
        let hoverCharacter = try XCTUnwrap(hoverLine.range(of: "greet"))
        let hoverColumn = hoverLine.distance(from: hoverLine.startIndex, to: hoverCharacter.lowerBound) + 1
        let hoverOffset = try snapshot.utf8Offset(
            for: SourcePosition(line: hoverLineIndex, character: hoverColumn),
            encoding: .utf16
        )

        // rust-analyzer needs a background `cargo metadata`/project-load
        // pass (analogous to SourceKit-LSP's indexing) before hover on a
        // fresh process reliably resolves. Generous budget: under heavy
        // parallel test/process load on a shared machine, this first
        // load can take substantially longer than on a quiet machine.
        let hover = try await retryUntilNonNil(attempts: 240, delayNanoseconds: 500_000_000) {
            try await service.hover(snapshot: snapshot, utf8Offset: hoverOffset)
        }
        let stderrLog = await service.serverStderrLog()
        let hoverValue = try XCTUnwrap(
            hover?.contents.value,
            "rust-analyzer returned no hover after project-load retries. stderr:\n\(stderrLog)"
        )
        XCTAssertTrue(hoverValue.contains("greet"), "Expected hover to mention 'greet', got: \(hoverValue)")

        let definitions = try await service.definition(snapshot: snapshot, utf8Offset: hoverOffset)
        XCTAssertFalse(definitions.isEmpty, "Expected at least one real definition location")

        let symbols = try await retryUntilNonEmpty { try await service.documentSymbols(snapshot: snapshot) }
        XCTAssertTrue(symbols.contains { $0.name == "Greeter" }, "Expected a 'Greeter' document symbol, got: \(symbols.map(\.name))")

        let maybeCapabilities = await service.capabilities()
        let capabilities = try XCTUnwrap(maybeCapabilities)
        if capabilities.typeDefinitionProvider?.isEnabled == true {
            // `typeDefinition` at a function's own name has no
            // meaningful target in Rust (it applies to a value's type,
            // not a function declaration) — this only asserts the real
            // server answers without throwing, not that it is non-empty.
            _ = try await service.typeDefinition(snapshot: snapshot, utf8Offset: hoverOffset)
        }
        if capabilities.callHierarchyProvider?.isEnabled == true {
            let items = try await retryUntilNonEmpty { try await service.prepareCallHierarchy(snapshot: snapshot, utf8Offset: hoverOffset) }
            if let item = items.first {
                _ = try await service.callHierarchyIncomingCalls(item: item)
                _ = try await service.callHierarchyOutgoingCalls(item: item)
            }
        }

        try await service.didClose(url: fileURL)

        let finalChecksum = try Data(contentsOf: fileURL)
        XCTAssertEqual(originalChecksum, finalChecksum, "Kod must never modify a workspace file via LSP operations")
    }
}
