import Foundation
import XCTest
@testable import LanguageClient

/// Publish sequencing, freshness, routing policy and pull result-ID
/// bookkeeping, exercised directly — the races these rules exist to
/// prevent are otherwise only observable through timing.
final class LanguageDiagnosticsCoordinatorTests: XCTestCase {
    private let fileURL = URL(fileURLWithPath: "/tmp/kod-diagnostics/File.ts")
    private let otherURL = URL(fileURLWithPath: "/tmp/kod-diagnostics/Other.ts")

    func testRoutingSendsUnopenedFilesToTheRawStoreOnly() {
        XCTAssertEqual(
            LanguageDiagnosticsCoordinator.routing(isDocumentOpen: false),
            .rawOnly
        )
        XCTAssertEqual(
            LanguageDiagnosticsCoordinator.routing(isDocumentOpen: true),
            .rawAndNormalized
        )
    }

    /// The core race: a slow normalization that started first must not
    /// publish after a newer one claimed the slot.
    func testANewerPublishInvalidatesAnOlderInFlightOne() {
        var coordinator = LanguageDiagnosticsCoordinator()
        let first = coordinator.beginPublish(for: fileURL)
        let second = coordinator.beginPublish(for: fileURL)

        XCTAssertFalse(coordinator.isCurrent(first))
        XCTAssertTrue(coordinator.isCurrent(second))
    }

    func testPublishSlotsAreTrackedPerURL() {
        var coordinator = LanguageDiagnosticsCoordinator()
        let file = coordinator.beginPublish(for: fileURL)
        _ = coordinator.beginPublish(for: otherURL)

        XCTAssertTrue(
            coordinator.isCurrent(file),
            "A publish for another file must not invalidate this one"
        )
    }

    /// A `didChange`, a close, or a restart clears markers and blocks
    /// re-normalizing already-stored wire diagnostics until the server
    /// publishes again for the live snapshot.
    func testInvalidationBlocksStoredNormalizationUntilAFreshPublish() {
        var coordinator = LanguageDiagnosticsCoordinator()
        XCTAssertTrue(coordinator.allowsStoredNormalization(for: fileURL))

        coordinator.invalidate(url: fileURL)
        XCTAssertFalse(coordinator.allowsStoredNormalization(for: fileURL))

        let ticket = coordinator.beginPublish(for: fileURL)
        XCTAssertFalse(
            coordinator.allowsStoredNormalization(for: fileURL),
            "Claiming a slot is not delivery"
        )
        coordinator.completePublish(ticket)
        XCTAssertTrue(coordinator.allowsStoredNormalization(for: fileURL))
    }

    func testInvalidationSupersedesAnInFlightPublish() {
        var coordinator = LanguageDiagnosticsCoordinator()
        let inFlight = coordinator.beginPublish(for: fileURL)
        coordinator.invalidate(url: fileURL)

        XCTAssertFalse(
            coordinator.isCurrent(inFlight),
            "A close/change during normalization must win"
        )
    }

    func testBulkInvalidationReportsEveryAffectedURL() {
        var coordinator = LanguageDiagnosticsCoordinator()
        let cleared = coordinator.invalidate(urls: [fileURL, otherURL])
        XCTAssertEqual(Set(cleared), Set([fileURL, otherURL]))
        XCTAssertFalse(coordinator.allowsStoredNormalization(for: fileURL))
        XCTAssertFalse(coordinator.allowsStoredNormalization(for: otherURL))
    }

    func testSequenceNumbersAdvanceMonotonicallyPerURL() {
        var coordinator = LanguageDiagnosticsCoordinator()
        XCTAssertEqual(coordinator.currentSequence(for: fileURL), 0)
        _ = coordinator.beginPublish(for: fileURL)
        XCTAssertEqual(coordinator.currentSequence(for: fileURL), 1)
        coordinator.invalidate(url: fileURL)
        XCTAssertEqual(coordinator.currentSequence(for: fileURL), 2)
    }

    // MARK: - Pull result IDs

    func testResultIDsAreRecordedInAStableOrder() {
        var coordinator = LanguageDiagnosticsCoordinator()
        coordinator.recordResultID("b", kind: .full, for: otherURL)
        coordinator.recordResultID("a", kind: .full, for: fileURL)

        let previous = coordinator.previousResultIDs
        XCTAssertEqual(previous.map(\.value), ["a", "b"])
        XCTAssertEqual(
            previous.map(\.uri.stringValue),
            previous.map(\.uri.stringValue).sorted()
        )
    }

    func testAFullReportWithoutAResultIDClearsTheStoredOne() {
        var coordinator = LanguageDiagnosticsCoordinator()
        coordinator.recordResultID("a", kind: .full, for: fileURL)
        coordinator.recordResultID(nil, kind: .full, for: fileURL)
        XCTAssertTrue(coordinator.previousResultIDs.isEmpty)
    }

    func testAnUnchangedReportWithoutAResultIDKeepsTheStoredOne() {
        var coordinator = LanguageDiagnosticsCoordinator()
        coordinator.recordResultID("a", kind: .full, for: fileURL)
        coordinator.recordResultID(nil, kind: .unchanged, for: fileURL)
        XCTAssertEqual(coordinator.previousResultIDs.map(\.value), ["a"])
    }

    /// A relaunched server's result IDs describe a process that no longer
    /// exists, so a restart drops them all.
    func testResetDropsEveryResultID() {
        var coordinator = LanguageDiagnosticsCoordinator()
        coordinator.recordResultID("a", kind: .full, for: fileURL)
        coordinator.recordResultID("b", kind: .full, for: otherURL)
        coordinator.resetResultIDs()
        XCTAssertEqual(coordinator.trackedResultIDCount, 0)
        XCTAssertTrue(coordinator.previousResultIDs.isEmpty)
    }
}
