import Foundation

/// The server lifecycle states the UI always distinguishes (SPEC 6.2).
/// `Equatable` so tests and UI diffing can compare states directly.
public enum LanguageServerState: Equatable, Sendable {
    /// No compatible executable was discovered for this workspace.
    case missing(reason: String)
    /// Process launched; `initialize` handshake in flight.
    case starting
    /// `initialize`/`initialized` completed; server is doing initial
    /// workspace indexing before results can be trusted as complete.
    case indexing
    /// Ready to serve requests.
    case ready
    /// Ready, but currently has one or more in-flight requests Kod is
    /// waiting on.
    case busy
    /// Graceful shutdown (`shutdown`/`exit`) in progress.
    case stopping
    /// Exited cleanly (or was stopped) and is not scheduled to restart.
    case stopped
    /// Exited unexpectedly. May still auto-restart, subject to the
    /// restart budget below.
    case crashed(reason: String)
    /// Crashed more than the restart budget allows; will not restart
    /// automatically. A manual Restart action is required.
    case disabled(reason: String)

    public var isUsable: Bool {
        switch self {
        case .ready, .busy, .indexing:
            return true
        case .missing, .starting, .stopping, .stopped, .crashed, .disabled:
            return false
        }
    }

    public var displayName: String {
        switch self {
        case .missing:
            return "Missing"
        case .starting:
            return "Starting"
        case .indexing:
            return "Indexing"
        case .ready:
            return "Ready"
        case .busy:
            return "Busy"
        case .stopping:
            return "Stopping"
        case .stopped:
            return "Stopped"
        case .crashed:
            return "Crashed"
        case .disabled:
            return "Disabled"
        }
    }
}

/// Tracks crash timestamps within a sliding window to enforce SPEC 6.2's
/// "restarts at most three times in five minutes" budget. Pure value
/// logic, isolated from the connection actor so it's independently
/// testable.
public struct RestartBudget: Sendable {
    public let maxRestarts: Int
    public let window: TimeInterval
    private var crashTimestamps: [Date] = []

    public init(maxRestarts: Int = 3, window: TimeInterval = 5 * 60) {
        self.maxRestarts = maxRestarts
        self.window = window
    }

    /// Records a crash at `date` and returns whether a restart is still
    /// permitted (i.e. fewer than `maxRestarts` crashes fall within the
    /// trailing `window`, including this one).
    public mutating func recordCrashAndCheckIfRestartAllowed(at date: Date = Date()) -> Bool {
        crashTimestamps.append(date)
        crashTimestamps.removeAll { date.timeIntervalSince($0) > window }
        return crashTimestamps.count <= maxRestarts
    }
}
