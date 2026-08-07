import XCTest
@testable import DiagnosticsCore

final class CrashReportingTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suiteName = "diagnostics-core-crash-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @MainActor
    func testCrashReportingDefaultsToDisabled() {
        let store = CrashReportingSettingsStore(defaults: freshDefaults())
        XCTAssertFalse(store.load().isEnabled)
    }

    @MainActor
    func testSavingAndLoadingSettingsRoundTrips() {
        let defaults = freshDefaults()
        let store = CrashReportingSettingsStore(defaults: defaults)

        store.save(CrashReportingSettings(isEnabled: true))

        XCTAssertTrue(store.load().isEnabled)
    }

    @MainActor
    func testCorruptSettingsQuarantineFallsBackToDisabled() {
        let defaults = freshDefaults()
        defaults.set(Data("not json".utf8), forKey: "kod.diagnostics.crash-reporting-settings")
        let store = CrashReportingSettingsStore(defaults: defaults)
        let quarantine = CorruptStateQuarantine(defaults: defaults)

        let settings = store.load(quarantine: quarantine)

        XCTAssertFalse(settings.isEnabled, "a corrupt setting must fail safe to disabled, never silently enabled")
        XCTAssertEqual(quarantine.ledger().count, 1)
    }

    @MainActor
    func testUploadCoordinatorNeverInvokesTransportWhenReportingDisabled() async throws {
        let defaults = freshDefaults()
        let store = CrashReportingSettingsStore(defaults: defaults)
        store.save(CrashReportingSettings(isEnabled: false))
        let transport = RecordingCrashReportTransport()
        let coordinator = CrashReportUploadCoordinator(settingsStore: store, transport: transport)

        do {
            try await coordinator.upload(CrashReport(redactedPayload: Data()))
            XCTFail("expected reportingDisabled error")
        } catch CrashReportUploadError.reportingDisabled {
            // expected
        }

        let sent = await transport.sentReports
        XCTAssertTrue(sent.isEmpty, "transport must never be invoked while reporting is disabled")
    }

    @MainActor
    func testUploadCoordinatorInvokesTransportOnlyAfterExplicitOptIn() async throws {
        let defaults = freshDefaults()
        let store = CrashReportingSettingsStore(defaults: defaults)
        store.save(CrashReportingSettings(isEnabled: true))
        let transport = RecordingCrashReportTransport()
        let coordinator = CrashReportUploadCoordinator(settingsStore: store, transport: transport)
        let report = CrashReport(redactedPayload: Data("redacted-payload".utf8))

        try await coordinator.upload(report)

        let sent = await transport.sentReports
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].report.identifier, report.identifier)
        XCTAssertEqual(sent[0].attribution, .crashReport)
    }

    @MainActor
    func testDefaultTransportIsNoopAndNeverThrows() async throws {
        let transport = NoopCrashReportTransport()
        try await transport.send(CrashReport(redactedPayload: Data()), attribution: .crashReport)
        // No assertion needed beyond "did not throw" and "did not crash":
        // the noop transport's entire contract is doing nothing.
    }

    func testNetworkAttributionCasesAllHaveUserFacingDescriptions() {
        for attribution in NetworkAttribution.allCases {
            XCTAssertFalse(attribution.userFacingDescription.isEmpty)
        }
    }
}
