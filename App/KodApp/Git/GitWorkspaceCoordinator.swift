import DiagnosticsCore
import Foundation
import GitCore
import GitUI
import WorkspaceCore

/// Owns one workspace's optional, read-only `GitContext` and the immutable
/// presentation index derived from its latest status snapshot.
@MainActor
final class GitWorkspaceCoordinator {
    enum RepositoryState: Equatable {
        case loading
        case noRepository
        case available(
            location: GitRepositoryLocation,
            status: GitStatusSnapshot
        )
        case unavailable(
            location: GitRepositoryLocation?,
            reason: String
        )
    }

    private(set) var context: GitContext?
    private(set) var repositoryState: RepositoryState = .loading
    private(set) var latestStatus: GitStatusSnapshot?
    private(set) var presentationIndex = GitStatusPresentationIndex.empty
    private let root: URL
    private let onStatusChanged: (GitStatusSnapshot?) -> Void
    private let diagnosticsLog: BoundedEventLog
    private var refreshGeneration: UInt64 = 0

    /// `true` once `start()` has run, regardless of whether a repository
    /// was found.
    private(set) var hasStarted = false

    init(
        root: URL,
        diagnosticsLog: BoundedEventLog,
        onStatusChanged: @escaping (GitStatusSnapshot?) -> Void = { _ in }
    ) {
        self.root = root
        self.diagnosticsLog = diagnosticsLog
        self.onStatusChanged = onStatusChanged
    }

    func start() async {
        hasStarted = true
        do {
            context = try await GitContext.open(at: root)
        } catch let error as GitRepositoryLocatorError {
            context = nil
            switch error {
            case .notARepository:
                publish(.noRepository)
            case .processFailed, .malformedOutput:
                publish(
                    .unavailable(
                        location: nil,
                        reason: String(describing: error)
                    )
                )
            }
            await recordOpenFailure(error: error)
            return
        } catch {
            context = nil
            publish(.unavailable(location: nil, reason: String(describing: error)))
            await recordOpenFailure(error: error)
            return
        }
        await refresh()
    }

    func refresh() async {
        refreshGeneration &+= 1
        await refresh(generation: refreshGeneration)
    }

    private func refresh(generation: UInt64) async {
        guard let context else {
            if generation == refreshGeneration,
               case .loading = repositoryState {
                publish(.noRepository)
            }
            return
        }
        do {
            let location = try await context.refreshLocation()
            let status = try await context.status()
            guard generation == refreshGeneration else {
                return
            }
            publish(.available(location: location, status: status))
        } catch {
            let location = await context.location
            guard generation == refreshGeneration else {
                return
            }
            await diagnosticsLog.record(
                subsystem: .git,
                level: .warning,
                message: Localized.string("Git status refresh failed", comment: "Diagnostics log message recorded when a Git status refresh fails"),
                context: [
                    DiagnosticContextField(name: "workspaceRoot", category: .fullPath, value: root.path),
                    DiagnosticContextField(name: "reason", category: .diagnosticMessage, value: String(describing: error))
                ]
            )
            guard generation == refreshGeneration else {
                return
            }
            publish(
                .unavailable(
                    location: location,
                    reason: String(describing: error)
                )
            )
        }
    }

    static func gitInvalidation(
        for batch: WorkspaceChangeBatch
    ) -> GitRepositoryInvalidation {
        GitRepositoryInvalidation(changedPaths: batch.paths.map(\.path))
    }

    /// Translates the workspace's existing FSEvents batch into GitCore's
    /// repository-owned invalidation before loading a fresh snapshot.
    func handle(_ batch: WorkspaceChangeBatch) async {
        guard let context else {
            return
        }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        await context.invalidate(Self.gitInvalidation(for: batch))
        await refresh(generation: generation)
    }

    func explorerDecoration(
        forRelativePath relativePath: String,
        isDirectory: Bool
    ) -> GitExplorerDecoration? {
        presentationIndex.explorerDecoration(
            forRelativePath: relativePath,
            isDirectory: isDirectory
        )
    }

    private func publish(_ state: RepositoryState) {
        repositoryState = state
        let snapshot: GitStatusSnapshot?
        switch state {
        case .available(_, let status):
            snapshot = status
        case .loading, .noRepository, .unavailable:
            snapshot = nil
        }
        latestStatus = snapshot
        presentationIndex = GitStatusPresentationIndex(snapshot: snapshot)
        onStatusChanged(snapshot)
    }

    private func recordOpenFailure(error: Error) async {
        await diagnosticsLog.record(
            subsystem: .git,
            level: .info,
            message: Localized.string(
                "Opening the workspace's Git repository failed or found none",
                comment: "Diagnostics log message recorded when opening a workspace's Git repository fails or finds none"
            ),
            context: [
                DiagnosticContextField(
                    name: "workspaceRoot",
                    category: .fullPath,
                    value: root.path
                ),
                DiagnosticContextField(
                    name: "reason",
                    category: .diagnosticMessage,
                    value: String(describing: error)
                )
            ]
        )
    }
}
