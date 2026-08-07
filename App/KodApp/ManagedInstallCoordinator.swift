import DiagnosticsCore
import Foundation
import ManagedLanguageServers

/// The app-facing controller for Kod-managed language-server installs
/// (SPEC 6.5/6.2): exposes each managed server's current
/// install/upgrade/rollback/remove state as a plain
/// `ManagedInstallStatusModel` for UI binding, and drives
/// `ManagedInstallController` (the `ManagedLanguageServers` actor that
/// actually owns the signed-catalog verification and on-disk install
/// pipeline) in response to explicit user actions only — this type
/// itself never starts a download without a caller first calling
/// `requestInstall`, which itself only proceeds after
/// `ManagedInstallController.grantConsent`.
///
/// A setup/install UI may bind to `status(for:)`/`onStatusChange`, but
/// per this task's constraints, that UI is validated only through this
/// headless coordinator, never through `KodAppUITests`/`XCUIApplication`.
@MainActor
public final class ManagedInstallCoordinator {
    private let controller: ManagedInstallController
    private var statuses: [String: ManagedInstallStatusModel] = [:]
    /// Shared, app-lifetime bounded diagnostics log (SPEC 15): every
    /// `.failed(message:)` lifecycle transition below is already
    /// surfaced in the (currently unwired) setup UI's status text; this
    /// additionally records it so a failed managed install/upgrade/
    /// rollback/remove survives into the Diagnostics viewer and support
    /// bundle, tagged with the fixed, non-identifying `serverID` (never
    /// a file path) and the failure's description as `.diagnosticMessage`.
    private let diagnosticsLog: BoundedEventLog

    public var onStatusChange: (() -> Void)?

    public init(controller: ManagedInstallController, diagnosticsLog: BoundedEventLog = BoundedEventLog()) {
        self.controller = controller
        self.diagnosticsLog = diagnosticsLog
    }

    public func status(for serverID: String) -> ManagedInstallStatusModel {
        statuses[serverID] ?? .notInstalled(serverID: serverID, language: nil)
    }

    /// Refreshes `status(for:)` from `ManagedInstallController`'s
    /// on-disk state — call after launch (once
    /// `recoverInterruptedOperations` has run) and whenever the setup UI
    /// becomes visible, so a version installed or removed by a prior
    /// launch is reflected without requiring an install/remove action
    /// to have happened in *this* session.
    public func refreshStatus(serverID: String, language: String?) async {
        do {
            if let record = try await controller.installedRecord(serverID: serverID) {
                setInstalled(record: record, language: language)
            } else {
                statuses[serverID] = .notInstalled(serverID: serverID, language: language)
            }
        } catch {
            statuses[serverID] = ManagedInstallStatusModel(serverID: serverID, language: language, lifecycle: .failed(message: String(describing: error)))
            await recordInstallFailure(serverID: serverID, operation: "refreshing install status", error: error)
        }
        onStatusChange?()
    }

    /// Installs (or upgrades to) `entry`'s version, recording consent
    /// first. Progress callbacks from `ManagedInstallController.install`
    /// update `status(for:)` live (downloading/verifying/extracting/
    /// activating) before the final installed-or-failed state.
    public func requestInstall(
        entry: ManagedServerCatalogEntry,
        architecture: ManagedInstallArchitecture,
        trustRoot: CatalogTrustRoot,
        cancellationToken: ManagedDownloadCancellationToken = ManagedDownloadCancellationToken()
    ) async {
        guard entry.artifact(for: architecture) != nil else {
            statuses[entry.serverID] = ManagedInstallStatusModel(serverID: entry.serverID, language: entry.language, lifecycle: .unsupportedArchitecture)
            onStatusChange?()
            return
        }

        do {
            try await controller.grantConsent(serverID: entry.serverID, version: entry.version, architecture: architecture)
        } catch {
            statuses[entry.serverID] = ManagedInstallStatusModel(serverID: entry.serverID, language: entry.language, lifecycle: .failed(message: String(describing: error)))
            await recordInstallFailure(serverID: entry.serverID, operation: "granting install consent", error: error)
            onStatusChange?()
            return
        }

        let progressSink = ProgressSink { [weak self] stage in
            Task { @MainActor in
                self?.apply(stage: stage, serverID: entry.serverID, language: entry.language)
            }
        }

        do {
            let record = try await controller.install(
                entry: entry,
                architecture: architecture,
                trustRoot: trustRoot,
                cancellationToken: cancellationToken,
                onProgress: { stage in progressSink.report(stage) }
            )
            setInstalled(record: record, language: entry.language)
        } catch {
            statuses[entry.serverID] = ManagedInstallStatusModel(serverID: entry.serverID, language: entry.language, lifecycle: .failed(message: String(describing: error)))
            await recordInstallFailure(serverID: entry.serverID, operation: "installing", error: error)
        }
        onStatusChange?()
    }

    public func rollback(serverID: String, language: String?) async {
        do {
            let record = try await controller.rollback(serverID: serverID)
            setInstalled(record: record, language: language)
        } catch {
            statuses[serverID] = ManagedInstallStatusModel(serverID: serverID, language: language, lifecycle: .failed(message: String(describing: error)))
            await recordInstallFailure(serverID: serverID, operation: "rolling back", error: error)
        }
        onStatusChange?()
    }

    public func remove(serverID: String, language: String?) async {
        do {
            try await controller.remove(serverID: serverID)
            statuses[serverID] = .notInstalled(serverID: serverID, language: language)
        } catch {
            statuses[serverID] = ManagedInstallStatusModel(serverID: serverID, language: language, lifecycle: .failed(message: String(describing: error)))
            await recordInstallFailure(serverID: serverID, operation: "removing", error: error)
        }
        onStatusChange?()
    }

    /// Records one warning-level diagnostic event for a failed managed
    /// install operation, tagging `serverID` under `.symbol` (a fixed
    /// catalog identifier, not user content) and the operation/error
    /// description under `.diagnosticMessage`.
    private func recordInstallFailure(serverID: String, operation: String, error: Error) async {
        await diagnosticsLog.record(
            subsystem: .managedInstall,
            level: .warning,
            message: Localized.string(
                "Managed language server install operation failed while \(operation)",
                comment: "Diagnostics log message recorded when a managed language server install operation fails, naming the operation that failed"
            ),
            context: [
                DiagnosticContextField(name: "serverID", category: .symbol, value: serverID),
                DiagnosticContextField(name: "reason", category: .diagnosticMessage, value: String(describing: error))
            ]
        )
    }

    private func setInstalled(record: InstalledServerRecord, language: String?) {
        statuses[record.serverID] = ManagedInstallStatusModel(
            serverID: record.serverID,
            language: language,
            lifecycle: .installed,
            installedVersion: record.version,
            installedArchitecture: record.architecture,
            installedExecutablePath: record.executableRelativePath,
            provenance: .managedInstall
        )
    }

    private func apply(stage: ManagedInstallStage, serverID: String, language: String?) {
        let lifecycle: ManagedInstallStatusModel.Lifecycle
        switch stage {
        case .downloading(let progress):
            lifecycle = .downloading(bytesReceived: progress.bytesReceived, expectedTotalBytes: progress.expectedTotalBytes)
        case .verifyingDigest:
            lifecycle = .verifyingDigest
        case .extracting:
            lifecycle = .extracting
        case .activating:
            lifecycle = .activating
        }
        statuses[serverID] = ManagedInstallStatusModel(serverID: serverID, language: language, lifecycle: lifecycle)
        onStatusChange?()
    }
}

/// A small `Sendable` box so a plain (non-`Sendable`) closure captured
/// by `install`'s `@Sendable onProgress` parameter can safely hop back
/// onto the main actor — mirrors the `DiscoveredArgumentsBox`/`LockedBox`
/// pattern already used elsewhere in this codebase for the same reason.
private final class ProgressSink: @unchecked Sendable {
    private let handler: (ManagedInstallStage) -> Void

    init(_ handler: @escaping (ManagedInstallStage) -> Void) {
        self.handler = handler
    }

    func report(_ stage: ManagedInstallStage) {
        handler(stage)
    }
}
