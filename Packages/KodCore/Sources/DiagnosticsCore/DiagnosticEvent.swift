import Foundation

/// The subsystem a diagnostic event originates from. Kept as a small,
/// closed set (rather than a free-form string) so the bounded log, the
/// Problems/diagnostics viewer, and support-bundle grouping all agree on
/// the same vocabulary (SPEC 15: "every background subsystem has an
/// explicit state and user-visible failure path").
public enum DiagnosticSubsystem: String, Sendable, Equatable, Codable, CaseIterable {
    case workspace
    case search
    case git
    case languageServer
    case managedInstall
    case preview
    case theme
    case font
    case accessibility
    case crashReporting
    case app
}

public enum DiagnosticLevel: String, Sendable, Equatable, Codable, Comparable, CaseIterable {
    case debug
    case info
    case warning
    case error

    private var ordinal: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    public static func < (lhs: DiagnosticLevel, rhs: DiagnosticLevel) -> Bool {
        lhs.ordinal < rhs.ordinal
    }
}

/// One field of context attached to a `DiagnosticEvent`. `category` records
/// what *kind* of data `value` holds so `RedactionEngine` can apply the
/// correct, deterministic transform (SPEC 13.3) without having to guess by
/// sniffing the string — the producer of the event (which knows whether a
/// value is a search term, a symbol name, a full path, etc.) tags it once,
/// at the source, rather than downstream code trying to reverse-engineer
/// the meaning of an opaque string.
public struct DiagnosticContextField: Sendable, Equatable, Codable {
    public enum Category: String, Sendable, Equatable, Codable, CaseIterable {
        /// Free text that is not known to require redaction (e.g. a fixed,
        /// non-identifying status word). Still passed through
        /// `RedactionEngine.redactFreeformText` as a safety net.
        case general
        case sourceText
        case searchTerm
        case username
        case homePath
        case fullPath
        case repositoryRemote
        case symbol
        case diagnosticMessage
        case environmentSecret
    }

    public let name: String
    public let category: Category
    public let value: String

    public init(name: String, category: Category, value: String) {
        self.name = name
        self.category = category
        self.value = value
    }
}

/// A single structured, bounded diagnostic record. `DiagnosticEvent`s are
/// produced by background subsystems (language servers, Git, search,
/// managed installs, previews, theme/font loading) whenever they hit an
/// explicit failure, degraded, or recovered state, per SPEC 15. They are
/// never raw `print`/`NSLog` output: every event carries a subsystem, a
/// level, a human-readable (pre-redaction) message, and zero or more
/// tagged context fields so a support bundle can redact deterministically
/// rather than guessing.
public struct DiagnosticEvent: Sendable, Equatable, Codable {
    public let id: UUID
    public let timestamp: Date
    public let subsystem: DiagnosticSubsystem
    public let level: DiagnosticLevel
    public let message: String
    public let context: [DiagnosticContextField]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        subsystem: DiagnosticSubsystem,
        level: DiagnosticLevel,
        message: String,
        context: [DiagnosticContextField] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.subsystem = subsystem
        self.level = level
        self.message = message
        self.context = context
    }
}
