import DiagnosticsCore
import Foundation
import GitCore
import GitUI
import WorkspaceCore

/// Owns one workspace's optional, read-only `GitContext` and the immutable
/// presentation index derived from its latest status snapshot.
@MainActor
final class GitWorkspaceCoordinator {
    private(set) var context: GitContext?
    private(set) var latestStatus: GitStatusSnapshot?
    private(set) var presentationIndex = GitStatusPresentationIndex.empty
    private let root: URL
    private let onStatusChanged: (GitStatusSnapshot?) -> Void
    private let diagnosticsLog: BoundedEventLog

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
        } catch {
            context = nil
            await diagnosticsLog.record(
                subsystem: .git,
                level: .info,
                message: Localized.string(
                    "Opening the workspace's Git repository failed or found none",
                    comment: "Diagnostics log message recorded when opening a workspace's Git repository fails or finds none"
                ),
                context: [
                    DiagnosticContextField(name: "workspaceRoot", category: .fullPath, value: root.path),
                    DiagnosticContextField(name: "reason", category: .diagnosticMessage, value: String(describing: error))
                ]
            )
        }
        await refresh()
    }

    func refresh() async {
        guard let context else {
            publishStatus(nil)
            return
        }
        do {
            publishStatus(try await context.status())
        } catch {
            await diagnosticsLog.record(
                subsystem: .git,
                level: .warning,
                message: Localized.string("Git status refresh failed", comment: "Diagnostics log message recorded when a Git status refresh fails"),
                context: [
                    DiagnosticContextField(name: "workspaceRoot", category: .fullPath, value: root.path),
                    DiagnosticContextField(name: "reason", category: .diagnosticMessage, value: String(describing: error))
                ]
            )
            publishStatus(nil)
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
        await context.invalidate(Self.gitInvalidation(for: batch))
        await refresh()
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

    private func publishStatus(_ snapshot: GitStatusSnapshot?) {
        latestStatus = snapshot
        presentationIndex = GitStatusPresentationIndex(snapshot: snapshot)
        onStatusChanged(snapshot)
    }
}
