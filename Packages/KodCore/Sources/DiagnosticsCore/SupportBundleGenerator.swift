import Foundation

/// Everything captured in a support bundle: app/OS identification, the
/// redacted bounded event log, and a summary of any quarantined
/// (corrupt-and-rebuilt) metadata — deliberately nothing else. There is no
/// field anywhere in this type for source file contents, workspace paths,
/// or search history, because SPEC 13.3 requires "No source, path,
/// symbol, diagnostic, theme, font, search, or repository data leaves the
/// Mac by default" and a support bundle the user explicitly exports is
/// held to the same redaction bar as an opt-in crash report.
public struct SupportBundleManifest: Sendable, Equatable, Codable {
    public let generatedAt: Date
    public let appVersion: String
    public let osVersion: String
    public let architecture: String
    public let eventCount: Int
    public let droppedEventCount: Int
    public let quarantinedRecordCount: Int

    public init(
        generatedAt: Date,
        appVersion: String,
        osVersion: String,
        architecture: String,
        eventCount: Int,
        droppedEventCount: Int,
        quarantinedRecordCount: Int
    ) {
        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.architecture = architecture
        self.eventCount = eventCount
        self.droppedEventCount = droppedEventCount
        self.quarantinedRecordCount = quarantinedRecordCount
    }
}

public struct SupportBundleContents: Sendable, Equatable, Codable {
    public let manifest: SupportBundleManifest
    public let redactedEvents: [DiagnosticEvent]
    public let quarantinedRecords: [QuarantinedRecord]

    public init(
        manifest: SupportBundleManifest,
        redactedEvents: [DiagnosticEvent],
        quarantinedRecords: [QuarantinedRecord]
    ) {
        self.manifest = manifest
        self.redactedEvents = redactedEvents
        self.quarantinedRecords = quarantinedRecords
    }
}

public enum SupportBundleError: Error, Equatable {
    case unredactedSourceTextDetected
}

/// Builds and writes a support bundle. Generation never touches the
/// network (the bundle is written to a local, caller-chosen directory for
/// the user to inspect/attach to a manually-filed report themselves) and
/// never reads repository content — its only inputs are the diagnostics
/// log and the quarantine ledger, both of which are already
/// metadata-only.
public enum SupportBundleGenerator {
    /// Assembles bundle contents from an already-populated `BoundedEventLog`
    /// and SettingsCore's bounded quarantine. `redactedEvents` are re-verified here
    /// (`assertFullyRedacted`) as a defense-in-depth check, not just
    /// trusted from the caller, since this is the last point before the
    /// data could be written to disk/handed to a user.
    public static func generate(
        from log: BoundedEventLog,
        quarantine: [QuarantinedRecord],
        appVersion: String,
        osVersion: String,
        architecture: String,
        now: Date = Date()
    ) async throws -> SupportBundleContents {
        let redactedEvents = await log.redactedSnapshot()
        try assertFullyRedacted(redactedEvents)

        let manifest = SupportBundleManifest(
            generatedAt: now,
            appVersion: appVersion,
            osVersion: osVersion,
            architecture: architecture,
            eventCount: redactedEvents.count,
            droppedEventCount: await log.droppedCount,
            quarantinedRecordCount: quarantine.count
        )

        return SupportBundleContents(
            manifest: manifest,
            redactedEvents: redactedEvents,
            quarantinedRecords: quarantine
        )
    }

    /// Serializes `contents` as a single pretty-printed, deterministic JSON
    /// document and writes it to `url` (a file the caller chose, e.g. via
    /// an `NSSavePanel`). No compression/zipping is required for a
    /// diagnostics-only JSON document, and avoiding an archive format keeps
    /// the bundle trivially human-inspectable before the user shares it.
    public static func write(_ contents: SupportBundleContents, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(contents)
        try data.write(to: url, options: .atomic)
    }

    /// Defense-in-depth: scans already-"redacted" events for the fixed
    /// category placeholder strings that should be present and, more
    /// importantly, for signs that a `.sourceText`-tagged field somehow
    /// still carries non-placeholder content (e.g. a future call site that
    /// forgets to route through `RedactionEngine.redact` first). This is
    /// intentionally strict — a hit throws rather than silently shipping a
    /// bundle that might contain source contents.
    static func assertFullyRedacted(_ events: [DiagnosticEvent]) throws {
        for event in events {
            for field in event.context where field.category == .sourceText {
                guard field.value == RedactionEngine.redactedValue(for: field) else {
                    throw SupportBundleError.unredactedSourceTextDetected
                }
            }
        }
    }
}
