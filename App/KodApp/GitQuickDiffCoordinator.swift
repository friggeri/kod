import AppKit
import CodeViewport
import DiagnosticsCore
import EditorUI
import GitCore
import GitUI
import SourceIO
import SourceModel
import WorkspaceCore

/// Tracks one monotonically increasing generation per Quick Diff request
/// channel. Each consumer (the Source Control sidebar selection, the
/// visible editors' gutters) owns its own channel, so cancelling or
/// superseding one never invalidates in-flight work for the other.
struct GitQuickDiffRequestRegistry {
    enum Channel: Hashable, CaseIterable {
        case sidebarSelection
        case visibleEditors
    }

    private var generations: [Channel: Int] = [:]

    /// Starts a new request on `channel`, invalidating any older one.
    mutating func begin(_ channel: Channel) -> Int {
        let generation = (generations[channel] ?? 0) + 1
        generations[channel] = generation
        return generation
    }

    /// Invalidates whatever is in flight on `channel` without starting a
    /// replacement.
    mutating func invalidate(_ channel: Channel) {
        generations[channel] = (generations[channel] ?? 0) + 1
    }

    func generation(for channel: Channel) -> Int {
        generations[channel] ?? 0
    }

    func isCurrent(_ generation: Int, in channel: Channel) -> Bool {
        self.generation(for: channel) == generation
    }
}

/// The single policy for turning a `GitFileDiff` into what Quick Diff
/// shows — which provider/label a diff belongs to, and the exact message
/// used when an inline diff cannot be rendered. Shared by both consumers
/// so a conflicted, binary or empty diff reads identically whether it was
/// opened from the Source Control sidebar or decorates a visible editor.
enum GitQuickDiffPolicy {
    enum Role {
        case workingTree
        case index
        case workingTreeAgainstHead
    }

    static func role(for target: GitDiffTarget) -> Role {
        switch target {
        case .indexVsHead:
            return .index
        case .workingTreeVsIndex:
            return .workingTree
        case .workingTreeVsHead:
            return .workingTreeAgainstHead
        }
    }

    static func provider(for role: Role) -> GitQuickDiffProvider {
        switch role {
        case .workingTree:
            return .workingTree
        case .index:
            return .staged
        case .workingTreeAgainstHead:
            return GitQuickDiffProvider(id: "working-tree-head", source: .head)
        }
    }

    static func label(for role: Role) -> String {
        switch role {
        case .index:
            return Localized.string(
                "Index",
                comment: "Quick Diff provider label for staged index changes"
            )
        case .workingTree:
            return Localized.string(
                "Working Tree",
                comment: "Quick Diff provider label for unstaged working-tree changes"
            )
        case .workingTreeAgainstHead:
            return Localized.string(
                "Working Tree",
                comment: "Quick Diff provider label for working-tree changes against HEAD"
            )
        }
    }

    /// Projects `diff` for `role`, optionally hiding marks already shown by
    /// a primary layer so a staged overlay never double-marks a line.
    static func source(
        diff: GitFileDiff,
        role: Role,
        layer: CodeGutterChange.Layer,
        suppressingMarksOverlapping primary: GitQuickDiffSource? = nil
    ) -> GitQuickDiffSource {
        var projection = GitQuickDiffProjection.project(
            diff,
            provider: provider(for: role)
        )
        if let primary {
            projection = projection.suppressingMarks(
                overlapping: primary.projection
            )
        }
        return GitQuickDiffSource(
            label: label(for: role),
            diff: diff,
            projection: projection,
            layer: layer
        )
    }

    static var conflictedMessage: String {
        Localized.string(
            "Inline Git changes are unavailable while this file has unresolved conflicts.",
            comment: "Message shown instead of Quick Diff for a merge-conflicted file"
        )
    }

    static var binaryMessage: String {
        Localized.string(
            "Binary files do not have an inline text diff.",
            comment: "Message shown when Quick Diff cannot render a binary file"
        )
    }

    static var noInlineDifferencesMessage: String {
        Localized.string(
            "This change has no inline line differences.",
            comment: "Message shown when a Git change has metadata but no textual hunks"
        )
    }

    static var loadFailureMessage: String {
        Localized.string(
            "Git diff could not be loaded.",
            comment: "Message shown when an inline Git diff fails to load"
        )
    }

    /// A Git submodule pointer (mode 160000) has no text content to load,
    /// so it is projected from an empty snapshot exactly like a binary.
    static func isGitlink(_ diff: GitFileDiff) -> Bool {
        diff.change.oldMode == "160000" || diff.change.newMode == "160000"
    }

    /// Whether a selection made in the Source Control sidebar still
    /// describes a real change after a status refresh.
    static func selection(
        _ target: GitDiffTarget,
        stillAppliesTo entry: GitStatusEntry
    ) -> Bool {
        switch target {
        case .indexVsHead:
            return entry.isStaged
        case .workingTreeVsIndex:
            return entry.isUnstaged || entry.isUntracked || entry.isConflicted
        case .workingTreeVsHead:
            return entry.isStaged || entry.isUnstaged || entry.isUntracked || entry.isConflicted
        }
    }
}

/// Owns every Quick Diff request the workspace makes: the tab opened from
/// a Source Control sidebar selection and the gutter decorations for the
/// visible editors. Both go through one request/projection/error policy
/// and one per-channel generation guard, so a refresh of one consumer
/// cancels only itself.
@MainActor
final class GitQuickDiffCoordinator {
    typealias Channel = GitQuickDiffRequestRegistry.Channel

    struct Dependencies {
        var workspaceRoot: URL
        var diagnosticsLog: BoundedEventLog
        var gitContext: () -> GitContext?
        var latestStatus: () -> GitStatusSnapshot?
        /// Loads a workspace-relative path into a version-bumped snapshot.
        var loadSnapshot: @MainActor (String) async throws -> SourceSnapshot
        /// The next snapshot version, for the empty snapshots that back an
        /// unavailable-diff tab.
        var nextSnapshotVersion: () -> Int
        var groupController: (EditorGroupID) -> EditorGroupViewController?
        var allGroupControllers: () -> [EditorGroupViewController]
    }

    private struct SelectionState {
        let selection: SourceControlSidebarViewController.FileSelection
        let groupID: EditorGroupID
    }

    private enum VisibleResult {
        case sources([GitQuickDiffSource])
        case unavailable(message: String, diff: GitFileDiff?)
    }

    private struct VisibleDocument {
        let groupController: EditorGroupViewController
        let documentController: CodeDocumentViewController
        let relativePath: String
        let snapshotVersion: Int
    }

    private let dependencies: Dependencies
    private var registry = GitQuickDiffRequestRegistry()
    private var tasks: [Channel: Task<Void, Never>] = [:]
    private var selectionState: SelectionState?
    private var visibleControllers: [ObjectIdentifier: GitQuickDiffController] = [:]

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    // MARK: - Request channels

    private func beginRequest(on channel: Channel) -> Int {
        tasks.removeValue(forKey: channel)?.cancel()
        return registry.begin(channel)
    }

    private func invalidate(_ channel: Channel) {
        tasks.removeValue(forKey: channel)?.cancel()
        registry.invalidate(channel)
    }

    private func isCurrent(_ generation: Int, in channel: Channel) -> Bool {
        registry.isCurrent(generation, in: channel)
    }

    // MARK: - Visible editors

    /// The controller driving the currently visible document's gutter, if
    /// any — used by the next/previous-change commands.
    func visibleController(
        for documentController: CodeDocumentViewController
    ) -> GitQuickDiffController? {
        visibleControllers[ObjectIdentifier(documentController)]
    }

    func refreshTheme() {
        visibleControllers.values.forEach { $0.refreshTheme() }
    }

    func cancelAll() {
        for channel in Channel.allCases {
            invalidate(channel)
        }
        selectionState = nil
    }

    // MARK: - Source Control sidebar selection

    func openSelection(
        _ selection: SourceControlSidebarViewController.FileSelection,
        in groupController: EditorGroupViewController
    ) {
        selectionState = SelectionState(
            selection: selection,
            groupID: groupController.groupID
        )
        loadSelection(selection, in: groupController)
    }

    /// Re-runs the sidebar selection's diff after a status change, or
    /// clears it when the selection no longer describes a real change.
    func refreshSelection(snapshot: GitStatusSnapshot?) {
        guard let state = selectionState,
              let groupController = dependencies.groupController(state.groupID) else {
            return
        }
        guard let entry = snapshot?.entry(forPath: state.selection.path),
              GitQuickDiffPolicy.selection(state.selection.target, stillAppliesTo: entry) else {
            invalidate(.sidebarSelection)
            groupController.currentQuickDiffController?.clear()
            selectionState = nil
            return
        }
        loadSelection(state.selection, in: groupController)
    }

    /// The group showing the sidebar selection changed its tabs: if it no
    /// longer shows that Quick Diff, the selection is no longer live.
    func handleGroupStateChange(
        groupID: EditorGroupID,
        controller: EditorGroupViewController
    ) {
        guard let state = selectionState, state.groupID == groupID else {
            return
        }
        if controller.currentQuickDiffController == nil
            || controller.currentTabRelativePath != state.selection.path {
            invalidate(.sidebarSelection)
            selectionState = nil
        }
    }

    /// A plain document became ready in the group that owned the sidebar
    /// selection's path: the Quick Diff tab was replaced, so drop it.
    func handleDocumentReady(
        groupID: EditorGroupID,
        relativePath: String,
        controller: EditorGroupViewController
    ) {
        guard controller.currentQuickDiffController == nil,
              let state = selectionState,
              state.groupID == groupID,
              state.selection.path == relativePath else {
            return
        }
        invalidate(.sidebarSelection)
        selectionState = nil
    }

    private func loadSelection(
        _ selection: SourceControlSidebarViewController.FileSelection,
        in groupController: EditorGroupViewController
    ) {
        guard let context = dependencies.gitContext() else {
            return
        }
        let generation = beginRequest(on: .sidebarSelection)
        let groupID = groupController.groupID
        tasks[.sidebarSelection] = Task { [weak self, weak groupController] in
            guard let self, let groupController else {
                return
            }
            do {
                if self.dependencies.latestStatus()?
                    .entry(forPath: selection.path)?.isConflicted == true {
                    let snapshot = try await self.dependencies.loadSnapshot(selection.path)
                    try Task.checkCancellation()
                    guard self.isCurrent(generation, in: .sidebarSelection),
                          self.dependencies.groupController(groupID) === groupController else {
                        return
                    }
                    groupController.openQuickDiffTab(
                        relativePath: selection.path,
                        snapshot: snapshot,
                        sources: [],
                        revealFirstHunk: false,
                        unavailableMessage: GitQuickDiffPolicy.conflictedMessage
                    )
                    return
                }
                let diff = try await context.diff(
                    path: selection.path,
                    target: selection.target,
                    isUntracked: selection.isUntracked,
                    knownOldPath: selection.originalPath
                )
                try Task.checkCancellation()
                let snapshot: SourceSnapshot
                if diff.content == .binary || GitQuickDiffPolicy.isGitlink(diff) {
                    snapshot = self.emptySnapshot(relativePath: selection.path)
                } else {
                    snapshot = try await self.selectionSnapshot(
                        for: diff,
                        target: selection.target,
                        relativePath: selection.path,
                        context: context
                    )
                }
                try Task.checkCancellation()
                guard self.isCurrent(generation, in: .sidebarSelection),
                      self.dependencies.groupController(groupID) === groupController else {
                    return
                }

                if case .binary = diff.content {
                    groupController.openQuickDiffTab(
                        relativePath: selection.path,
                        snapshot: snapshot,
                        sources: [],
                        revealFirstHunk: false,
                        unavailableMessage: GitQuickDiffPolicy.binaryMessage,
                        fallbackDiff: diff
                    )
                    return
                }
                if diff.hunks.isEmpty {
                    groupController.openQuickDiffTab(
                        relativePath: selection.path,
                        snapshot: snapshot,
                        sources: [],
                        revealFirstHunk: false,
                        unavailableMessage: GitQuickDiffPolicy.noInlineDifferencesMessage,
                        fallbackDiff: diff
                    )
                    return
                }

                groupController.openQuickDiffTab(
                    relativePath: selection.path,
                    snapshot: snapshot,
                    sources: [
                        GitQuickDiffPolicy.source(
                            diff: diff,
                            role: GitQuickDiffPolicy.role(for: selection.target),
                            layer: .primary
                        )
                    ],
                    revealFirstHunk: true
                )
            } catch is CancellationError {
                return
            } catch {
                guard self.isCurrent(generation, in: .sidebarSelection),
                      self.dependencies.groupController(groupID) === groupController else {
                    return
                }
                groupController.openQuickDiffTab(
                    relativePath: selection.path,
                    snapshot: self.emptySnapshot(relativePath: selection.path),
                    sources: [],
                    revealFirstHunk: false,
                    unavailableMessage: GitQuickDiffPolicy.loadFailureMessage
                )
                await self.dependencies.diagnosticsLog.record(
                    subsystem: .git,
                    level: .warning,
                    message: Localized.string(
                        "Git diff loading failed",
                        comment: "Diagnostics log message recorded when loading a Git diff fails"
                    ),
                    context: [
                        DiagnosticContextField(
                            name: "workspaceRoot",
                            category: .fullPath,
                            value: self.dependencies.workspaceRoot.path
                        ),
                        DiagnosticContextField(
                            name: "path",
                            category: .fullPath,
                            value: self.url(forRelativePath: selection.path).path
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
    }

    private func selectionSnapshot(
        for diff: GitFileDiff,
        target: GitDiffTarget,
        relativePath: String,
        context: GitContext
    ) async throws -> SourceSnapshot {
        let url = self.url(forRelativePath: relativePath)
        let version = dependencies.nextSnapshotVersion()
        if case .binary = diff.content {
            return SourceSnapshot(text: "", url: url, version: version)
        }
        if diff.change.kind == .deleted {
            return SourceSnapshot(text: "", url: url, version: version)
        }

        switch target {
        case .indexVsHead:
            let content = try await context.revisionContent(
                source: .index,
                target: target,
                diff: diff
            )
            guard let bytes = content.bytes else {
                throw GitRevisionContentError.contentUnavailable(source: .index, path: relativePath)
            }
            return try await Task.detached(priority: .userInitiated) {
                try SourceSnapshotLoader(
                    renderingSafetyPolicy: .codeViewportDefault
                ).load(data: bytes, url: url, version: version)
            }.value
        case .workingTreeVsIndex, .workingTreeVsHead:
            return try await Task.detached(priority: .userInitiated) {
                try SourceSnapshotLoader(
                    renderingSafetyPolicy: .codeViewportDefault
                ).load(url: url, version: version)
            }.value
        }
    }

    // MARK: - Visible editor gutters

    func refreshVisibleEditors(snapshot: GitStatusSnapshot?) {
        let generation = beginRequest(on: .visibleEditors)

        let visibleDocuments: [VisibleDocument] = dependencies.allGroupControllers()
            .compactMap { groupController in
                guard let documentController = groupController.currentVisibleDocumentController,
                      let relativePath = groupController.currentTabRelativePath else {
                    return nil
                }
                return VisibleDocument(
                    groupController: groupController,
                    documentController: documentController,
                    relativePath: relativePath,
                    snapshotVersion: documentController.snapshot.version
                )
            }
        let visibleIDs = Set(visibleDocuments.map { ObjectIdentifier($0.documentController) })
        let staleIDs = visibleControllers.keys.filter { !visibleIDs.contains($0) }
        for identifier in staleIDs {
            visibleControllers.removeValue(forKey: identifier)?.clear()
        }

        guard let context = dependencies.gitContext(), let snapshot else {
            for item in visibleDocuments {
                visibleControllers
                    .removeValue(forKey: ObjectIdentifier(item.documentController))?
                    .clear()
            }
            return
        }

        tasks[.visibleEditors] = Task { [weak self] in
            guard let self else {
                return
            }
            for item in visibleDocuments {
                guard !Task.isCancelled,
                      self.isCurrent(generation, in: .visibleEditors) else {
                    return
                }
                let identifier = ObjectIdentifier(item.documentController)
                guard let entry = snapshot.entry(forPath: item.relativePath), !entry.isIgnored else {
                    self.visibleControllers.removeValue(forKey: identifier)?.clear()
                    item.documentController.viewport.clearGutterChanges()
                    continue
                }

                let controller = self.visibleControllers[identifier]
                    ?? GitQuickDiffController(documentController: item.documentController)
                controller.onOpenFullDiff = { [weak groupController = item.groupController] diff in
                    groupController?.openDiffTab(relativePath: item.relativePath, diff: diff)
                }
                self.visibleControllers[identifier] = controller

                do {
                    let result = try await self.visibleResult(
                        entry: entry,
                        relativePath: item.relativePath,
                        context: context
                    )
                    guard !Task.isCancelled,
                          self.isCurrent(generation, in: .visibleEditors),
                          item.groupController.currentVisibleDocumentController === item.documentController,
                          item.groupController.currentTabRelativePath == item.relativePath,
                          item.documentController.snapshot.version == item.snapshotVersion else {
                        return
                    }
                    switch result {
                    case .sources(let sources):
                        controller.update(sources: sources)
                    case .unavailable(let message, let diff):
                        controller.showUnavailable(message: message, diff: diff)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard self.isCurrent(generation, in: .visibleEditors),
                          item.groupController.currentVisibleDocumentController === item.documentController else {
                        return
                    }
                    controller.showUnavailable(
                        message: GitQuickDiffPolicy.loadFailureMessage
                    )
                    await self.dependencies.diagnosticsLog.record(
                        subsystem: .git,
                        level: .warning,
                        message: Localized.string(
                            "Git Quick Diff refresh failed",
                            comment: "Diagnostics log message when editor gutter Git changes fail to refresh"
                        ),
                        context: [
                            DiagnosticContextField(
                                name: "path",
                                category: .fullPath,
                                value: self.url(forRelativePath: item.relativePath).path
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
        }
    }

    private func visibleResult(
        entry: GitStatusEntry,
        relativePath: String,
        context: GitContext
    ) async throws -> VisibleResult {
        if entry.isConflicted {
            return .unavailable(
                message: GitQuickDiffPolicy.conflictedMessage,
                diff: nil
            )
        }

        var primarySource: GitQuickDiffSource?
        if entry.isUnstaged || entry.isUntracked {
            let diff = try await context.diff(
                path: relativePath,
                target: .workingTreeVsIndex,
                isUntracked: entry.isUntracked,
                knownOldPath: entry.originalPath
            )
            if case .binary = diff.content {
                return .unavailable(
                    message: GitQuickDiffPolicy.binaryMessage,
                    diff: diff
                )
            }
            primarySource = GitQuickDiffPolicy.source(
                diff: diff,
                role: .workingTree,
                layer: .primary
            )
        }

        var sources = primarySource.map { [$0] } ?? []
        if entry.isStaged {
            let hasHead = try await context.headExists()
            let diff = try await context.diff(
                path: relativePath,
                target: hasHead ? .workingTreeVsHead : .workingTreeVsIndex,
                isUntracked: !hasHead,
                knownOldPath: entry.originalPath
            )
            if case .binary = diff.content {
                return .unavailable(
                    message: GitQuickDiffPolicy.binaryMessage,
                    diff: diff
                )
            }
            sources.append(
                GitQuickDiffPolicy.source(
                    diff: diff,
                    role: .index,
                    layer: primarySource == nil ? .primary : .secondary,
                    suppressingMarksOverlapping: primarySource
                )
            )
        }
        return .sources(sources)
    }

    // MARK: - Helpers

    private func url(forRelativePath relativePath: String) -> URL {
        dependencies.workspaceRoot.appendingPathComponent(relativePath)
    }

    private func emptySnapshot(relativePath: String) -> SourceSnapshot {
        SourceSnapshot(
            text: "",
            url: url(forRelativePath: relativePath),
            version: dependencies.nextSnapshotVersion()
        )
    }
}
