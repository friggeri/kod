import Foundation

/// Sequencing, freshness, and routing policy for every diagnostic this
/// service publishes (SPEC 6.3).
///
/// Two independent destinations exist, and mixing them up is the bug
/// this type prevents:
///
/// * **Raw** reports go to the workspace-wide store for every accepted
///   report, including files Kod never opened (which have no
///   `SourceSnapshot` to validate against).
/// * **Normalized** reports go to live editor decorations, and only for
///   documents that are open right now, validated against the exact
///   immutable snapshot version that was open when the report arrived.
///
/// Because normalization suspends (it awaits the negotiated encoding), a
/// per-URL monotonic publish sequence is issued *before* the suspension
/// and re-checked after it. A close, a `didChange`, a restart, or a
/// newer publish for the same version invalidates the outstanding
/// ticket, so an older in-flight normalization can never overwrite a
/// newer one.
struct LanguageDiagnosticsCoordinator {
    /// Where one report is allowed to go.
    enum Routing: Equatable {
        /// The file is not open here: raw only, exactly like a file that
        /// was never opened at all.
        case rawOnly
        /// The file is open: raw plus snapshot-normalized editor markers.
        case rawAndNormalized
    }

    /// A claim on one URL's normalized-publish slot, taken before the
    /// normalization suspension point and validated after it.
    struct PublishTicket: Equatable {
        let url: URL
        let sequence: UInt64
    }

    private var publishSequenceByURL: [URL: UInt64] = [:]
    /// URLs whose editor markers were cleared and must not be
    /// reconstructed from already-stored wire diagnostics until the
    /// server publishes again for the current snapshot.
    private var urlsRequiringFreshPublish: Set<URL> = []
    private var workspaceResultIDsByURL: [URL: String] = [:]

    init() {}

    // MARK: - Routing policy

    static func routing(isDocumentOpen: Bool) -> Routing {
        isDocumentOpen ? .rawAndNormalized : .rawOnly
    }

    // MARK: - Publish sequencing

    /// Claims the next publish slot for `url`.
    mutating func beginPublish(for url: URL) -> PublishTicket {
        let sequence = publishSequenceByURL[url, default: 0] &+ 1
        publishSequenceByURL[url] = sequence
        return PublishTicket(url: url, sequence: sequence)
    }

    /// Whether `ticket` is still the most recent claim for its URL.
    func isCurrent(_ ticket: PublishTicket) -> Bool {
        publishSequenceByURL[ticket.url, default: 0] == ticket.sequence
    }

    /// Marks a normalized publish as delivered: the URL's markers now
    /// describe the live snapshot again, so stored wire diagnostics may
    /// be re-normalized against it.
    mutating func completePublish(_ ticket: PublishTicket) {
        urlsRequiringFreshPublish.remove(ticket.url)
    }

    /// Invalidates any outstanding normalization for `url` and blocks
    /// stored-diagnostic re-normalization until a fresh publish arrives.
    /// Returns the URL so callers can clear its markers in one step.
    @discardableResult
    mutating func invalidate(url: URL) -> URL {
        publishSequenceByURL[url] = publishSequenceByURL[url, default: 0] &+ 1
        urlsRequiringFreshPublish.insert(url)
        return url
    }

    @discardableResult
    mutating func invalidate(urls: some Sequence<URL>) -> [URL] {
        urls.map { invalidate(url: $0) }
    }

    /// Whether diagnostics already retained by the workspace store may be
    /// normalized against the current snapshot of `url`.
    func allowsStoredNormalization(for url: URL) -> Bool {
        !urlsRequiringFreshPublish.contains(url)
    }

    func currentSequence(for url: URL) -> UInt64 {
        publishSequenceByURL[url, default: 0]
    }

    // MARK: - Pull result IDs

    /// `workspace/diagnostic` previous result IDs, in a stable order so
    /// the request payload never depends on dictionary ordering.
    var previousResultIDs: [PreviousResultID] {
        workspaceResultIDsByURL
            .map { PreviousResultID(uri: DocumentURI(fileURL: $0.key), value: $0.value) }
            .sorted { $0.uri.stringValue < $1.uri.stringValue }
    }

    /// Records (or clears) one workspace report item's result ID. A
    /// `full` report without a result ID means the server no longer
    /// supports incremental follow-ups for that file.
    mutating func recordResultID(
        _ resultID: String?,
        kind: WorkspaceDocumentDiagnosticReport.Kind,
        for url: URL
    ) {
        if let resultID {
            workspaceResultIDsByURL[url] = resultID
        } else if kind == .full {
            workspaceResultIDsByURL.removeValue(forKey: url)
        }
    }

    mutating func resetResultIDs() {
        workspaceResultIDsByURL.removeAll()
    }

    var trackedResultIDCount: Int {
        workspaceResultIDsByURL.count
    }
}
