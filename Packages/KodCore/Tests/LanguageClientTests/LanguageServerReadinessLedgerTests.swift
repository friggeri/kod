import Foundation
import XCTest
@testable import LanguageClient

/// The start/restart/replay decisions behind SPEC 6.2, exercised without
/// launching (or crashing) a real server process.
final class LanguageServerReadinessLedgerTests: XCTestCase {
    private let fileURL = URL(fileURLWithPath: "/tmp/kod-readiness/File.ts")

    func testFirstLaunchForwardsStartingThenReady() {
        var ledger = LanguageServerReadinessLedger()
        XCTAssertEqual(ledger.transition(for: .starting), .forward(.starting))
        XCTAssertEqual(ledger.transition(for: .ready), .firstReady)
        XCTAssertTrue(ledger.didCompleteFirstReady)
    }

    /// A crash/auto-restart cycle inside one connection: the relaunch is
    /// visible, but `.ready` is withheld until documents are replayed.
    func testRelaunchWithholdsReadyUntilDocumentsAreReplayed() {
        var ledger = LanguageServerReadinessLedger()
        _ = ledger.transition(for: .starting)
        _ = ledger.transition(for: .ready)

        XCTAssertEqual(ledger.transition(for: .starting), .relaunching)
        XCTAssertEqual(
            ledger.transition(for: .ready),
            .replayDocumentsThenReady
        )
    }

    func testAReadyWithoutAPrecedingStartingIsJustForwarded() {
        var ledger = LanguageServerReadinessLedger()
        XCTAssertEqual(
            ledger.transition(for: .ready),
            .forward(.ready),
            "Only a connection that announced .starting is awaiting readiness"
        )
        XCTAssertFalse(ledger.didCompleteFirstReady)
    }

    func testNonReadinessStatesAreForwardedUnchanged() {
        var ledger = LanguageServerReadinessLedger()
        XCTAssertEqual(
            ledger.transition(for: .missing(reason: "not installed")),
            .forward(.missing(reason: "not installed"))
        )
        XCTAssertEqual(
            ledger.transition(for: .crashed(reason: "signal 9")),
            .forward(.crashed(reason: "signal 9"))
        )
    }

    func testReplayOutcomesAreRecorded() {
        var ledger = LanguageServerReadinessLedger()
        let failures = [
            LanguageDocumentReplayFailure(
                url: fileURL,
                reason: .notConnected,
                attempts: 0
            )
        ]
        ledger.markReplayFailed(failures)
        XCTAssertEqual(ledger.replayFailures, failures)

        ledger.markReplaySucceeded()
        XCTAssertTrue(
            ledger.replayFailures.isEmpty,
            "A successful replay clears the previous failures"
        )
        XCTAssertTrue(ledger.didCompleteFirstReady)
    }

    func testOnlyOneRestartRunsAtATime() {
        var ledger = LanguageServerReadinessLedger()
        XCTAssertTrue(ledger.beginRestart())
        XCTAssertFalse(
            ledger.beginRestart(),
            "A concurrent restart is a no-op, not a second shutdown"
        )
        ledger.endRestart()
        XCTAssertTrue(ledger.beginRestart())
    }

    func testStopIsIdempotentAndStartReopensTheService() {
        var ledger = LanguageServerReadinessLedger()
        XCTAssertTrue(ledger.hasStopped, "A fresh service has not started yet")

        ledger.markStarted()
        XCTAssertFalse(ledger.hasStopped)

        _ = ledger.transition(for: .starting)
        _ = ledger.transition(for: .ready)
        ledger.markStopping()
        ledger.markStopped()
        XCTAssertTrue(ledger.hasStopped)
        XCTAssertFalse(ledger.didCompleteFirstReady)
        XCTAssertFalse(ledger.isAwaitingConnectionReady)

        ledger.markStarted()
        XCTAssertFalse(ledger.hasStopped)
    }

    /// An explicit restart discards per-connection readiness, so the next
    /// `.ready` is a first launch again rather than a replay.
    func testResetForRelaunchMakesTheNextReadyAFirstReady() {
        var ledger = LanguageServerReadinessLedger()
        _ = ledger.transition(for: .starting)
        _ = ledger.transition(for: .ready)
        ledger.markReplayFailed([
            LanguageDocumentReplayFailure(
                url: fileURL,
                reason: .notConnected,
                attempts: 1
            )
        ])

        ledger.resetForRelaunch()
        XCTAssertTrue(ledger.replayFailures.isEmpty)
        XCTAssertEqual(ledger.transition(for: .starting), .forward(.starting))
        XCTAssertEqual(ledger.transition(for: .ready), .firstReady)
    }

    func testReplayFailureReasonIsBoundedAndContentFree() {
        let failures = (0..<10).map { index in
            LanguageDocumentReplayFailure(
                url: URL(fileURLWithPath: "/tmp/kod-readiness/File\(index).ts"),
                reason: .notificationFailed("write failed"),
                attempts: 2
            )
        }
        let reason = LanguageServerReadinessLedger.replayFailureReason(failures)

        XCTAssertTrue(reason.contains("File0.ts"))
        XCTAssertTrue(reason.contains("(+7 more)"))
        XCTAssertFalse(reason.contains("File9.ts"))
    }

    func testTransportReasonIsTruncated() {
        struct LongError: Error, CustomStringConvertible {
            let description = String(repeating: "x", count: 500)
        }
        let reason = LanguageServerReadinessLedger.transportReason(LongError())
        XCTAssertEqual(reason.count, 201)
        XCTAssertTrue(reason.hasSuffix("…"))
    }
}
