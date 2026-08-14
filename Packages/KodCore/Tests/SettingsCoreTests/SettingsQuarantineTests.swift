import Foundation
import XCTest
@testable import SettingsCore

private struct QuarantineSample: Codable, Sendable, Equatable {
    let value: Int
}

final class SettingsQuarantineTests: XCTestCase {
    func testMalformedValueIsRemovedAndRecordedWithoutItsBytes() throws {
        let secret = "SECRET_MARKER_not-json"
        let store = InMemorySettingsKeyValueStore(
            initialValues: ["sample": .data(Data(secret.utf8))]
        )
        let quarantine = SettingsQuarantine(
            store: store,
            now: { Date(timeIntervalSince1970: 100) }
        )
        let repository = CodableSettingsRepository(
            store: store,
            quarantine: quarantine
        )
        let setting = legacySetting(key: "sample")

        guard case .quarantined(let record) =
                try repository.read(setting) else {
            return XCTFail("Expected quarantine")
        }

        XCTAssertNil(try store.value(forKey: "sample"))
        XCTAssertEqual(record.key, "sample")
        XCTAssertEqual(record.quarantinedAt, Date(timeIntervalSince1970: 100))
        XCTAssertGreaterThan(record.byteCount, 0)
        XCTAssertEqual(try quarantine.records(), [record])
        guard let ledgerValue = try store.value(
            forKey: SettingsQuarantine.defaultLedgerKey
        ),
              case .data(let ledgerData) = ledgerValue else {
            return XCTFail("Expected ledger data")
        }
        XCTAssertFalse(String(decoding: ledgerData, as: UTF8.self).contains(secret))
    }

    func testLedgerIsBoundedAndDropsOldestRecords() throws {
        let store = InMemorySettingsKeyValueStore()
        let quarantine = SettingsQuarantine(
            store: store,
            maximumRecordCount: 3
        )
        let repository = CodableSettingsRepository(
            store: store,
            quarantine: quarantine
        )

        for index in 0..<5 {
            let key = "sample-\(index)"
            try store.setValue(.data(Data("bad-\(index)".utf8)), forKey: key)
            _ = try repository.read(legacySetting(key: key))
        }

        XCTAssertEqual(
            try quarantine.records().map(\.key),
            ["sample-2", "sample-3", "sample-4"]
        )
    }

    func testRecordKeysAndReasonsAreBounded() throws {
        let key = String(repeating: "k", count: 100)
        let store = InMemorySettingsKeyValueStore(
            initialValues: [key: .data(Data("bad".utf8))]
        )
        let quarantine = SettingsQuarantine(
            store: store,
            maximumKeyByteCount: 8,
            maximumReasonByteCount: 16
        )
        let repository = CodableSettingsRepository(
            store: store,
            quarantine: quarantine
        )

        guard case .quarantined(let record) =
                try repository.read(legacySetting(key: key)) else {
            return XCTFail("Expected quarantine")
        }

        XCTAssertEqual(record.key.utf8.count, 8)
        XCTAssertLessThanOrEqual(record.reason.utf8.count, 16)
    }

    func testEncodedLedgerRespectsByteLimit() throws {
        let store = InMemorySettingsKeyValueStore()
        let quarantine = SettingsQuarantine(
            store: store,
            maximumRecordCount: 100,
            maximumLedgerByteCount: 1_000
        )
        let repository = CodableSettingsRepository(
            store: store,
            quarantine: quarantine
        )
        for index in 0..<30 {
            let key = "bounded-\(index)"
            try store.setValue(.data(Data("bad".utf8)), forKey: key)
            _ = try repository.read(legacySetting(key: key))
        }

        guard let storedLedger = try store.value(
            forKey: SettingsQuarantine.defaultLedgerKey
        ),
              case .data(let ledgerData) = storedLedger else {
            return XCTFail("Expected ledger data")
        }
        XCTAssertLessThanOrEqual(ledgerData.count, 1_000)
        XCTAssertLessThan(try quarantine.records().count, 30)
    }

    func testCorruptLedgerIsRebuiltWithDiagnosticRecord() throws {
        let store = InMemorySettingsKeyValueStore(
            initialValues: [
                SettingsQuarantine.defaultLedgerKey: .data(Data("bad ledger".utf8)),
                "sample": .data(Data("bad sample".utf8))
            ]
        )
        let quarantine = SettingsQuarantine(store: store)
        let repository = CodableSettingsRepository(
            store: store,
            quarantine: quarantine
        )

        _ = try repository.read(legacySetting(key: "sample"))

        let records = try quarantine.records()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(
            records.map(\.key),
            [SettingsQuarantine.defaultLedgerKey, "sample"]
        )
    }

    func testReadingCorruptLedgerThrowsInsteadOfReturningEmptySuccess() throws {
        let store = InMemorySettingsKeyValueStore(
            initialValues: [
                SettingsQuarantine.defaultLedgerKey: .string("not a ledger")
            ]
        )
        let quarantine = SettingsQuarantine(store: store)

        XCTAssertThrowsError(try quarantine.records()) { error in
            guard let quarantineError = error as? SettingsQuarantineError,
                  case .ledgerCorrupted(let key, let reason) =
                    quarantineError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(key, SettingsQuarantine.defaultLedgerKey)
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func testFutureLedgerVersionIsPreserved() throws {
        let data = try JSONEncoder().encode(
            CodableSettingsEnvelope(
                version: 2,
                payload: [
                    SettingsQuarantineRecord(
                        key: "future",
                        reason: "future",
                        quarantinedAt: Date(timeIntervalSince1970: 2),
                        byteCount: 2
                    )
                ]
            )
        )
        let store = InMemorySettingsKeyValueStore(
            initialValues: [
                SettingsQuarantine.defaultLedgerKey: .data(data)
            ]
        )
        let quarantine = SettingsQuarantine(store: store)

        XCTAssertThrowsError(try quarantine.records()) { error in
            XCTAssertEqual(
                error as? SettingsQuarantineError,
                .unsupportedLedgerVersion(
                    key: SettingsQuarantine.defaultLedgerKey,
                    stored: 2,
                    current: 1
                )
            )
        }
        XCTAssertEqual(
            try store.value(
                forKey: SettingsQuarantine.defaultLedgerKey
            ),
            .data(data)
        )
    }

    func testLegacyUnenvelopedLedgerRemainsReadable() throws {
        let existing = SettingsQuarantineRecord(
            key: "legacy",
            reason: "old",
            quarantinedAt: Date(timeIntervalSince1970: 1),
            byteCount: 4
        )
        let store = InMemorySettingsKeyValueStore(
            initialValues: [
                SettingsQuarantine.defaultLedgerKey: .data(
                    try JSONEncoder().encode([existing])
                )
            ]
        )

        XCTAssertEqual(
            try SettingsQuarantine(store: store).records(),
            [existing]
        )
    }

    func testClearRemovesLedger() throws {
        let store = InMemorySettingsKeyValueStore()
        let quarantine = SettingsQuarantine(store: store)
        let repository = CodableSettingsRepository(
            store: store,
            quarantine: quarantine
        )
        try store.setValue(.data(Data("bad".utf8)), forKey: "sample")
        _ = try repository.read(legacySetting(key: "sample"))
        XCTAssertFalse(try quarantine.records().isEmpty)

        try quarantine.clear()

        XCTAssertTrue(try quarantine.records().isEmpty)
    }

    private func legacySetting(
        key: String
    ) -> CodableSetting<QuarantineSample> {
        CodableSetting(
            key: key,
            currentVersion: 1,
            migrations: [
                .unversionedCodable(QuarantineSample.self) { $0 }
            ]
        )
    }
}
