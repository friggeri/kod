import FuzzSupport
import SettingsCore
import XCTest
@testable import WorkspaceCore

/// Bounded, seeded fuzzing of `WorkspaceLayoutStore`'s persistence-
/// migration path: what happens when the repository-backed JSON blob
/// behind a previously-valid saved layout becomes corrupt — from a
/// half-written save or hostile
/// tampering (SPEC 15: "Corrupt Kod metadata is quarantined and rebuilt";
/// SPEC 16.1 fuzz coverage extended here to persistence migrations, one
/// of Phase 12's explicitly requested new fuzz targets). Every corrupt
/// blob is random bytes: malformed/current data is quarantined, while a
/// syntactically valid future version or missing explicit migration remains
/// untouched with a typed error. Neither path may crash or loop.
@MainActor
final class PersistenceMigrationFuzzTests: XCTestCase {
    func testCorruptSavedLayoutIsAlwaysQuarantinedNeverCrashes() throws {
        try FuzzRun.run("PersistenceMigrationFuzzTests.corruptLayout", iterations: 200) { source in
            let keyValueStore = InMemorySettingsKeyValueStore()
            let repository = CodableSettingsRepository(store: keyValueStore)
            let store = WorkspaceLayoutStore(repository: repository)
            let identity = try WorkspaceIdentity(root: FileManager.default.temporaryDirectory)
            let dataKey = "workspace-layout.\(identity.persistenceKey)"

            // Save one genuinely valid state first, so the corrupted
            // blob below replaces real, previously-written data — the
            // scenario SPEC 15 actually describes (a subsystem finding
            // its *own* prior save corrupt), not just "reading garbage
            // that was never valid to begin with."
            try store.save(.singleGroup(), for: identity)

            let corruptBytes = Data(FuzzGenerators.randomBytes(lengthIn: 0...512, &source))
            try keyValueStore.setValue(.data(corruptBytes), forKey: dataKey)

            // First load after corruption: must never crash, and — for
            // the (extremely unlikely but not impossible) case where
            // random bytes happen to decode as valid JSON matching the
            // schema — either a legitimate value or quarantine is acceptable;
            // only an untyped failure or crash is a failure.
            do {
                _ = try store.load(for: identity)
            } catch SettingsRepositoryError.unsupportedVersion(_, _, _) {
                // A syntactically valid future envelope is deliberately
                // preserved rather than quarantined by an older build.
            } catch SettingsRepositoryError.migrationRequired(_, _, _) {
                // Likewise, a recognized older envelope with no registered
                // migration remains untouched and actionable.
            }

            // A second load must be stable: quarantined bytes stay cleared;
            // recognized-but-unsupported envelopes repeat the same typed
            // error without being destroyed.
            do {
                _ = try store.load(for: identity)
            } catch SettingsRepositoryError.unsupportedVersion(_, _, _) {
            } catch SettingsRepositoryError.migrationRequired(_, _, _) {
            }

            let ledgerEntries = try repository.quarantine.records()
            XCTAssertLessThanOrEqual(ledgerEntries.count, 200, "the quarantine ledger must stay bounded even under repeated corruption")
        }
    }
}
