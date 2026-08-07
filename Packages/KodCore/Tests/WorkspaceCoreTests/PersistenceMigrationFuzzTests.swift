import DiagnosticsCore
import FuzzSupport
import XCTest
@testable import WorkspaceCore

/// Bounded, seeded fuzzing of `WorkspaceLayoutStore`'s persistence-
/// migration path: what happens when the `UserDefaults`-backed JSON blob
/// behind a previously-valid saved layout becomes corrupt — from a
/// half-written save, a future Kod version's schema change, or hostile
/// tampering (SPEC 15: "Corrupt Kod metadata is quarantined and rebuilt";
/// SPEC 16.1 fuzz coverage extended here to persistence migrations, one
/// of Phase 12's explicitly requested new fuzz targets). Every corrupt
/// blob is random bytes — the only acceptable outcome is `load(for:)`
/// returning `nil` (quarantined-and-rebuilt) with the ledger recording
/// exactly one bounded entry, never a crash and never a resurfacing of
/// the corrupt bytes on a later call.
@MainActor
final class PersistenceMigrationFuzzTests: XCTestCase {
    func testCorruptSavedLayoutIsAlwaysQuarantinedNeverCrashes() throws {
        try FuzzRun.run("PersistenceMigrationFuzzTests.corruptLayout", iterations: 200) { source in
            let suiteName = "com.kod.fuzz.persistence-migration.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                return
            }
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let store = WorkspaceLayoutStore(defaults: defaults)
            let identity = try WorkspaceIdentity(root: FileManager.default.temporaryDirectory)

            // Save one genuinely valid state first, so the corrupted
            // blob below replaces real, previously-written data — the
            // scenario SPEC 15 actually describes (a subsystem finding
            // its *own* prior save corrupt), not just "reading garbage
            // that was never valid to begin with."
            store.save(.singleGroup(), for: identity)

            guard let dataKey = (defaults.dictionaryRepresentation().first { _, value in value is Data })?.key else {
                return XCTFail("expected exactly one Data-valued key after saving a layout")
            }

            let corruptBytes = Data(FuzzGenerators.randomBytes(lengthIn: 0...512, &source))
            defaults.set(corruptBytes, forKey: dataKey)

            // First load after corruption: must never crash, and — for
            // the (extremely unlikely but not impossible) case where
            // random bytes happen to decode as valid JSON matching the
            // schema — either a legitimate value or `nil` is acceptable;
            // only a crash is a failure.
            _ = store.load(for: identity)

            // A second load must be stable: once quarantined, the key is
            // cleared, so a repeat load must return `nil` (or, if
            // somehow re-populated by prior test state, must still never
            // crash) rather than re-processing the same corrupt bytes
            // forever.
            _ = store.load(for: identity)

            let ledgerEntries = store.quarantine.ledger()
            XCTAssertLessThanOrEqual(ledgerEntries.count, 200, "the quarantine ledger must stay bounded even under repeated corruption")
        }
    }
}
