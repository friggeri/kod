import SettingsCore
import XCTest
@testable import DiagnosticsCore

final class CrashReportingTests: XCTestCase {
    @MainActor
    private func makeStore() -> (
        CrashReportingSettingsStore,
        CodableSettingsRepository,
        InMemorySettingsKeyValueStore
    ) {
        let keyValueStore = InMemorySettingsKeyValueStore()
        let repository = CodableSettingsRepository(store: keyValueStore)
        return (
            CrashReportingSettingsStore(repository: repository),
            repository,
            keyValueStore
        )
    }

    @MainActor
    func testCrashReportingIsAbsentUntilUserMakesAChoice() throws {
        let (store, _, _) = makeStore()
        XCTAssertEqual(try store.load(), .absent)
    }

    @MainActor
    func testSavingAndLoadingSettingsRoundTrips() throws {
        let (store, _, _) = makeStore()

        try store.save(CrashReportingSettings(isEnabled: true))

        guard case .value(let settings, _) = try store.load() else {
            return XCTFail("Expected saved settings")
        }
        XCTAssertTrue(settings.isEnabled)
    }

    @MainActor
    func testLegacyUnenvelopedSettingsMigrate() throws {
        let (store, _, keyValueStore) = makeStore()
        let settings = CrashReportingSettings(isEnabled: true)
        try keyValueStore.setValue(
            .data(try JSONEncoder().encode(settings)),
            forKey: "kod.diagnostics.crash-reporting-settings"
        )

        XCTAssertEqual(
            try store.load(),
            .value(
                settings,
                provenance: .migrated(
                    from: .unversioned,
                    toVersion: 1
                )
            )
        )
    }

    @MainActor
    func testCorruptSettingsAreExplicitlyQuarantined() throws {
        let (store, repository, keyValueStore) = makeStore()
        try keyValueStore.setValue(
            .data(Data("not json".utf8)),
            forKey: "kod.diagnostics.crash-reporting-settings"
        )

        guard case .quarantined(let record) = try store.load() else {
            return XCTFail("Expected quarantine")
        }

        XCTAssertEqual(
            record.key,
            "kod.diagnostics.crash-reporting-settings"
        )
        XCTAssertEqual(try repository.quarantine.records(), [record])
    }

    @MainActor
    func testUploadCoordinatorNeverInvokesTransportWhenReportingAbsent() async throws {
        let (store, _, _) = makeStore()
        let transport = RecordingCrashReportTransport()
        let coordinator = CrashReportUploadCoordinator(
            settingsStore: store,
            transport: transport
        )

        do {
            try await coordinator.upload(CrashReport(redactedPayload: Data()))
            XCTFail("expected reportingDisabled error")
        } catch CrashReportUploadError.reportingDisabled {
            // Expected.
        }

        let sent = await transport.sentReports
        XCTAssertTrue(sent.isEmpty)
    }

    @MainActor
    func testUploadCoordinatorInvokesTransportOnlyAfterExplicitOptIn() async throws {
        let (store, _, _) = makeStore()
        try store.save(CrashReportingSettings(isEnabled: true))
        let transport = RecordingCrashReportTransport()
        let coordinator = CrashReportUploadCoordinator(
            settingsStore: store,
            transport: transport
        )
        let report = CrashReport(
            redactedPayload: Data("redacted-payload".utf8)
        )

        try await coordinator.upload(report)

        let sent = await transport.sentReports
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].report.identifier, report.identifier)
        XCTAssertEqual(sent[0].attribution, .crashReport)
    }

    @MainActor
    func testDefaultTransportIsNoopAndNeverThrows() async throws {
        let transport = NoopCrashReportTransport()
        try await transport.send(
            CrashReport(redactedPayload: Data()),
            attribution: .crashReport
        )
    }

    func testNetworkAttributionCasesAllHaveUserFacingDescriptions() {
        for attribution in NetworkAttribution.allCases {
            XCTAssertFalse(attribution.userFacingDescription.isEmpty)
        }
    }
}
