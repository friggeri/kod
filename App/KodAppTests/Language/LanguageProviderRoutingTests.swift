import DiagnosticsCore
import LanguageAdapters
import LanguageClient
import SettingsCore
import SourceModel
import WorkspaceCore
import XCTest
@testable import Kod

/// Headless coverage for `MultiLanguageServicesCoordinator`'s
/// provider-ID routing (SPEC 6.1/6.3). No language server process is
/// launched: these assertions are about *where* a cross-file result is
/// routed and *which* encoding converts it, which used to be inferred
/// from the result's target URL.
@MainActor
final class LanguageProviderRoutingTests: XCTestCase {
    private func makeTrustedIdentity() throws -> (WorkspaceIdentity, WorkspaceTrustStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let identity = try WorkspaceIdentity(root: root)
        let store = WorkspaceTrustStore(
            repository: CodableSettingsRepository(
                store: InMemorySettingsKeyValueStore()
            )
        )
        try store.trust(identity)
        return (identity, store)
    }

    private func makeRegistry() throws -> LanguageProfileRegistry {
        return LanguageProfileRegistry(
            store: try LanguageProfileStore(
                repository: CodableSettingsRepository(
                    store: InMemorySettingsKeyValueStore()
                )
            )
        )
    }

    private func makeCoordinator() throws -> MultiLanguageServicesCoordinator {
        let (identity, store) = try makeTrustedIdentity()
        return MultiLanguageServicesCoordinator(
            identity: identity,
            trustStore: store,
            profileRegistry: try makeRegistry(),
            overrideStore: try KodAppTestEnvironment.makeOverrideStore(in: self),
            diagnosticsLog: BoundedEventLog(),
            diagnosticsStore: WorkspaceDiagnosticsStore()
        )
    }

    private func makeItem(
        binding: LanguageProviderBinding,
        url: URL
    ) -> ValidatedHierarchyItem {
        ValidatedHierarchyItem(
            provider: binding,
            name: "greet",
            kind: .function,
            detail: nil,
            url: url,
            range: LSPRange(
                start: LSPPosition(line: 0, character: 0),
                end: LSPPosition(line: 0, character: 4)
            ),
            selectionRange: LSPRange(
                start: LSPPosition(line: 0, character: 0),
                end: LSPPosition(line: 0, character: 4)
            ),
            data: .string("opaque-server-state")
        )
    }

    func testNoProviderIsRegisteredBeforeAnyServiceStarts() throws {
        let coordinator = try makeCoordinator()
        XCTAssertNil(coordinator.providerID(forProfileIdentifier: "swift"))
        XCTAssertNil(coordinator.providerID(forProfileIdentifier: "typescript"))
    }

    /// An expansion whose provider is gone (stopped, replaced, or trust
    /// revoked) fails with a typed error instead of being rerouted to
    /// whichever service claims the item's file.
    func testHierarchyFollowUpForAnAbsentProviderThrowsProviderUnavailable() async throws {
        let coordinator = try makeCoordinator()
        let providerID = LanguageProviderID(profileIdentifier: "swift")
        let binding = LanguageProviderBinding(
            providerID: providerID,
            generation: 2,
            positionEncoding: .utf8
        )
        let item = makeItem(
            binding: binding,
            url: URL(fileURLWithPath: "/workspace/Sources/Foo.swift")
        )

        await assertProviderUnavailable(providerID) {
            _ = try await coordinator.callHierarchyIncomingCalls(item: item)
        }
        await assertProviderUnavailable(providerID) {
            _ = try await coordinator.callHierarchyOutgoingCalls(item: item)
        }
        await assertProviderUnavailable(providerID) {
            _ = try await coordinator.typeHierarchySupertypes(item: item)
        }
        await assertProviderUnavailable(providerID) {
            _ = try await coordinator.typeHierarchySubtypes(item: item)
        }
    }

    /// The item's file is a TypeScript file, but the item came from the
    /// Swift provider. Routing must still fail on the *Swift* provider
    /// rather than quietly reaching a TypeScript server.
    func testCrossProfileItemIsNeverRoutedByItsTargetURL() async throws {
        let coordinator = try makeCoordinator()
        let swiftProviderID = LanguageProviderID(profileIdentifier: "swift")
        let item = makeItem(
            binding: LanguageProviderBinding(
                providerID: swiftProviderID,
                generation: 1,
                positionEncoding: .utf8
            ),
            url: URL(fileURLWithPath: "/workspace/Sources/generated.ts")
        )

        await assertProviderUnavailable(swiftProviderID) {
            _ = try await coordinator.callHierarchyIncomingCalls(item: item)
        }
    }

    /// The conversion a bound location gets is the one its provider
    /// negotiated — not the target file's owner, and not the LSP default.
    func testBoundLocationConversionUsesTheOriginatingProvidersEncoding() throws {
        let coordinator = try makeCoordinator()
        let url = URL(fileURLWithPath: "/workspace/Sources/generated.ts")
        let snapshot = SourceSnapshot(text: "éabcd\n", url: url, version: 1)
        let range = LSPRange(
            start: LSPPosition(line: 0, character: 0),
            end: LSPPosition(line: 0, character: 4)
        )
        let utf8Location = LanguageProviderFixtures.location(
            url: url,
            range: range,
            binding: LanguageProviderFixtures.binding(
                providerID: LanguageProviderID(profileIdentifier: "swift"),
                encoding: .utf8
            )
        )
        let utf16Location = LanguageProviderFixtures.location(
            url: url,
            range: range,
            binding: LanguageProviderFixtures.binding(
                providerID: LanguageProviderID(profileIdentifier: "typescript"),
                encoding: .utf16
            )
        )

        XCTAssertEqual(coordinator.utf8Range(for: utf8Location, in: snapshot), 0..<4)
        XCTAssertEqual(coordinator.utf8Range(for: utf16Location, in: snapshot), 0..<5)
    }

    /// The unbound path — published diagnostics, which always describe the
    /// file their own provider reported them for — still falls back to the
    /// LSP default when no service owns the file.
    func testUnboundDiagnosticConversionFallsBackToTheLSPDefaultEncoding() async throws {
        let coordinator = try makeCoordinator()
        let url = URL(fileURLWithPath: "/workspace/Sources/generated.ts")
        let snapshot = SourceSnapshot(text: "éabcd\n", url: url, version: 1)
        let range = LSPRange(
            start: LSPPosition(line: 0, character: 0),
            end: LSPPosition(line: 0, character: 4)
        )

        let converted = await coordinator.utf8Range(for: range, in: snapshot)
        XCTAssertEqual(converted, 0..<5)
    }

    private func assertProviderUnavailable(
        _ providerID: LanguageProviderID,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected providerUnavailable", file: file, line: line)
        } catch let error as LanguageProviderRoutingError {
            XCTAssertEqual(
                error,
                .providerUnavailable(providerID),
                file: file,
                line: line
            )
        } catch {
            XCTFail("Expected providerUnavailable, got \(error)", file: file, line: line)
        }
    }
}
