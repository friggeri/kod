import Foundation
import SourceModel

// Diagnostic delivery (SPEC 6.3): accepting server push notifications,
// running the coalesced `workspace/diagnostic` pull, and applying the
// raw-vs-normalized routing policy. The sequencing and freshness rules
// themselves live in `LanguageDiagnosticsCoordinator`; this file is the
// actor-isolated orchestration around them.

extension LanguageWorkspaceService {
    // MARK: - Server notifications and diagnostics

    func handleServerNotification(
        _ notification: ServerNotification,
        generation: Int
    ) async {
        guard generation == connectionGeneration else {
            return
        }
        switch notification {
        case .workspaceDiagnosticRefresh:
            await scheduleWorkspaceDiagnostics(generation: generation)
        case .publishDiagnostics(let params):
            await handlePublishedDiagnostics(params, generation: generation)
        case .progress, .logMessage, .showMessage, .unknown:
            break
        }
    }

    func handlePublishedDiagnostics(
        _ params: PublishDiagnosticsParams,
        generation: Int
    ) async {
        guard let url = confinement.confinedFileURL(for: params.uri) else {
            return
        }
        // Versioned reports for open files must match the live snapshot.
        // Unopened files have no client-side version to compare and are
        // accepted when their file URI remains inside the trusted workspace.
        guard documents.acceptsReportedVersion(params.version, for: url) else {
            return
        }
        await publishDiagnostics(
            url: url,
            diagnostics: params.diagnostics,
            generation: generation
        )
    }

    /// Applies the raw-vs-normalized routing policy for one accepted
    /// report: raw diagnostics always reach the workspace-wide store,
    /// whether or not Kod has the file open; normalization additionally
    /// runs for open documents so editors get snapshot-validated markers.
    func publishDiagnostics(
        url: URL,
        diagnostics: [Diagnostic],
        generation: Int
    ) async {
        onDiagnostics(url, diagnostics)
        switch LanguageDiagnosticsCoordinator.routing(
            isDocumentOpen: documents.isTracked(url)
        ) {
        case .rawOnly:
            return
        case .rawAndNormalized:
            await publishNormalizedDiagnostics(
                url: url,
                diagnostics: diagnostics,
                generation: generation
            )
        }
    }

    /// Converts `diagnostics` against the exact snapshot that is open for
    /// `url` right now and forwards them to `onNormalizedDiagnostics`.
    /// No-ops for files that are not open: an unopened workspace file has
    /// no `SourceSnapshot` to validate against, and its problems remain
    /// raw-only. The publish ticket, the connection generation and the
    /// snapshot version are all re-checked after the normalization
    /// suspension point so a close, a `didChange`, a restart, or a newer
    /// same-version publish can never be overwritten by an older
    /// in-flight normalization.
    func publishNormalizedDiagnostics(
        url: URL,
        diagnostics: [Diagnostic],
        generation: Int
    ) async {
        guard let snapshot = documents.snapshot(for: url) else {
            return
        }
        let ticket = diagnosticsCoordinator.beginPublish(for: url)
        let encoding = await resolvedPositionEncoding()
        await diagnosticNormalizationYield()
        guard generation == connectionGeneration,
              let currentSnapshot = documents.snapshot(for: url),
              currentSnapshot.version == snapshot.version,
              diagnosticsCoordinator.isCurrent(ticket) else {
            return
        }
        diagnosticsCoordinator.completePublish(ticket)
        onNormalizedDiagnostics(
            url,
            LSPRangeNormalizer.normalizedDiagnostics(
                diagnostics,
                snapshot: snapshot,
                encoding: encoding
            )
        )
    }

    /// Invalidates one document's editor markers: any in-flight
    /// normalization for it is superseded, stored wire diagnostics may no
    /// longer be re-normalized against it until the server publishes
    /// again, and the current markers are cleared.
    func clearNormalizedDiagnostics(for url: URL) {
        diagnosticsCoordinator.invalidate(url: url)
        onNormalizedDiagnostics(url, [])
    }

    func clearNormalizedDiagnosticsForOpenDocuments() {
        for url in documents.trackedURLs {
            clearNormalizedDiagnostics(for: url)
        }
    }

    func scheduleWorkspaceDiagnostics(generation: Int) async {
        guard generation == connectionGeneration,
              let connection,
              await connection.serverCapabilities?.diagnosticProvider?.workspaceDiagnostics == true else {
            return
        }
        workspaceDiagnosticTask?.cancel()
        workspaceDiagnosticTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else {
                    return
                }
                await self?.performWorkspaceDiagnostics(
                    connection: connection,
                    generation: generation
                )
            } catch {
                // Cancellation is the expected coalescing path.
            }
        }
    }

    func performWorkspaceDiagnostics(
        connection: LanguageServerConnection,
        generation: Int
    ) async {
        guard generation == connectionGeneration, self.connection === connection else {
            return
        }
        let previousResultIDs = diagnosticsCoordinator.previousResultIDs
        let identifier = await connection.serverCapabilities?.diagnosticProvider?.identifier
        do {
            let report: WorkspaceDiagnosticReport = try await connection.sendRequest(
                .workspaceDiagnostic,
                params: WorkspaceDiagnosticParams(
                    identifier: identifier,
                    previousResultIds: previousResultIDs
                ),
                priority: .background
            )
            try Task.checkCancellation()
            guard generation == connectionGeneration, self.connection === connection else {
                return
            }
            for item in report.items {
                guard let url = confinement.confinedFileURL(for: item.uri) else {
                    continue
                }
                guard documents.acceptsReportedVersion(item.version, for: url) else {
                    continue
                }
                diagnosticsCoordinator.recordResultID(
                    item.resultId,
                    kind: item.kind,
                    for: url
                )
                if item.kind == .full {
                    await publishDiagnostics(
                        url: url,
                        diagnostics: item.items ?? [],
                        generation: generation
                    )
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == connectionGeneration, self.connection === connection else {
                return
            }
            onWorkspaceDiagnosticsFailure(String(describing: error))
        }
    }

    func cancelWorkspaceDiagnostics(resetResultIDs: Bool) {
        workspaceDiagnosticTask?.cancel()
        workspaceDiagnosticTask = nil
        if resetResultIDs {
            diagnosticsCoordinator.resetResultIDs()
        }
    }

    /// Cancellation-complete counterpart used by `stop()`/`restart()`:
    /// the pull task is cancelled *and* awaited, so no workspace
    /// diagnostics request is still in flight when they return.
    func cancelWorkspaceDiagnosticsAwaitingCompletion(
        resetResultIDs: Bool
    ) async {
        let task = workspaceDiagnosticTask
        workspaceDiagnosticTask = nil
        task?.cancel()
        await task?.value
        if resetResultIDs {
            diagnosticsCoordinator.resetResultIDs()
        }
    }
}
