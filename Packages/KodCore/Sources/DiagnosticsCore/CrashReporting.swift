import Foundation

/// Every network call Kod ever makes must be attributable to one of these
/// purposes in the UI/model (SPEC 13.3: "Network activity is attributable
/// in the UI to app updates, remote Markdown resources, or crash reports.
/// This is a closed set on purpose — a
/// network call that doesn't fit one of these categories is a bug, not
/// something to label `.other`.
public enum NetworkAttribution: String, Sendable, Equatable, Codable, CaseIterable {
    case appUpdate
    case remoteMarkdownResource
    case crashReport

    public var userFacingDescription: String {
        switch self {
        case .appUpdate:
            return "App update check"
        case .remoteMarkdownResource:
            return "Remote Markdown image"
        case .crashReport:
            return "Crash report upload"
        }
    }
}

/// Opt-in crash reporting settings (SPEC 13.3: "Crash reporting is
/// opt-in."). `isEnabled` defaults to `false` and nothing in this package
/// ever flips it on programmatically — only an explicit, user-driven
/// settings action may do so. Persisted via `UserDefaults` like Kod's other
/// external metadata (SPEC 11.7).
public struct CrashReportingSettings: Sendable, Equatable, Codable {
    public var isEnabled: Bool

    public init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }
}

@MainActor
public final class CrashReportingSettingsStore {
    private let defaults: UserDefaults
    private let key = "kod.diagnostics.crash-reporting-settings"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Loads current settings. A corrupt/undecodable stored value is
    /// treated as "not enabled" (the safe default for an opt-in privacy
    /// setting) and is quarantined via `CorruptStateQuarantine` rather than
    /// silently discarded, so it remains visible for diagnosis. `quarantine`
    /// defaults to one backed by this store's own `defaults` (not global
    /// `.standard`), so a store constructed against a test/custom
    /// `UserDefaults` suite quarantines against that same suite.
    public func load(quarantine: CorruptStateQuarantine? = nil) -> CrashReportingSettings {
        let quarantine = quarantine ?? CorruptStateQuarantine(defaults: defaults)
        switch quarantine.decode(CrashReportingSettings.self, forKey: key) {
        case .restored(let settings):
            return settings
        case .absent, .quarantined:
            return CrashReportingSettings()
        }
    }

    public func save(_ settings: CrashReportingSettings) {
        guard let data = try? JSONEncoder().encode(settings) else {
            preconditionFailure("CrashReportingSettings must always be encodable")
        }
        defaults.set(data, forKey: key)
    }
}

/// A crash report ready for (opt-in, user-initiated) upload. `payload` is
/// expected to already be redacted before a transport ever sees it — see
/// `SupportBundleGenerator`/`RedactionEngine`. Kept intentionally tiny:
/// Kod does not collect stack symbolication, device identifiers, or any
/// other usage telemetry, only what is needed to diagnose the specific
/// crash.
public struct CrashReport: Sendable, Equatable {
    public let identifier: UUID
    public let capturedAt: Date
    public let redactedPayload: Data

    public init(identifier: UUID = UUID(), capturedAt: Date = Date(), redactedPayload: Data) {
        self.identifier = identifier
        self.capturedAt = capturedAt
        self.redactedPayload = redactedPayload
    }
}

/// The transport boundary crash reports must cross before leaving the
/// Mac. This is a protocol specifically so it can be tested *without*
/// sending anything real: production code must never call a concrete
/// networking transport directly, only through this seam, and only after
/// confirming `CrashReportingSettings.isEnabled`.
public protocol CrashReportTransport: Sendable {
    func send(_ report: CrashReport, attribution: NetworkAttribution) async throws
}

/// The default, no-op transport. Nothing is ever sent. Every
/// `CrashReportUploadCoordinator` is constructed with this transport
/// unless a call site explicitly substitutes another one, so "opt-in
/// crash reporting" fails safely toward "never actually transmits
/// anything" rather than toward "transmits by default."
public struct NoopCrashReportTransport: CrashReportTransport {
    public init() {}

    public func send(_ report: CrashReport, attribution: NetworkAttribution) async throws {
        // Intentionally does nothing: this is the permanent default
        // transport. A real transport is opt-in infrastructure that does
        // not exist in this codebase — see SPEC 13.3 and the Phase 11
        // README notes on why no production upload endpoint is wired up.
    }
}

public enum CrashReportUploadError: Error, Equatable {
    case reportingDisabled
}

/// Gates every crash-report send behind the user's live opt-in setting,
/// so a transport implementation can never be invoked while reporting is
/// disabled — the check happens here, once, rather than being each
/// transport's responsibility to remember.
@MainActor
public final class CrashReportUploadCoordinator {
    private let settingsStore: CrashReportingSettingsStore
    private let transport: any CrashReportTransport

    public init(
        settingsStore: CrashReportingSettingsStore = CrashReportingSettingsStore(),
        transport: any CrashReportTransport = NoopCrashReportTransport()
    ) {
        self.settingsStore = settingsStore
        self.transport = transport
    }

    /// Sends `report` only if the user has opted in; otherwise throws
    /// `.reportingDisabled` without ever touching `transport`.
    public func upload(_ report: CrashReport) async throws {
        guard settingsStore.load().isEnabled else {
            throw CrashReportUploadError.reportingDisabled
        }
        try await transport.send(report, attribution: .crashReport)
    }
}

/// A test double that records every attempted send without performing any
/// real network I/O, so opt-in gating and payload redaction can be proven
/// in headless unit tests "without sending" anything, per the Phase 11
/// requirement that crash-report settings be "testable without sending."
public actor RecordingCrashReportTransport: CrashReportTransport {
    public private(set) var sentReports: [(report: CrashReport, attribution: NetworkAttribution)] = []

    public init() {}

    public func send(_ report: CrashReport, attribution: NetworkAttribution) async throws {
        sentReports.append((report, attribution))
    }
}
