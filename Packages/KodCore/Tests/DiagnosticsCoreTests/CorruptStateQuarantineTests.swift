import XCTest
@testable import DiagnosticsCore

private struct SampleMetadata: Codable, Equatable, Sendable {
    let value: Int
}

final class CorruptStateQuarantineTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suiteName = "diagnostics-core-quarantine-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @MainActor
    func testAbsentKeyReturnsAbsentNotQuarantined() {
        let defaults = freshDefaults()
        let quarantine = CorruptStateQuarantine(defaults: defaults)

        let outcome = quarantine.decode(SampleMetadata.self, forKey: "missing-key")

        guard case .absent = outcome else {
            return XCTFail("expected .absent, got \(outcome)")
        }
    }

    @MainActor
    func testValidDataDecodesToRestored() {
        let defaults = freshDefaults()
        let quarantine = CorruptStateQuarantine(defaults: defaults)
        let key = "valid-key"
        defaults.set(try! JSONEncoder().encode(SampleMetadata(value: 42)), forKey: key)

        let outcome = quarantine.decode(SampleMetadata.self, forKey: key)

        guard case .restored(let value) = outcome else {
            return XCTFail("expected .restored, got \(outcome)")
        }
        XCTAssertEqual(value, SampleMetadata(value: 42))
    }

    @MainActor
    func testCorruptDataIsQuarantinedAndRemovedFromLiveKeySoItCanRebuild() {
        let defaults = freshDefaults()
        let quarantine = CorruptStateQuarantine(defaults: defaults)
        let key = "corrupt-key"
        defaults.set(Data("not valid json at all {{{".utf8), forKey: key)

        let outcome = quarantine.decode(SampleMetadata.self, forKey: key)

        guard case .quarantined = outcome else {
            return XCTFail("expected .quarantined, got \(outcome)")
        }
        // Rebuild must be possible: the corrupt bytes must no longer be
        // sitting at the live key, so a fresh save immediately succeeds
        // and does not keep re-triggering quarantine on next launch.
        XCTAssertNil(defaults.data(forKey: key))

        let ledger = quarantine.ledger()
        XCTAssertEqual(ledger.count, 1)
        XCTAssertEqual(ledger[0].key, key)
        XCTAssertGreaterThan(ledger[0].byteCount, 0)
    }

    @MainActor
    func testLedgerNeverContainsTheCorruptBytesThemselves() {
        let defaults = freshDefaults()
        let quarantine = CorruptStateQuarantine(defaults: defaults)
        let key = "corrupt-key-2"
        let secretLookingCorruptPayload = "SECRET_MARKER_zzz_not_json"
        defaults.set(Data(secretLookingCorruptPayload.utf8), forKey: key)

        _ = quarantine.decode(SampleMetadata.self, forKey: key)

        let ledgerData = defaults.data(forKey: "kod.diagnostics.quarantine-ledger") ?? Data()
        let ledgerText = String(decoding: ledgerData, as: UTF8.self)
        XCTAssertFalse(ledgerText.contains(secretLookingCorruptPayload))
    }

    @MainActor
    func testLedgerIsBoundedAndDropsOldestEntries() {
        let defaults = freshDefaults()
        let quarantine = CorruptStateQuarantine(defaults: defaults)

        for index in 0..<250 {
            defaults.set(Data("bad-\(index)".utf8), forKey: "key-\(index)")
            _ = quarantine.decode(SampleMetadata.self, forKey: "key-\(index)")
        }

        let ledger = quarantine.ledger()
        XCTAssertLessThanOrEqual(ledger.count, 200)
        XCTAssertEqual(ledger.last?.key, "key-249")
    }

    @MainActor
    func testClearLedgerRemovesAllRecords() {
        let defaults = freshDefaults()
        let quarantine = CorruptStateQuarantine(defaults: defaults)
        defaults.set(Data("bad".utf8), forKey: "k")
        _ = quarantine.decode(SampleMetadata.self, forKey: "k")
        XCTAssertFalse(quarantine.ledger().isEmpty)

        quarantine.clearLedger()

        XCTAssertTrue(quarantine.ledger().isEmpty)
    }
}
