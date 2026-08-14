import Foundation
import SourceModel
import XCTest
@testable import LanguageClient

/// Pure coverage for provider-bound result identity: the encoding a
/// cross-file result is converted with must come from the provider that
/// produced it, and a bound handle must only ever route back to that same
/// provider instance. No process is launched here — these are the exact
/// decisions that used to be made by looking a service up from the
/// result's target URL.
final class LanguageProviderBindingTests: XCTestCase {
    private let range = LSPRange(
        start: LSPPosition(line: 0, character: 0),
        end: LSPPosition(line: 0, character: 4)
    )

    /// "é" is one UTF-16 code unit but two UTF-8 bytes, so the same wire
    /// range resolves to a different byte range under each encoding.
    private func makeSnapshot() -> SourceSnapshot {
        SourceSnapshot(
            text: "éabcd\n",
            url: URL(fileURLWithPath: "/workspace/Sources/Target.ts"),
            version: 1
        )
    }

    func testBindingConvertsRangesWithItsOwnNegotiatedEncoding() {
        let snapshot = makeSnapshot()
        let utf8Provider = LanguageProviderBinding(
            providerID: LanguageProviderID(profileIdentifier: "swift"),
            generation: 1,
            positionEncoding: .utf8
        )
        let utf16Provider = LanguageProviderBinding(
            providerID: LanguageProviderID(profileIdentifier: "typescript"),
            generation: 1,
            positionEncoding: .utf16
        )

        XCTAssertEqual(utf8Provider.utf8Range(for: range, in: snapshot), 0..<4)
        XCTAssertEqual(utf16Provider.utf8Range(for: range, in: snapshot), 0..<5)
    }

    /// A Swift server can legitimately return a definition inside a file
    /// whose own profile is TypeScript. The conversion must follow the
    /// Swift provider's encoding, not the target file's owner.
    func testCrossProfileTargetUsesTheOriginatingProvidersEncoding() {
        let snapshot = makeSnapshot()
        let originating = LanguageProviderBinding(
            providerID: LanguageProviderID(profileIdentifier: "swift"),
            generation: 3,
            positionEncoding: .utf8
        )
        let targetFileOwner = LanguageProviderBinding(
            providerID: LanguageProviderID(profileIdentifier: "typescript"),
            generation: 1,
            positionEncoding: .utf16
        )
        let target = NavigationTarget(
            provider: originating,
            url: snapshot.url,
            range: range
        )

        XCTAssertEqual(target.location.utf8Range(in: snapshot), 0..<4)
        XCTAssertNotEqual(
            target.location.utf8Range(in: snapshot),
            targetFileOwner.utf8Range(for: range, in: snapshot),
            "Routing by target URL would have converted with the wrong encoding"
        )
    }

    func testHierarchyItemExposesBothItsFullAndSelectionLocation() {
        let binding = LanguageProviderBinding(
            providerID: LanguageProviderID(profileIdentifier: "swift"),
            generation: 2,
            positionEncoding: .utf8
        )
        let selectionRange = LSPRange(
            start: LSPPosition(line: 0, character: 0),
            end: LSPPosition(line: 0, character: 2)
        )
        let item = ValidatedHierarchyItem(
            provider: binding,
            name: "greet",
            kind: .function,
            detail: nil,
            url: URL(fileURLWithPath: "/workspace/Sources/Foo.swift"),
            range: range,
            selectionRange: selectionRange,
            data: .string("opaque")
        )

        XCTAssertEqual(item.location.range, range)
        XCTAssertEqual(item.selectionLocation.range, selectionRange)
        XCTAssertEqual(item.selectionLocation.provider, binding)
        XCTAssertEqual(item.data, .string("opaque"))
    }

    // MARK: - Routing

    func testRouterReturnsTheProducingServiceForABoundResult() throws {
        var router = LanguageProviderRouter<String>()
        let swift = LanguageProviderID(profileIdentifier: "swift")
        let typescript = LanguageProviderID(profileIdentifier: "typescript")
        router.register("swift-service", for: swift)
        router.register("typescript-service", for: typescript)

        let binding = LanguageProviderBinding(
            providerID: swift,
            generation: 1,
            positionEncoding: .utf8
        )
        XCTAssertEqual(try router.service(for: binding), "swift-service")
    }

    func testRouterThrowsForAProviderThatIsNoLongerRegistered() {
        var router = LanguageProviderRouter<String>()
        let swift = LanguageProviderID(profileIdentifier: "swift")
        router.register("swift-service", for: swift)
        router.unregister(swift)

        let binding = LanguageProviderBinding(
            providerID: swift,
            generation: 1,
            positionEncoding: .utf8
        )
        XCTAssertThrowsError(try router.service(for: binding)) { error in
            XCTAssertEqual(
                error as? LanguageProviderRoutingError,
                .providerUnavailable(swift)
            )
        }
    }

    /// Replacing a profile's service mints a new provider identity, so
    /// handles from the discarded one stop routing instead of silently
    /// reaching its successor.
    func testReplacingAProfilesServiceInvalidatesPriorHandles() {
        var router = LanguageProviderRouter<String>()
        let original = LanguageProviderID(profileIdentifier: "swift")
        let replacement = LanguageProviderID(profileIdentifier: "swift")
        router.register("first", for: original)
        router.unregister(original)
        router.register("second", for: replacement)

        let staleBinding = LanguageProviderBinding(
            providerID: original,
            generation: 1,
            positionEncoding: .utf8
        )
        XCTAssertThrowsError(try router.service(for: staleBinding))
        XCTAssertEqual(
            try? router.service(
                for: LanguageProviderBinding(
                    providerID: replacement,
                    generation: 1,
                    positionEncoding: .utf8
                )
            ),
            "second"
        )
        XCTAssertNotEqual(original, replacement)
        XCTAssertEqual(original.profileIdentifier, replacement.profileIdentifier)
    }
}
