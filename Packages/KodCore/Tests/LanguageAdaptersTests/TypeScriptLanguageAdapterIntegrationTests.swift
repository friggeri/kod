import Foundation
import SourceModel
import WorkspaceCore
import XCTest
@testable import LanguageAdapters
@testable import LanguageClient

/// Real, headless `typescript-language-server` integration tests against
/// a small, checked-in fixture (`Fixtures/TypeScriptFixture`). These
/// launch the actual pinned executable installed by
/// `Scripts/vendor-test-language-servers/setup.sh` — never
/// `FakeLanguageServer` — through the exact same
/// profile-driven service path the app itself uses (with a workspace-scoped executable
/// override standing in for "the user configured/has installed this
/// server", since Kod itself never bundles or manages this
/// installation in this phase). Skips explicitly (never fakes success)
/// if the pinned executable isn't present.
final class TypeScriptLanguageAdapterIntegrationTests: XCTestCase {
    @MainActor
    private func makeService(root: URL) throws -> LanguageWorkspaceService {
        let executableURL = try PinnedTestLanguageServerLocator.typescriptLanguageServer()
        let identity = try WorkspaceIdentity(root: root)
        let suiteName = "TypeScriptLanguageAdapterIntegrationTests.\(UUID().uuidString)"
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
            languageKey: TypeScriptLanguageAdapter.languageKey,
            identity: identity
        )
        return try LanguageProfileServiceFactory.makeService(
            for: DefaultLanguageProfiles.typeScript,
            identity: identity,
            trustStore: trustStore,
            overrideStore: overrideStore
        )
    }

    @MainActor
    func testInitializeHoverDefinitionDocumentSymbolsAndFoldingAgainstRealTypescriptLanguageServer() async throws {
        let root = PinnedTestLanguageServerLocator.fixture("TypeScriptFixture")
        let service: LanguageWorkspaceService
        do {
            service = try makeService(root: root)
        } catch let error as PinnedExecutableMissing {
            throw XCTSkip("\(error)")
        }

        try await service.start()
        addTeardownBlock { await service.stop() }

        let fileURL = root.appendingPathComponent("greeter.ts")
        let originalChecksum = try Data(contentsOf: fileURL)

        let snapshot = try SourceSnapshotLoader().load(url: fileURL, version: 1)
        try await service.didOpen(snapshot)

        let text = snapshot.text
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let hoverLineIndex = try XCTUnwrap(lines.firstIndex { $0.contains("greet(): string") })
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

        let symbols = try await service.documentSymbols(snapshot: snapshot)
        XCTAssertTrue(symbols.contains { $0.name == "Greeter" }, "Expected a 'Greeter' document symbol, got: \(symbols.map(\.name))")

        let maybeCapabilities = await service.capabilities()
        let capabilities = try XCTUnwrap(maybeCapabilities)
        if capabilities.foldingRangeProvider?.isEnabled == true {
            let foldingRanges = try await service.foldingRanges(snapshot: snapshot)
            XCTAssertFalse(foldingRanges.isEmpty, "Expected at least one real folding range for a class body")
        }
        if capabilities.documentHighlightProvider?.isEnabled == true {
            let highlights = try await service.documentHighlights(snapshot: snapshot, utf8Offset: hoverOffset)
            XCTAssertFalse(highlights.isEmpty, "Expected at least one document highlight at 'greet'")
        }
        if capabilities.typeDefinitionProvider?.isEnabled == true {
            let typeDefinitions = try await service.typeDefinition(snapshot: snapshot, utf8Offset: hoverOffset)
            XCTAssertFalse(typeDefinitions.isEmpty, "Expected at least one real type-definition location")
        }
        if capabilities.selectionRangeProvider?.isEnabled == true {
            let selectionRanges = try await service.selectionRanges(snapshot: snapshot, utf8Offsets: [hoverOffset])
            XCTAssertFalse(selectionRanges.isEmpty, "Expected at least one real selection range at 'greet'")
        }
        if capabilities.signatureHelpProvider?.isEnabled == true {
            // Position the request just inside the call parentheses of
            // `makeDefaultGreeter()`'s constructor call site so there is
            // an active signature to report.
            let constructorLineIndex = try XCTUnwrap(lines.firstIndex { $0.contains("new Greeter(") })
            let constructorLine = String(lines[constructorLineIndex])
            let parenIndex = try XCTUnwrap(constructorLine.range(of: "("))
            let parenColumn = constructorLine.distance(from: constructorLine.startIndex, to: parenIndex.upperBound)
            let signatureOffset = try snapshot.utf8Offset(
                for: SourcePosition(line: constructorLineIndex, character: parenColumn),
                encoding: .utf16
            )
            let signatureHelp = try await retryUntilNonNil {
                try await service.signatureHelp(snapshot: snapshot, utf8Offset: signatureOffset)
            }
            XCTAssertFalse((signatureHelp?.signatures ?? []).isEmpty, "Expected at least one real signature at the constructor call site")
        }
        if capabilities.callHierarchyProvider?.isEnabled == true {
            let items = try await retryUntilNonEmpty { try await service.prepareCallHierarchy(snapshot: snapshot, utf8Offset: hoverOffset) }
            if let item = items.first {
                // Both calls must succeed (never throw) against a real
                // server, even if this particular fixture has no actual
                // callers/callees to report.
                _ = try await service.callHierarchyIncomingCalls(item: item)
                _ = try await service.callHierarchyOutgoingCalls(item: item)
            }
        }

        try await service.didClose(url: fileURL)

        let finalChecksum = try Data(contentsOf: fileURL)
        XCTAssertEqual(originalChecksum, finalChecksum, "Kod must never modify a workspace file via LSP operations")
    }
}

/// Retries `operation` a few times with a short delay for a real
/// server's project-load latency (TypeScript's language service needs a
/// moment after `didOpen` before hover resolves against a fresh
/// process).
@MainActor
func retryUntilNonNil<T>(
    attempts: Int = 20,
    delayNanoseconds: UInt64 = 300_000_000,
    _ operation: () async throws -> T?
) async throws -> T? {
    for _ in 0..<attempts {
        do {
            if let value = try await operation() {
                return value
            }
        } catch LanguageClientError.serverError(let error)
            where error.code == JSONRPCErrorCode.contentModified {
            // Real servers can invalidate an in-flight read while their
            // initial project snapshot is still changing.
        }
        try await Task.sleep(nanoseconds: delayNanoseconds)
    }
    return try await operation()
}

/// Same idea as `retryUntilNonNil`, for requests that return an array
/// rather than an optional (e.g. `documentSymbols`, `references`).
@MainActor
func retryUntilNonEmpty<Element>(
    attempts: Int = 20,
    delayNanoseconds: UInt64 = 300_000_000,
    _ operation: () async throws -> [Element]
) async throws -> [Element] {
    var lastResult: [Element] = []
    for _ in 0..<attempts {
        lastResult = try await operation()
        if !lastResult.isEmpty {
            return lastResult
        }
        try await Task.sleep(nanoseconds: delayNanoseconds)
    }
    return lastResult
}
