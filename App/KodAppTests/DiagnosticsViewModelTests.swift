import DiagnosticsCore
import SettingsCore
import XCTest
@testable import Kod

/// Headless coverage for `DiagnosticsViewModel` (SPEC 15): the
/// Diagnostics settings tab's view-model must only ever expose
/// `redactedSnapshot()` (never raw `events`), support-bundle export must
/// produce a manifest whose counts match reality and actually write a
/// file, and the crash-reporting toggle must default to off, persist
/// across a store reload, and never invoke any transport unless the
/// user explicitly opted in first.
@MainActor
final class DiagnosticsViewModelTests: XCTestCase {
    private func makeRepository() -> CodableSettingsRepository {
        CodableSettingsRepository(
            store: InMemorySettingsKeyValueStore()
        )
    }

    // MARK: - Redaction-only guarantee

    /// Feeds a raw, obviously-sensitive absolute path into the shared
    /// log (tagged `.fullPath`, exactly like the real call sites in
    /// `GitWorkspaceCoordinator`/`SearchSidebarViewController` do), then
    /// asserts the view-model's displayed `events`/`filteredEvents`
    /// never contain that raw path — only ever the redacted placeholder
    /// `redactedSnapshot()` already produces.
    func testDisplayedEventsAreAlwaysTheRedactedSnapshotNeverRawContent() async throws {
        let log = BoundedEventLog()
        let rawSensitivePath = "/Users/definitely-a-real-person/Secret Project/main.swift"
        await log.record(
            subsystem: .git,
            level: .warning,
            message: "Git status refresh failed",
            context: [
                DiagnosticContextField(name: "workspaceRoot", category: .fullPath, value: rawSensitivePath)
            ]
        )

        let repository = makeRepository()
        let model = try DiagnosticsViewModel(
            diagnosticsLog: log,
            crashReportingSettingsStore: CrashReportingSettingsStore(
                repository: repository
            ),
            settingsQuarantine: repository.quarantine
        )
        await model.refresh()

        XCTAssertFalse(model.events.isEmpty)
        for event in model.events {
            for field in event.context {
                XCTAssertFalse(field.value.contains(rawSensitivePath), "Raw sensitive content must never reach the view-model's displayed events")
                XCTAssertFalse(field.value.contains("definitely-a-real-person"), "Raw sensitive content must never reach the view-model's displayed events")
            }
        }
        XCTAssertTrue(model.events.allSatisfy { event in
            event.context.allSatisfy { $0.category != .fullPath || $0.value == "<path redacted>" }
        })

        // Also true of the level-filtered projection the view actually renders.
        for event in model.filteredEvents {
            for field in event.context {
                XCTAssertFalse(field.value.contains(rawSensitivePath))
            }
        }
    }

    func testDroppedCountIsExposedWhenTheLogExceedsCapacity() async throws {
        let log = BoundedEventLog(capacity: 2)
        for index in 0..<5 {
            await log.record(subsystem: .app, level: .debug, message: "event \(index)")
        }
        let repository = makeRepository()
        let model = try DiagnosticsViewModel(
            diagnosticsLog: log,
            crashReportingSettingsStore: CrashReportingSettingsStore(
                repository: repository
            ),
            settingsQuarantine: repository.quarantine
        )
        await model.refresh()
        XCTAssertGreaterThan(model.droppedCount, 0)
    }

    // MARK: - Support-bundle export

    func testSupportBundleGenerationManifestCountsMatchAndWriteSucceeds() async throws {
        let log = BoundedEventLog()
        await log.record(subsystem: .search, level: .warning, message: "Workspace search failed")
        await log.record(subsystem: .git, level: .info, message: "Opening the workspace's Git repository failed or found none")

        let quarantineRecord = QuarantinedRecord(key: "test.key", reason: "corrupt", quarantinedAt: Date(), byteCount: 12)
        let keyValueStore = InMemorySettingsKeyValueStore(
            initialValues: [
                SettingsQuarantine.defaultLedgerKey: .data(
                    try JSONEncoder().encode([quarantineRecord])
                )
            ]
        )
        let repository = CodableSettingsRepository(store: keyValueStore)
        let model = try DiagnosticsViewModel(
            diagnosticsLog: log,
            crashReportingSettingsStore: CrashReportingSettingsStore(
                repository: repository
            ),
            settingsQuarantine: repository.quarantine,
            appVersion: "1.0 (test)",
            osVersion: "Test OS 1.0",
            architecture: "test-arch"
        )

        let contents = try await model.generateSupportBundle()
        XCTAssertEqual(contents.manifest.eventCount, contents.redactedEvents.count)
        XCTAssertEqual(contents.manifest.eventCount, 2)
        XCTAssertEqual(contents.manifest.quarantinedRecordCount, 1)
        XCTAssertEqual(contents.manifest.quarantinedRecordCount, contents.quarantinedRecords.count)
        XCTAssertEqual(contents.manifest.appVersion, "1.0 (test)")
        XCTAssertEqual(contents.manifest.osVersion, "Test OS 1.0")
        XCTAssertEqual(contents.manifest.architecture, "test-arch")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DiagnosticsViewModelTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        await model.exportSupportBundle(to: url)
        XCTAssertNil(model.lastExportErrorDescription)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SupportBundleContents.self, from: data)
        XCTAssertEqual(decoded.manifest.eventCount, 2)
    }

    // MARK: - Crash-reporting toggle

    func testCrashReportingDefaultsToOffAndPersistsAcrossReload() throws {
        let repository = makeRepository()
        let log = BoundedEventLog()

        let firstModel = try DiagnosticsViewModel(
            diagnosticsLog: log,
            crashReportingSettingsStore: CrashReportingSettingsStore(
                repository: repository
            ),
            settingsQuarantine: repository.quarantine
        )
        XCTAssertFalse(firstModel.crashReportingEnabled, "Crash reporting must default to off")

        firstModel.crashReportingEnabled = true

        // A freshly reloaded model (mirroring the app being relaunched)
        // must observe the persisted, explicitly-opted-in value.
        let reloadedModel = try DiagnosticsViewModel(
            diagnosticsLog: log,
            crashReportingSettingsStore: CrashReportingSettingsStore(
                repository: repository
            ),
            settingsQuarantine: repository.quarantine
        )
        XCTAssertTrue(reloadedModel.crashReportingEnabled, "The opt-in must persist across a store reload")
    }

    func testUploadCoordinatorNeverInvokesTransportUnlessToggleWasExplicitlyEnabled() async throws {
        let repository = makeRepository()
        let settingsStore = CrashReportingSettingsStore(
            repository: repository
        )
        let transport = RecordingCrashReportTransport()
        let coordinator = CrashReportUploadCoordinator(settingsStore: settingsStore, transport: transport)
        let report = CrashReport(redactedPayload: Data("<redacted>".utf8))

        // Toggle left at its default (off): every upload attempt must
        // fail with `.reportingDisabled` and the transport must remain
        // untouched.
        do {
            try await coordinator.upload(report)
            XCTFail("Expected .reportingDisabled while crash reporting is off")
        } catch CrashReportUploadError.reportingDisabled {
            // expected
        }
        var sent = await transport.sentReports
        XCTAssertTrue(sent.isEmpty, "RecordingCrashReportTransport must stay empty while opted out")

        // Only after an explicit opt-in does the coordinator invoke the transport.
        try settingsStore.save(CrashReportingSettings(isEnabled: true))
        try await coordinator.upload(report)
        sent = await transport.sentReports
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.attribution, .crashReport)
    }
}
