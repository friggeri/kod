import Foundation

// Explicit, typed outcomes for the language service surface. Nothing
// here is ever silently degraded into "no results": an unauthorized
// workspace, an un-launched server, a superseded snapshot, a capability
// the server never advertised, and a document a relaunched server could
// not be resynchronized with are all distinguishable, reportable
// conditions.

public enum LanguageWorkspaceServiceError: Error, Equatable, Sendable {
    /// The workspace's injected `WorkspaceLaunchAuthorization` refused
    /// the launch (SPEC 6/13's trust-before-launch rule).
    case notTrusted
    case notStarted
    case documentNotOpen(URL)
    case staleRequest(url: URL, expectedVersion: Int, actualVersion: Int)
    case capabilityUnavailable(String)
    case invalidTargetURI(String)
}

public enum LanguageDocumentSynchronizationResult: Equatable, Sendable {
    case opened
    case unchanged
    case changed
}

/// Why one tracked document could not be re-opened on a relaunched
/// server after an automatic crash/restart cycle. Carries the affected
/// document URL and a transport-level reason only: never any part of the
/// document's text, so a failure can be logged or displayed without
/// leaking source content.
public struct LanguageDocumentReplayFailure: Error, Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// The connection disappeared between the server reporting
        /// `.ready` and the replay being issued.
        case notConnected
        /// `textDocument/didOpen` could not be delivered. The associated
        /// description is the transport/JSON-RPC error only.
        case notificationFailed(String)
    }

    public let url: URL
    public let reason: Reason
    /// How many delivery attempts were made before giving up.
    public let attempts: Int

    public init(url: URL, reason: Reason, attempts: Int) {
        self.url = url
        self.reason = reason
        self.attempts = attempts
    }

    /// A short, content-free description suitable for a bounded
    /// diagnostics-log entry.
    public var localizedDescription: String {
        switch reason {
        case .notConnected:
            return "\(url.lastPathComponent): connection unavailable"
        case .notificationFailed(let description):
            return "\(url.lastPathComponent): \(description)"
        }
    }
}
