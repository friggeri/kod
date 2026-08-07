import DiagnosticsCore
import Foundation
import GitCore
import WorkspaceCore

/// Owns one workspace's `GitContext` (if the workspace root is inside a
/// Git repository/worktree at all — SPEC 9: "Git integration is
/// read-only and optional for non-Git folders") and keeps its status
/// snapshot fresh as the workspace's existing FSEvents pipeline reports
/// changes.
///
/// This type is deliberately AppKit-free so `GitWorkspaceCoordinatorTests`
/// can drive it directly without a window, view, or any UI automation.
@MainActor
final class GitWorkspaceCoordinator {
    private(set) var context: GitContext?
    private(set) var latestStatus: GitStatusSnapshot?
    private let root: URL
    private let onStatusChanged: (GitStatusSnapshot?) -> Void
    /// Shared, app-lifetime bounded diagnostics log (SPEC 15): a failed
    /// repository open or status refresh is an "explicit failure path"
    /// this workspace's Git integration already tolerates gracefully
    /// (falling back to "not a Git repository"/stale status), but which
    /// is worth recording for the Diagnostics viewer/support bundle
    /// rather than only ever being swallowed by `try?`.
    private let diagnosticsLog: BoundedEventLog

    /// `true` once `start()` has run, regardless of whether a repository
    /// was actually found — lets callers distinguish "not yet checked"
    /// from "checked, and this folder isn't a Git repository".
    private(set) var hasStarted = false

    init(
        root: URL,
        diagnosticsLog: BoundedEventLog = BoundedEventLog(),
        onStatusChanged: @escaping (GitStatusSnapshot?) -> Void = { _ in }
    ) {
        self.root = root
        self.diagnosticsLog = diagnosticsLog
        self.onStatusChanged = onStatusChanged
    }

    /// Resolves this workspace's repository (a no-op, non-fatal outcome
    /// if `root` is not inside one) and loads an initial status snapshot.
    func start() async {
        hasStarted = true
        do {
            context = try await GitContext.open(at: root)
        } catch {
            context = nil
            // Not every workspace is a Git repository — only record a
            // diagnostic when opening failed with something other than
            // "no repository here", which the doc comment above already
            // treats as the normal, non-fatal path. `GitContext.open`
            // doesn't distinguish the two in its throw shape today, so
            // this records every open failure at `.info` (not
            // `.warning`/`.error`) to avoid over-alarming for the common
            // "just not a Git folder" case while still keeping a bounded
            // trail for genuine repository-open problems.
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
            latestStatus = nil
            onStatusChanged(nil)
            return
        }
        do {
            latestStatus = try await context.status()
        } catch {
            latestStatus = nil
            await diagnosticsLog.record(
                subsystem: .git,
                level: .warning,
                message: Localized.string("Git status refresh failed", comment: "Diagnostics log message recorded when a Git status refresh fails"),
                context: [
                    DiagnosticContextField(name: "workspaceRoot", category: .fullPath, value: root.path),
                    DiagnosticContextField(name: "reason", category: .diagnosticMessage, value: String(describing: error))
                ]
            )
        }
        onStatusChanged(latestStatus)
    }

    /// Wired to the same `WorkspaceFileWatcher(onBatch:)` callback that
    /// already drives Explorer/index live updates (SPEC 5.6), so Git
    /// status recomputes on the same change signal rather than its own
    /// separate watcher.
    func handle(_ batch: WorkspaceChangeBatch) async {
        guard let context else {
            return
        }
        await context.invalidate(for: batch)
        await refresh()
    }

    func statusEntry(forRelativePath relativePath: String) -> GitStatusEntry? {
        latestStatus?.entry(forPath: relativePath)
    }

    /// Test-only seam: sets the in-memory status snapshot directly,
    /// bypassing `GitContext`/a real Git process entirely, so
    /// `badge(forRelativePath:)`'s classification logic can be exercised
    /// against hand-built `GitStatusEntry` fixtures headlessly.
    func applyTestSnapshot(_ snapshot: GitStatusSnapshot) {
        latestStatus = snapshot
    }

    /// A single-character Explorer badge for `relativePath`, or `nil` for
    /// an unmodified/untracked-by-Git-status path. Ignored files
    /// intentionally report no badge letter (Explorer already dims them
    /// via existing ignore-rule presentation) to avoid a second, competing
    /// visual signal.
    func badge(forRelativePath relativePath: String) -> GitExplorerBadge? {
        guard let entry = statusEntry(forRelativePath: relativePath) else {
            return nil
        }
        if entry.isConflicted {
            return .conflicted
        }
        switch entry.shape {
        case .untracked:
            return .untracked
        case .ignored:
            return nil
        case .renameOrCopy:
            return .renamed
        case .unmerged:
            return .conflicted
        case .ordinary(let indexStatus, let worktreeStatus):
            let effective = worktreeStatus != .unmodified ? worktreeStatus : indexStatus
            switch effective {
            case .added:
                return .added
            case .deleted:
                return .deleted
            case .modified, .typeChanged:
                return .modified
            case .unmodified, .renamed, .copied, .updatedButUnmerged:
                return nil
            }
        }
    }
}

/// The Explorer badge kinds SPEC 9.1 asks for ("Explorer badges and
/// inline added/modified/deleted gutter markers"), plus renamed/
/// conflicted/untracked since those are equally part of SPEC 9.1's
/// file-status grouping. Each maps to one of `GitDecorationColors`'
/// four theme colors (renamed reuses `.modified`'s color, matching most
/// editors' convention that a rename is a kind of modification).
enum GitExplorerBadge: Equatable {
    case added
    case modified
    case deleted
    case renamed
    case untracked
    case conflicted

    var letter: String {
        switch self {
        case .added: return Localized.string("A", comment: "Single-letter Explorer badge for an added file's Git status")
        case .modified: return Localized.string("M", comment: "Single-letter Explorer badge for a modified file's Git status")
        case .deleted: return Localized.string("D", comment: "Single-letter Explorer badge for a deleted file's Git status")
        case .renamed: return Localized.string("R", comment: "Single-letter Explorer badge for a renamed file's Git status")
        case .untracked: return Localized.string("U", comment: "Single-letter Explorer badge for an untracked file's Git status")
        case .conflicted: return "!"
        }
    }

    /// A full-word description of this badge, so Explorer rows can expose
    /// their Git status as text to VoiceOver rather than relying on the
    /// single-letter badge or its color alone (SPEC 14: "No status is
    /// communicated by color alone").
    var accessibilityDescription: String {
        switch self {
        case .added: return Localized.string("Added", comment: "Accessibility description for an added file's Git status")
        case .modified: return Localized.string("Modified", comment: "Accessibility description for a modified file's Git status")
        case .deleted: return Localized.string("Deleted", comment: "Accessibility description for a deleted file's Git status")
        case .renamed: return Localized.string("Renamed", comment: "Accessibility description for a renamed file's Git status")
        case .untracked: return Localized.string("Untracked", comment: "Accessibility description for an untracked file's Git status")
        case .conflicted: return Localized.string("Conflicted", comment: "Accessibility description for a conflicted file's Git status")
        }
    }
}
