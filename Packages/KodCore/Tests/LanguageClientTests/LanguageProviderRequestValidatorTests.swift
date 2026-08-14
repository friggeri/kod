import Foundation
import SourceModel
import XCTest
@testable import LanguageClient

/// A stand-in for the connection object a request was issued to. The
/// validator only ever compares identity, so a plain class is enough to
/// exercise every rule.
private final class StubConnection {}

/// Provider/generation currency rules, exercised without a live server:
/// these are the checks that keep opaque hierarchy `data` and
/// encoding-specific ranges from reaching the wrong server process.
final class LanguageProviderRequestValidatorTests: XCTestCase {
    private let providerID = LanguageProviderID(profileIdentifier: "typescript")

    private func binding(
        _ providerID: LanguageProviderID,
        generation: Int,
        encoding: SourcePositionEncoding = .utf16
    ) -> LanguageProviderBinding {
        LanguageProviderBinding(
            providerID: providerID,
            generation: generation,
            positionEncoding: encoding
        )
    }

    func testBindingCarriesTheProviderGenerationAndEncoding() {
        let validator = LanguageProviderRequestValidator(providerID: providerID)
        let binding = validator.binding(generation: 3, positionEncoding: .utf8)

        XCTAssertEqual(binding.providerID, providerID)
        XCTAssertEqual(binding.generation, 3)
        XCTAssertEqual(binding.positionEncoding, .utf8)
    }

    func testAHandleFromAnotherProviderIsRejected() {
        let validator = LanguageProviderRequestValidator(providerID: providerID)
        let foreign = LanguageProviderID(profileIdentifier: "swift")

        XCTAssertThrowsError(
            try validator.requireCurrentProvider(
                binding(foreign, generation: 1),
                currentGeneration: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? LanguageProviderRoutingError,
                .providerMismatch(expected: providerID, actual: foreign)
            )
        }
    }

    /// A handle produced before a restart names a dead server process:
    /// its opaque data means nothing to the successor.
    func testAHandleFromASupersededGenerationIsRejected() {
        let validator = LanguageProviderRequestValidator(providerID: providerID)

        XCTAssertThrowsError(
            try validator.requireCurrentProvider(
                binding(providerID, generation: 1),
                currentGeneration: 2
            )
        ) { error in
            XCTAssertEqual(
                error as? LanguageProviderRoutingError,
                .staleProviderResult(
                    providerID: providerID,
                    resultGeneration: 1,
                    currentGeneration: 2
                )
            )
        }
    }

    func testACurrentHandleIsAccepted() {
        let validator = LanguageProviderRequestValidator(providerID: providerID)
        XCTAssertNoThrow(
            try validator.requireCurrentProvider(
                binding(providerID, generation: 4),
                currentGeneration: 4
            )
        )
    }

    /// The post-response check: the generation may still match while the
    /// connection object itself has been replaced.
    func testAResponseFromAReplacedConnectionIsRejected() {
        let validator = LanguageProviderRequestValidator(providerID: providerID)
        let issued = StubConnection()
        let request = LanguageProviderRequest(
            connection: issued,
            binding: binding(providerID, generation: 2)
        )

        XCTAssertNoThrow(
            try validator.requireCurrent(
                request,
                currentGeneration: 2,
                currentConnection: issued
            )
        )
        XCTAssertThrowsError(
            try validator.requireCurrent(
                request,
                currentGeneration: 2,
                currentConnection: StubConnection()
            )
        )
        XCTAssertThrowsError(
            try validator.requireCurrent(
                request,
                currentGeneration: 2,
                currentConnection: nil
            ),
            "A response that arrives after the service stopped is stale"
        )
        XCTAssertThrowsError(
            try validator.requireCurrent(
                request,
                currentGeneration: 3,
                currentConnection: issued
            )
        )
    }

    // MARK: - Provider-bound result construction

    func testNavigationTargetsRequireAFileURIAndAStructurallyValidRange() {
        let bound = binding(providerID, generation: 1)
        let valid = LSPLocation(
            uri: DocumentURI(fileURL: URL(fileURLWithPath: "/tmp/kod/Target.ts")),
            range: LSPRange(
                start: LSPPosition(line: 1, character: 0),
                end: LSPPosition(line: 1, character: 4)
            )
        )
        XCTAssertEqual(
            ProviderBoundResultBuilder.navigationTarget(valid, binding: bound)?.provider,
            bound
        )

        let nonFile = LSPLocation(
            uri: DocumentURI(stringValue: "https://example.com/Target.ts"),
            range: valid.range
        )
        XCTAssertNil(
            ProviderBoundResultBuilder.navigationTarget(nonFile, binding: bound)
        )

        let inverted = LSPLocation(
            uri: valid.uri,
            range: LSPRange(
                start: LSPPosition(line: 4, character: 0),
                end: LSPPosition(line: 1, character: 0)
            )
        )
        XCTAssertNil(
            ProviderBoundResultBuilder.navigationTarget(inverted, binding: bound)
        )
    }

    /// Opaque hierarchy `data` must survive a round trip completely
    /// unmodified, since only the producing server can interpret it.
    func testHierarchyItemsRoundTripOpaqueDataUnmodified() throws {
        let bound = binding(providerID, generation: 5)
        let opaque = JSONValue.object([
            "usr": .string("s:4Kod7GreeterV"),
            "index": .number(3)
        ])
        let range = LSPRange(
            start: LSPPosition(line: 0, character: 0),
            end: LSPPosition(line: 0, character: 7)
        )
        let wire = CallHierarchyItem(
            name: "Greeter",
            kind: .function,
            detail: nil,
            uri: DocumentURI(fileURL: URL(fileURLWithPath: "/tmp/kod/Greeter.ts")),
            range: range,
            selectionRange: range,
            data: opaque
        )

        let validated = try XCTUnwrap(
            ProviderBoundResultBuilder.hierarchyItem(wire, binding: bound)
        )
        XCTAssertEqual(validated.provider, bound)
        XCTAssertEqual(validated.data, opaque)

        let roundTripped = ProviderBoundResultBuilder.wireCallHierarchyItem(validated)
        XCTAssertEqual(roundTripped.data, opaque)
        XCTAssertEqual(roundTripped.uri, wire.uri)

        let asTypeHierarchy = ProviderBoundResultBuilder.wireTypeHierarchyItem(validated)
        XCTAssertEqual(asTypeHierarchy.data, opaque)
    }

    func testHierarchyItemsWithInvalidRangesAreDiscarded() {
        let bound = binding(providerID, generation: 1)
        let valid = LSPRange(
            start: LSPPosition(line: 0, character: 0),
            end: LSPPosition(line: 0, character: 1)
        )
        let invalid = LSPRange(
            start: LSPPosition(line: 0, character: -1),
            end: LSPPosition(line: 0, character: 1)
        )
        let item = CallHierarchyItem(
            name: "Greeter",
            kind: .function,
            detail: nil,
            uri: DocumentURI(fileURL: URL(fileURLWithPath: "/tmp/kod/Greeter.ts")),
            range: valid,
            selectionRange: invalid,
            data: nil
        )
        XCTAssertNil(ProviderBoundResultBuilder.hierarchyItem(item, binding: bound))
    }
}
