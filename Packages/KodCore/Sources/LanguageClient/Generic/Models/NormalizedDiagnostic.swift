import Foundation

/// A published diagnostic converted through the server-negotiated position
/// encoding and validated against the exact immutable snapshot version that
/// was open when the notification arrived.
public struct NormalizedDiagnostic: Sendable {
    public let snapshotVersion: Int
    public let utf8Range: Range<Int>
    public let startLine: Int
    public let severity: DiagnosticSeverity?
    public let code: JSONValue?
    public let source: String?
    public let message: String

    public init(
        snapshotVersion: Int,
        utf8Range: Range<Int>,
        startLine: Int,
        severity: DiagnosticSeverity?,
        code: JSONValue?,
        source: String?,
        message: String
    ) {
        self.snapshotVersion = snapshotVersion
        self.utf8Range = utf8Range
        self.startLine = startLine
        self.severity = severity
        self.code = code
        self.source = source
        self.message = message
    }
}
