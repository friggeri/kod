import Foundation
import SourceModel
import XCTest
@testable import LanguageClient

/// Direct coverage for the open-document state machine behind SPEC 6.3,
/// with no server, no connection, and no I/O.
final class DocumentSynchronizationLedgerTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/kod-ledger", isDirectory: true)

    private func snapshot(
        _ name: String = "File.ts",
        text: String = "let x = 1\n",
        version: Int
    ) -> SourceSnapshot {
        SourceSnapshot(
            text: text,
            url: root.appendingPathComponent(name),
            version: version
        )
    }

    func testUntrackedDocumentPlansAnOpen() {
        let ledger = DocumentSynchronizationLedger()
        XCTAssertEqual(ledger.plan(for: snapshot(version: 1)), .open)
        XCTAssertTrue(ledger.isEmpty)
    }

    func testIdenticalSnapshotPlansNothing() {
        var ledger = DocumentSynchronizationLedger()
        let first = snapshot(version: 1)
        ledger.recordOpen(first)
        XCTAssertEqual(ledger.plan(for: first), .unchanged)
    }

    func testNewVersionOrNewTextPlansAChange() {
        var ledger = DocumentSynchronizationLedger()
        ledger.recordOpen(snapshot(version: 1))
        XCTAssertEqual(ledger.plan(for: snapshot(version: 2)), .change)
        XCTAssertEqual(
            ledger.plan(for: snapshot(text: "let y = 2\n", version: 1)),
            .change,
            "Same version with different text is still a change"
        )
    }

    /// `/tmp/x` and `/tmp/./x` are the same document: a non-standardized
    /// URL must not create a phantom second entry that would make Kod
    /// send `didOpen` twice for one file.
    func testURLsAreStandardizedBeforeTracking() {
        var ledger = DocumentSynchronizationLedger()
        ledger.recordOpen(snapshot(version: 1))
        let indirect = SourceSnapshot(
            text: "let x = 1\n",
            url: root.appendingPathComponent("./File.ts"),
            version: 1
        )
        XCTAssertEqual(ledger.plan(for: indirect), .unchanged)
        XCTAssertNotNil(ledger.snapshot(for: indirect.url))
    }

    func testRequireTrackedRejectsUnopenedDocuments() {
        var ledger = DocumentSynchronizationLedger()
        let unopened = snapshot(version: 1)
        XCTAssertThrowsError(try ledger.requireTracked(unopened)) { error in
            XCTAssertEqual(
                error as? LanguageWorkspaceServiceError,
                .documentNotOpen(unopened.url)
            )
        }
        ledger.recordOpen(unopened)
        XCTAssertNoThrow(try ledger.requireTracked(unopened))
    }

    func testRequireOpenAndCurrentRejectsSupersededVersions() {
        var ledger = DocumentSynchronizationLedger()
        ledger.recordOpen(snapshot(version: 7))
        let stale = snapshot(version: 6)
        XCTAssertThrowsError(try ledger.requireOpenAndCurrent(stale)) { error in
            XCTAssertEqual(
                error as? LanguageWorkspaceServiceError,
                .staleRequest(url: stale.url, expectedVersion: 7, actualVersion: 6)
            )
        }
    }

    func testRecordChangeReplacesTheTrackedSnapshot() {
        var ledger = DocumentSynchronizationLedger()
        ledger.recordOpen(snapshot(version: 1))
        ledger.recordChange(snapshot(text: "let y = 2\n", version: 2))
        let tracked = ledger.snapshot(for: root.appendingPathComponent("File.ts"))
        XCTAssertEqual(tracked?.version, 2)
        XCTAssertEqual(tracked?.text, "let y = 2\n")
    }

    func testRemoveReportsWhetherItWasATrackedDocument() {
        var ledger = DocumentSynchronizationLedger()
        let opened = snapshot(version: 1)
        ledger.recordOpen(opened)
        XCTAssertEqual(
            ledger.remove(url: opened.url),
            opened.url.standardizedFileURL
        )
        XCTAssertNil(
            ledger.remove(url: opened.url),
            "Closing a document twice must be a no-op"
        )
    }

    func testReportedVersionsAreOnlyCheckedForOpenDocuments() {
        var ledger = DocumentSynchronizationLedger()
        let unopened = root.appendingPathComponent("Unopened.ts")
        XCTAssertTrue(
            ledger.acceptsReportedVersion(3, for: unopened),
            "A file Kod never opened has no client-side version to compare"
        )
        let opened = snapshot(version: 4)
        ledger.recordOpen(opened)
        XCTAssertTrue(ledger.acceptsReportedVersion(4, for: opened.url))
        XCTAssertFalse(ledger.acceptsReportedVersion(3, for: opened.url))
        XCTAssertTrue(
            ledger.acceptsReportedVersion(nil, for: opened.url),
            "An unversioned report is accepted"
        )
    }

    func testIsCurrentRequiresBothVersionAndText() {
        var ledger = DocumentSynchronizationLedger()
        let opened = snapshot(version: 2)
        ledger.recordOpen(opened)
        XCTAssertTrue(ledger.isCurrent(opened))
        XCTAssertFalse(ledger.isCurrent(snapshot(text: "other\n", version: 2)))
        XCTAssertFalse(ledger.isCurrent(snapshot(version: 3)))
    }

    /// Replay order must not depend on dictionary ordering, so a failure
    /// report is reproducible.
    func testSnapshotsAreOrderedByPathForReplay() {
        var ledger = DocumentSynchronizationLedger()
        ledger.recordOpen(snapshot("c.ts", version: 1))
        ledger.recordOpen(snapshot("a.ts", version: 1))
        ledger.recordOpen(snapshot("b.ts", version: 1))
        XCTAssertEqual(
            ledger.snapshotsOrderedByPath.map(\.url.lastPathComponent),
            ["a.ts", "b.ts", "c.ts"]
        )
    }

    func testRemoveAllReturnsEveryTrackedURL() {
        var ledger = DocumentSynchronizationLedger()
        ledger.recordOpen(snapshot("a.ts", version: 1))
        ledger.recordOpen(snapshot("b.ts", version: 1))
        XCTAssertEqual(
            Set(ledger.removeAll()),
            Set([
                root.appendingPathComponent("a.ts"),
                root.appendingPathComponent("b.ts")
            ])
        )
        XCTAssertTrue(ledger.isEmpty)
    }
}
