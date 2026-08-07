import Foundation

/// The result of attempting to decode persisted Kod metadata (window/split
/// layout, imported themes, font settings, and similar externally-stored
/// state — SPEC 11.7/15). Distinguishing `.absent` from `.corrupted` is the
/// whole point: a caller that only sees `nil` on decode failure cannot tell
/// "there is no saved state yet" (fall back to defaults, nothing wrong)
/// apart from "there *was* saved state and it's corrupt" (SPEC 15: this
/// must be quarantined and rebuilt, and — being an explicit failure path —
/// should be visible rather than silently indistinguishable from a fresh
/// install).
public enum CorruptStateOutcome<Value: Sendable>: Sendable {
    case restored(Value)
    case absent
    case quarantined(reason: String)
}

/// One quarantined (corrupt, undecodable) blob of metadata, kept around
/// only for diagnosis (e.g. inclusion in a support bundle) — never used as
/// a second attempt at recovery, and never repository content (SPEC 15:
/// "repository contents are never used as recovery storage").
public struct QuarantinedRecord: Sendable, Equatable, Codable {
    public let key: String
    public let reason: String
    public let quarantinedAt: Date
    public let byteCount: Int

    public init(key: String, reason: String, quarantinedAt: Date, byteCount: Int) {
        self.key = key
        self.reason = reason
        self.quarantinedAt = quarantinedAt
        self.byteCount = byteCount
    }
}

/// Decodes `UserDefaults`-backed JSON metadata with quarantine-and-rebuild
/// semantics (SPEC 15): a decode failure never leaves the corrupt bytes in
/// place to fail again on every future launch. Instead, the corrupt data is
/// (a) removed from its live key so the subsystem can rebuild fresh
/// defaults immediately, and (b) recorded — key, reason, size, and
/// timestamp only, never the corrupt bytes themselves, since arbitrarily
/// corrupt bytes could themselves contain fragments of previously-written
/// sensitive metadata — in a bounded quarantine ledger for diagnosis.
@MainActor
public final class CorruptStateQuarantine {
    private let defaults: UserDefaults
    private let ledgerKey = "kod.diagnostics.quarantine-ledger"
    private let maxLedgerEntries = 200

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Attempts to decode `type` from the JSON stored at `key`. On success,
    /// returns `.restored`. If nothing is stored, returns `.absent`. If
    /// something is stored but fails to decode, removes it from `key`
    /// (so callers can immediately persist fresh defaults there without
    /// the corrupt bytes resurfacing), appends a `QuarantinedRecord` to the
    /// bounded ledger, and returns `.quarantined(reason:)`.
    public func decode<Value: Decodable & Sendable>(
        _ type: Value.Type,
        forKey key: String
    ) -> CorruptStateOutcome<Value> {
        guard let data = defaults.data(forKey: key) else {
            return .absent
        }

        do {
            let value = try JSONDecoder().decode(Value.self, from: data)
            return .restored(value)
        } catch {
            let reason = String(describing: error)
            defaults.removeObject(forKey: key)
            appendLedgerEntry(
                QuarantinedRecord(
                    key: key,
                    reason: reason,
                    quarantinedAt: Date(),
                    byteCount: data.count
                )
            )
            return .quarantined(reason: reason)
        }
    }

    public func ledger() -> [QuarantinedRecord] {
        guard let data = defaults.data(forKey: ledgerKey),
              let records = try? JSONDecoder().decode([QuarantinedRecord].self, from: data) else {
            return []
        }
        return records
    }

    public func clearLedger() {
        defaults.removeObject(forKey: ledgerKey)
    }

    private func appendLedgerEntry(_ record: QuarantinedRecord) {
        var records = ledger()
        records.append(record)
        if records.count > maxLedgerEntries {
            records.removeFirst(records.count - maxLedgerEntries)
        }
        guard let data = try? JSONEncoder().encode(records) else {
            // The ledger itself is developer-controlled `Codable` data
            // (no user content beyond a redaction-safe `reason` string);
            // an encode failure here would be a genuine programming bug.
            // The ledger is diagnostics-only, so failing to append one
            // entry must never block quarantine-and-rebuild of the
            // caller's real metadata, which has already succeeded above.
            return
        }
        defaults.set(data, forKey: ledgerKey)
    }
}
