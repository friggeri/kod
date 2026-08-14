import Foundation

public struct SettingsQuarantineRecord: Sendable, Equatable, Codable {
    public let key: String
    public let reason: String
    public let quarantinedAt: Date
    public let byteCount: Int

    public init(
        key: String,
        reason: String,
        quarantinedAt: Date,
        byteCount: Int
    ) {
        self.key = key
        self.reason = reason
        self.quarantinedAt = quarantinedAt
        self.byteCount = byteCount
    }
}

public enum SettingsQuarantineError: Error, Sendable, Equatable {
    case keyValueStore(SettingsKeyValueStoreError)
    case ledgerCorrupted(key: String, reason: String)
    case unsupportedLedgerVersion(key: String, stored: Int, current: Int)
    case ledgerEncodingFailed(key: String, reason: String)
}

extension SettingsQuarantineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .keyValueStore(let error):
            error.localizedDescription
        case .ledgerCorrupted(let key, let reason):
            "Settings quarantine ledger \(key) is corrupt: \(reason)"
        case .unsupportedLedgerVersion(let key, let stored, let current):
            "Settings quarantine ledger \(key) has future version \(stored); this build supports \(current)."
        case .ledgerEncodingFailed(let key, let reason):
            "Could not encode settings quarantine ledger \(key): \(reason)"
        }
    }
}

/// Redaction-safe, bounded metadata describing corrupt settings values. The
/// original bytes are always removed and never copied into the ledger.
public final class SettingsQuarantine: @unchecked Sendable {
    public static let defaultLedgerKey = "kod.diagnostics.quarantine-ledger"

    private let store: any SettingsKeyValueStore
    private let ledgerKey: String
    private let maximumRecordCount: Int
    private let maximumLedgerByteCount: Int
    private let maximumKeyByteCount: Int
    private let maximumReasonByteCount: Int
    private let now: @Sendable () -> Date
    private let lock = NSRecursiveLock()

    public init(
        store: any SettingsKeyValueStore,
        ledgerKey: String = SettingsQuarantine.defaultLedgerKey,
        maximumRecordCount: Int = 200,
        maximumLedgerByteCount: Int = 512 * 1_024,
        maximumKeyByteCount: Int = 512,
        maximumReasonByteCount: Int = 1_000,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.ledgerKey = ledgerKey
        self.maximumRecordCount = max(1, maximumRecordCount)
        self.maximumLedgerByteCount = max(1, maximumLedgerByteCount)
        self.maximumKeyByteCount = max(1, maximumKeyByteCount)
        self.maximumReasonByteCount = max(1, maximumReasonByteCount)
        self.now = now
    }

    public func records(
    ) throws(SettingsQuarantineError) -> [SettingsQuarantineRecord] {
        lock.lock()
        defer { lock.unlock() }
        let storedValue = try readStoredLedger()
        guard let storedValue else {
            return []
        }
        switch decodeLedger(storedValue) {
        case .success(let records):
            return records
                .suffix(maximumRecordCount)
                .map(boundedRecord)
        case .failure(.corrupt(let reason)):
            throw .ledgerCorrupted(key: ledgerKey, reason: reason)
        case .failure(.unsupportedVersion(let version)):
            throw .unsupportedLedgerVersion(
                key: ledgerKey,
                stored: version,
                current: 1
            )
        }
    }

    public func clear() throws(SettingsQuarantineError) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try store.removeValue(forKey: ledgerKey)
        } catch {
            throw .keyValueStore(error)
        }
    }

    func quarantine(
        _ storedValue: SettingsStoredValue,
        forKey key: String,
        reason: String
    ) throws(SettingsQuarantineError) -> SettingsQuarantineRecord {
        lock.lock()
        defer { lock.unlock() }

        var records: [SettingsQuarantineRecord]
        let storedLedger = try readStoredLedger()
        if let storedLedger {
            switch decodeLedger(storedLedger) {
            case .success(let decoded):
                records = decoded
                    .suffix(maximumRecordCount - 1)
                    .map(boundedRecord)
            case .failure(.corrupt(let reason)):
                records = [
                    makeRecord(
                        key: ledgerKey,
                        reason: "Corrupt quarantine ledger was rebuilt: \(reason)",
                        byteCount: storedLedger.byteCount
                    )
                ]
            case .failure(.unsupportedVersion(let version)):
                throw .unsupportedLedgerVersion(
                    key: ledgerKey,
                    stored: version,
                    current: 1
                )
            }
        } else {
            records = []
        }

        do {
            try store.removeValue(forKey: key)
        } catch {
            throw .keyValueStore(error)
        }

        let record = makeRecord(
            key: key,
            reason: reason,
            byteCount: storedValue.byteCount
        )
        records.append(record)
        if records.count > maximumRecordCount {
            records.removeFirst(records.count - maximumRecordCount)
        }

        var data: Data
        while true {
            data = try encodeLedger(records)
            if data.count <= maximumLedgerByteCount {
                break
            }
            guard records.count > 1 else {
                throw .ledgerEncodingFailed(
                    key: ledgerKey,
                    reason: "The encoded ledger exceeds its byte limit."
                )
            }
            records.removeFirst()
        }
        do {
            try store.setValue(.data(data), forKey: ledgerKey)
        } catch {
            throw .keyValueStore(error)
        }
        return record
    }

    private func readStoredLedger(
    ) throws(SettingsQuarantineError) -> SettingsStoredValue? {
        do {
            return try store.value(forKey: ledgerKey)
        } catch {
            throw .keyValueStore(error)
        }
    }

    private func encodeLedger(
        _ records: [SettingsQuarantineRecord]
    ) throws(SettingsQuarantineError) -> Data {
        let envelope = CodableSettingsEnvelope(version: 1, payload: records)
        let encoded = Result { () -> Data in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(envelope)
        }
        switch encoded {
        case .success(let data):
            return data
        case .failure(let error):
            throw .ledgerEncodingFailed(
                key: ledgerKey,
                reason: String(describing: error)
            )
        }
    }

    private func decodeLedger(
        _ storedValue: SettingsStoredValue
    ) -> Result<[SettingsQuarantineRecord], LedgerDecodeFailure> {
        guard case .data(let data) = storedValue else {
            return .failure(
                .corrupt("The ledger is not stored as data.")
            )
        }
        guard data.count <= maximumLedgerByteCount else {
            return .failure(
                .corrupt("The ledger exceeds its byte limit.")
            )
        }

        struct Header: Decodable {
            let version: Int
        }
        let headerResult = Result {
            try JSONDecoder().decode(Header.self, from: data)
        }
        if case .success(let header) = headerResult {
            guard header.version > 0 else {
                return .failure(
                    .corrupt("The ledger version must be positive.")
                )
            }
            guard header.version <= 1 else {
                return .failure(.unsupportedVersion(header.version))
            }
        }

        let current = Result {
            try JSONDecoder().decode(
                CodableSettingsEnvelope<[SettingsQuarantineRecord]>.self,
                from: data
            )
        }
        if case .success(let envelope) = current, envelope.version == 1 {
            return .success(envelope.payload)
        }

        let legacy = Result {
            try JSONDecoder().decode(
                [SettingsQuarantineRecord].self,
                from: data
            )
        }
        switch legacy {
        case .success(let records):
            return .success(records)
        case .failure(let error):
            return .failure(
                .corrupt(String(describing: error))
            )
        }
    }

    private enum LedgerDecodeFailure: Error {
        case corrupt(String)
        case unsupportedVersion(Int)
    }

    private func makeRecord(
        key: String,
        reason: String,
        byteCount: Int
    ) -> SettingsQuarantineRecord {
        let boundedKey = boundedUTF8(
            key,
            maximumByteCount: maximumKeyByteCount
        )
        let boundedReason = boundedUTF8(
            reason,
            maximumByteCount: maximumReasonByteCount
        )
        return SettingsQuarantineRecord(
            key: boundedKey,
            reason: boundedReason,
            quarantinedAt: now(),
            byteCount: byteCount
        )
    }

    private func boundedRecord(
        _ record: SettingsQuarantineRecord
    ) -> SettingsQuarantineRecord {
        SettingsQuarantineRecord(
            key: boundedUTF8(
                record.key,
                maximumByteCount: maximumKeyByteCount
            ),
            reason: boundedUTF8(
                record.reason,
                maximumByteCount: maximumReasonByteCount
            ),
            quarantinedAt: record.quarantinedAt,
            byteCount: max(0, record.byteCount)
        )
    }

    private func boundedUTF8(
        _ value: String,
        maximumByteCount: Int
    ) -> String {
        guard value.utf8.count > maximumByteCount else {
            return value
        }
        var result = ""
        result.reserveCapacity(maximumByteCount)
        var byteCount = 0
        for scalar in value.unicodeScalars {
            let scalarByteCount = String(scalar).utf8.count
            guard byteCount + scalarByteCount <= maximumByteCount else {
                break
            }
            result.append(contentsOf: String(scalar))
            byteCount += scalarByteCount
        }
        return result
    }
}

private extension SettingsStoredValue {
    var byteCount: Int {
        switch self {
        case .data(let data):
            data.count
        case .string(let string):
            string.utf8.count
        case .boolean:
            MemoryLayout<Bool>.size
        case .integer:
            MemoryLayout<Int64>.size
        case .double:
            MemoryLayout<Double>.size
        case .stringArray(let strings):
            strings.reduce(0) { $0 + $1.utf8.count }
        case .unsupported:
            0
        }
    }
}
