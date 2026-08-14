import Foundation
import SourceModel

/// The open-document half of SPEC 6.3's synchronization rules: which
/// documents this service has told its server about, and at exactly
/// which immutable snapshot.
///
/// Pure state with no I/O: it decides *what* transition a snapshot
/// implies (`didOpen` vs `didChange` vs nothing) and validates requests
/// against the tracked version, while the owning actor performs the
/// notification and records the outcome only once delivery succeeded.
/// Keys are always standardized file URLs, so `/tmp/x` and `/tmp/./x`
/// are the same document.
struct DocumentSynchronizationLedger {
    /// What synchronizing a given snapshot requires of the server.
    enum SynchronizationPlan: Equatable {
        /// Not tracked yet: the server must be sent `didOpen`.
        case open
        /// Tracked at exactly this version and text: nothing to send.
        case unchanged
        /// Tracked at a different version or text: send `didChange`.
        case change
    }

    private var snapshotsByURL: [URL: SourceSnapshot] = [:]

    init() {}

    // MARK: - Reads

    var trackedURLs: [URL] {
        Array(snapshotsByURL.keys)
    }

    var isEmpty: Bool {
        snapshotsByURL.isEmpty
    }

    /// Tracked snapshots in a stable, path-sorted order, which is what
    /// an automatic-restart replay walks so its behavior (and its
    /// reported failures) never depend on dictionary ordering.
    var snapshotsOrderedByPath: [SourceSnapshot] {
        snapshotsByURL.values.sorted { $0.url.path < $1.url.path }
    }

    func snapshot(for url: URL) -> SourceSnapshot? {
        snapshotsByURL[url.standardizedFileURL]
    }

    func isTracked(_ url: URL) -> Bool {
        snapshotsByURL[url.standardizedFileURL] != nil
    }

    func plan(for snapshot: SourceSnapshot) -> SynchronizationPlan {
        guard let current = snapshotsByURL[snapshot.url.standardizedFileURL] else {
            return .open
        }
        guard current.version != snapshot.version
                || current.text != snapshot.text else {
            return .unchanged
        }
        return .change
    }

    /// Whether a server-reported version for `url` describes the exact
    /// snapshot that is open right now. Documents Kod has not opened
    /// have no client-side version to compare, and are not rejected here.
    func acceptsReportedVersion(_ version: Int?, for url: URL) -> Bool {
        guard let version, let snapshot = snapshotsByURL[url.standardizedFileURL] else {
            return true
        }
        return snapshot.version == version
    }

    /// Whether `snapshot` is byte-for-byte the tracked one, which is the
    /// precondition for re-normalizing already-stored wire diagnostics
    /// against it.
    func isCurrent(_ snapshot: SourceSnapshot) -> Bool {
        guard let tracked = snapshotsByURL[snapshot.url.standardizedFileURL] else {
            return false
        }
        return tracked.version == snapshot.version && tracked.text == snapshot.text
    }

    // MARK: - Validation

    /// Requires that the document is tracked at all, which is what
    /// `didChange` needs before it can legally be sent.
    func requireTracked(_ snapshot: SourceSnapshot) throws {
        guard snapshotsByURL[snapshot.url.standardizedFileURL] != nil else {
            throw LanguageWorkspaceServiceError.documentNotOpen(snapshot.url)
        }
    }

    /// Requires that the document is tracked *and* that the caller's
    /// snapshot is the tracked version, so a request is never answered
    /// against text the server does not have (SPEC 6.3).
    func requireOpenAndCurrent(_ snapshot: SourceSnapshot) throws {
        guard let tracked = snapshotsByURL[snapshot.url.standardizedFileURL] else {
            throw LanguageWorkspaceServiceError.documentNotOpen(snapshot.url)
        }
        guard tracked.version == snapshot.version else {
            throw LanguageWorkspaceServiceError.staleRequest(
                url: snapshot.url,
                expectedVersion: tracked.version,
                actualVersion: snapshot.version
            )
        }
    }

    // MARK: - Transitions

    /// Records a delivered `didOpen`/replayed `didOpen`.
    mutating func recordOpen(_ snapshot: SourceSnapshot) {
        snapshotsByURL[snapshot.url.standardizedFileURL] = snapshot
    }

    /// Records a delivered `didChange`.
    mutating func recordChange(_ snapshot: SourceSnapshot) {
        snapshotsByURL[snapshot.url.standardizedFileURL] = snapshot
    }

    /// Drops a document. Returns the standardized URL when it really was
    /// tracked, and `nil` when this was a no-op — the caller uses that to
    /// decide whether to send `didClose` and clear editor markers.
    @discardableResult
    mutating func remove(url: URL) -> URL? {
        let standardizedURL = url.standardizedFileURL
        guard snapshotsByURL.removeValue(forKey: standardizedURL) != nil else {
            return nil
        }
        return standardizedURL
    }

    /// Drops every tracked document, returning the standardized URLs
    /// that were dropped.
    @discardableResult
    mutating func removeAll() -> [URL] {
        let urls = Array(snapshotsByURL.keys)
        snapshotsByURL.removeAll()
        return urls
    }
}
