import Combine
import DiagnosticsCore
import FontCore
import Foundation
import KodCore
import ThemeCore
import WorkspaceCore

/// The `@MainActor` coordinator behind the Diagnostics settings tab
/// (SPEC 15: "a bounded diagnostics/log viewer"). Polls a shared,
/// app-lifetime `BoundedEventLog` for its `redactedSnapshot()` — never
/// its raw `events` — and exposes the opt-in crash-reporting toggle and
/// the support-bundle export action on top of the same
/// `CrashReportingSettingsStore`/`SupportBundleGenerator` the rest of
/// `DiagnosticsCore` already implements. Constructed with an injectable
/// `BoundedEventLog` (and everything else it depends on defaulted), like
/// `WorkspaceTrustStore`/`FontSettingsStore`'s injectable-`UserDefaults`
/// pattern, so it is directly testable without any app-wide singleton.
@MainActor
final class DiagnosticsViewModel: ObservableObject {
    private let diagnosticsLog: BoundedEventLog
    private let crashReportingSettingsStore: CrashReportingSettingsStore
    private let quarantineLedgers: @MainActor () -> [QuarantinedRecord]
    private let appVersion: String
    private let osVersion: String
    private let architecture: String

    @Published private(set) var events: [DiagnosticEvent] = []
    @Published private(set) var droppedCount: Int = 0
    @Published var minimumLevel: DiagnosticLevel = .debug
    @Published var crashReportingEnabled: Bool {
        didSet {
            guard crashReportingEnabled != oldValue else {
                return
            }
            var settings = crashReportingSettingsStore.load()
            settings.isEnabled = crashReportingEnabled
            crashReportingSettingsStore.save(settings)
        }
    }
    @Published var lastExportErrorDescription: String?

    /// `events`, sorted newest-first, restricted to `minimumLevel` and
    /// above — the only thing `DiagnosticsView` ever renders.
    var filteredEvents: [DiagnosticEvent] {
        events
            .filter { $0.level >= minimumLevel }
            .sorted { $0.timestamp > $1.timestamp }
    }

    init(
        diagnosticsLog: BoundedEventLog,
        crashReportingSettingsStore: CrashReportingSettingsStore = CrashReportingSettingsStore(),
        quarantineLedgers: @escaping @MainActor () -> [QuarantinedRecord] = DiagnosticsViewModel.defaultQuarantineLedgers,
        appVersion: String = "\(KodBuildInfo.current().version) (\(KodBuildInfo.current().build))",
        osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
        architecture: String = KodBuildInfo.current().architecture
    ) {
        self.diagnosticsLog = diagnosticsLog
        self.crashReportingSettingsStore = crashReportingSettingsStore
        self.quarantineLedgers = quarantineLedgers
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.architecture = architecture
        self.crashReportingEnabled = crashReportingSettingsStore.load().isEnabled
    }

    /// Refreshes the on-screen event list/dropped-count from the shared
    /// log's redacted snapshot. Call from `.task`/
    /// `.onAppear` and again on a user-triggered "Refresh" action —
    /// this view never auto-polls in the background, matching this
    /// app's existing "explicit refresh over silent background timers"
    /// pattern for e.g. Source Control's status refresh.
    func refresh() async {
        events = await diagnosticsLog.redactedSnapshot()
        droppedCount = await diagnosticsLog.droppedCount
    }

    /// Assembles a fresh `SupportBundleContents` from the shared log and
    /// every reachable store's quarantine ledger (SPEC 15) — never
    /// touches the network.
    func generateSupportBundle() async throws -> SupportBundleContents {
        try await SupportBundleGenerator.generate(
            from: diagnosticsLog,
            quarantine: quarantineLedgers(),
            appVersion: appVersion,
            osVersion: osVersion,
            architecture: architecture
        )
    }

    /// Generates a fresh support bundle and writes it to `url` (a
    /// location the user chose via `NSSavePanel`, never a hardcoded
    /// path). Surfaces any failure into `lastExportErrorDescription` for
    /// the view to display, rather than throwing across the SwiftUI
    /// action boundary.
    func exportSupportBundle(to url: URL) async {
        do {
            let contents = try await generateSupportBundle()
            try SupportBundleGenerator.write(contents, to: url)
            lastExportErrorDescription = nil
        } catch {
            lastExportErrorDescription = String(describing: error)
        }
    }

    /// Aggregates `.quarantine.ledger()` across every store this app
    /// persists corrupt-state-quarantined metadata for (SPEC 15):
    /// `FontSettingsStore`/`ThemeStore`/`WorkspaceLayoutStore`. Each
    /// ledger lives in `UserDefaults` keyed independently of any one
    /// store instance, so freshly-constructed default-`UserDefaults`
    /// stores here read the same persisted ledger the app's real,
    /// already-open stores would.
    static func defaultQuarantineLedgers() -> [QuarantinedRecord] {
        ThemeStore().quarantine.ledger()
            + FontSettingsStore().quarantine.ledger()
            + WorkspaceLayoutStore().quarantine.ledger()
    }
}
