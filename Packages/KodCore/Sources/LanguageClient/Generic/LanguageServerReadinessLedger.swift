import Foundation

/// The lifecycle state machine behind SPEC 6.2's start/restart/stop and
/// the automatic crash-restart document replay: whether a connection is
/// waiting to become ready, whether it has *ever* been ready (which is
/// what distinguishes a first launch from a relaunch), whether an
/// explicit restart or stop is in progress, and the typed failures of
/// the most recent replay.
///
/// Pure state: it decides what a reported connection state *means*, and
/// the owning actor performs the resulting work (forwarding the state,
/// clearing markers, replaying documents, scheduling pull diagnostics).
struct LanguageServerReadinessLedger {
    /// What one reported connection state implies.
    enum Transition: Equatable {
        /// Forward the state; nothing else to do.
        case forward(LanguageServerState)
        /// A server that had already been ready is starting again — an
        /// automatic crash/restart cycle. Forward `.starting`, cancel
        /// pull diagnostics, and clear editor markers: a relaunching
        /// server's previously published markers no longer describe
        /// anything.
        case relaunching
        /// The first `.ready` for this connection instance: forward it
        /// and begin workspace-wide pull diagnostics.
        case firstReady
        /// A relaunched server reports `.ready`, but it holds none of
        /// Kod's documents yet. `.ready` is deliberately withheld until
        /// the replay succeeds, so no caller issues document requests
        /// against a server that cannot answer them.
        case replayDocumentsThenReady
    }

    private(set) var didCompleteFirstReady = false
    private(set) var isAwaitingConnectionReady = false
    private(set) var isRestarting = false
    /// Whether the service is fully stopped right now. A `stop()` after a
    /// completed `stop()` is a no-op — in particular it must never
    /// advance the provider generation a second time.
    private(set) var hasStopped = true
    private(set) var replayFailures: [LanguageDocumentReplayFailure] = []

    init() {}

    // MARK: - State machine

    mutating func transition(for state: LanguageServerState) -> Transition {
        if state == .starting {
            isAwaitingConnectionReady = true
            return didCompleteFirstReady ? .relaunching : .forward(.starting)
        }
        guard state == .ready, isAwaitingConnectionReady else {
            return .forward(state)
        }
        isAwaitingConnectionReady = false
        guard didCompleteFirstReady else {
            didCompleteFirstReady = true
            return .firstReady
        }
        return .replayDocumentsThenReady
    }

    mutating func markReplaySucceeded() {
        replayFailures = []
        didCompleteFirstReady = true
    }

    mutating func markReplayFailed(_ failures: [LanguageDocumentReplayFailure]) {
        replayFailures = failures
        didCompleteFirstReady = true
    }

    // MARK: - Explicit lifecycle

    mutating func markStarted() {
        hasStopped = false
    }

    /// Claims the single in-flight explicit restart. Returns `false` when
    /// one is already running, which the caller treats as a no-op.
    mutating func beginRestart() -> Bool {
        guard !isRestarting else {
            return false
        }
        isRestarting = true
        return true
    }

    mutating func endRestart() {
        isRestarting = false
    }

    /// Clears the per-connection readiness state a restart discards,
    /// leaving `hasStopped` alone: the subsequent `start()` owns that.
    mutating func resetForRelaunch() {
        replayFailures.removeAll()
        didCompleteFirstReady = false
        isAwaitingConnectionReady = false
    }

    mutating func markStopping() {
        isAwaitingConnectionReady = false
    }

    mutating func markStopped() {
        replayFailures.removeAll()
        didCompleteFirstReady = false
        hasStopped = true
    }

    // MARK: - Reporting

    /// A bounded, content-free summary of a failed replay. It reaches
    /// state callbacks, logs, and the status UI, so it never grows with
    /// the number of open documents and never contains document text.
    static func replayFailureReason(
        _ failures: [LanguageDocumentReplayFailure]
    ) -> String {
        let listed = failures.prefix(3).map(\.localizedDescription).joined(separator: "; ")
        let remainder = failures.count - min(failures.count, 3)
        let suffix = remainder > 0 ? " (+\(remainder) more)" : ""
        return "Restarted server could not be resynchronized: \(listed)\(suffix)"
    }

    /// A transport/JSON-RPC failure description, truncated so a bounded
    /// log entry stays bounded. Never contains document text.
    static func transportReason(_ error: Error) -> String {
        let description = String(describing: error)
        guard description.count > 200 else {
            return description
        }
        return String(description.prefix(200)) + "…"
    }
}
