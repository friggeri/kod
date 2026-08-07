import Foundation

/// A bounded, in-memory, append-only log of `DiagnosticEvent`s, mirroring
/// SPEC 13.2's "process stdout, stderr, message size... are bounded"
/// philosophy for the diagnostics/log viewer itself: unbounded log growth
/// is its own reliability and privacy risk (SPEC 15's "bounded diagnostics/
/// log viewer"). Oldest events are dropped once `capacity` is exceeded, and
/// the number dropped is tracked and exposed rather than silently lost, so
/// a support bundle or on-screen viewer can say "37 earlier events were
/// dropped" instead of just showing a suspiciously short log.
///
/// An `actor` (not `@MainActor`) because subsystems that log — language
/// servers, Git, search, managed installs, previews — run on background
/// queues/tasks and must be able to record events without hopping to the
/// main actor first.
public actor BoundedEventLog {
    public private(set) var events: [DiagnosticEvent] = []
    public private(set) var droppedCount: Int = 0
    public let capacity: Int

    public init(capacity: Int = 2000) {
        self.capacity = max(1, capacity)
    }

    public func record(_ event: DiagnosticEvent) {
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
            droppedCount += 1
        }
    }

    /// Convenience for the common case of building an event inline.
    public func record(
        subsystem: DiagnosticSubsystem,
        level: DiagnosticLevel,
        message: String,
        context: [DiagnosticContextField] = []
    ) {
        record(
            DiagnosticEvent(
                subsystem: subsystem,
                level: level,
                message: message,
                context: context
            )
        )
    }

    /// A redacted snapshot suitable for on-screen display or inclusion in
    /// a support bundle — never the raw, unredacted `events`.
    public func redactedSnapshot() -> [DiagnosticEvent] {
        events.map(RedactionEngine.redact)
    }

    public func events(atLeast minimumLevel: DiagnosticLevel) -> [DiagnosticEvent] {
        events.filter { $0.level >= minimumLevel }
    }

    public func clear() {
        events.removeAll()
        droppedCount = 0
    }
}
