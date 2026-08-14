import Foundation
import GitCore
import ThemeCore

public enum GitDecorationColorRole: Equatable, Hashable, Sendable {
    case added
    case modified
    case deleted
    case renamed
    case untracked
    case ignored
    case stagedModified
    case stagedDeleted
    case conflict
}

extension GitDecorationColors {
    public func color(for role: GitDecorationColorRole) -> ThemeColor {
        switch role {
        case .added: return added
        case .modified: return modified
        case .deleted: return deleted
        case .renamed: return renamed
        case .untracked: return untracked
        case .ignored: return ignored
        case .stagedModified: return stagedModified
        case .stagedDeleted: return stagedDeleted
        case .conflict: return conflict
        }
    }
}

public enum GitPresentedStatus: Equatable, Hashable, Sendable {
    case modified
    case added
    case deleted
    case renamed
    case copied
    case typeChanged
    case untracked
    case ignored
    case conflicted

    var letter: String? {
        switch self {
        case .modified:
            return gitUIStrings.string("M", comment: "Single-letter Git status badge for a modified file")
        case .added:
            return gitUIStrings.string("A", comment: "Single-letter Git status badge for an added file")
        case .deleted:
            return gitUIStrings.string("D", comment: "Single-letter Git status badge for a deleted file")
        case .renamed:
            return gitUIStrings.string("R", comment: "Single-letter Git status badge for a renamed file")
        case .copied:
            return gitUIStrings.string("C", comment: "Single-letter Git status badge for a copied file")
        case .typeChanged:
            return gitUIStrings.string("T", comment: "Single-letter Git status badge for a type-changed file")
        case .untracked:
            return gitUIStrings.string("U", comment: "Single-letter Git status badge for an untracked file")
        case .conflicted:
            return "!"
        case .ignored:
            return nil
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .modified:
            return gitUIStrings.string("Modified", comment: "Accessibility description for a modified file's Git status")
        case .added:
            return gitUIStrings.string("Added", comment: "Accessibility description for an added file's Git status")
        case .deleted:
            return gitUIStrings.string("Deleted", comment: "Accessibility description for a deleted file's Git status")
        case .renamed:
            return gitUIStrings.string("Renamed", comment: "Accessibility description for a renamed file's Git status")
        case .copied:
            return gitUIStrings.string("Copied", comment: "Accessibility description for a copied file's Git status")
        case .typeChanged:
            return gitUIStrings.string("Type changed", comment: "Accessibility description for a type-changed file's Git status")
        case .untracked:
            return gitUIStrings.string("Untracked", comment: "Accessibility description for an untracked file's Git status")
        case .ignored:
            return gitUIStrings.string("Ignored", comment: "Accessibility description for an ignored file's Git status")
        case .conflicted:
            return gitUIStrings.string("Conflicted", comment: "Accessibility description for a conflicted file's Git status")
        }
    }

    /// VS Code's Git decorations use these priority bands when more than
    /// one status applies to the same resource.
    var priority: Int {
        switch self {
        case .added, .deleted, .renamed, .untracked:
            return 1
        case .modified, .copied, .typeChanged:
            return 2
        case .ignored:
            return 3
        case .conflicted:
            return 4
        }
    }

    fileprivate var folderTieBreakRank: Int {
        switch self {
        case .untracked: return 0
        case .renamed: return 1
        case .deleted: return 2
        case .added: return 3
        case .typeChanged: return 4
        case .copied: return 5
        case .modified: return 6
        case .ignored: return 7
        case .conflicted: return 8
        }
    }
}

public struct GitStatusPresentation: Equatable, Sendable {
    public let status: GitPresentedStatus
    public let colorRole: GitDecorationColorRole

    public init(
        status: GitPresentedStatus,
        colorRole: GitDecorationColorRole
    ) {
        self.status = status
        self.colorRole = colorRole
    }

    var letter: String? {
        status.letter
    }

    public var accessibilityDescription: String {
        status.accessibilityDescription
    }

    var isDeleted: Bool {
        status == .deleted
    }
}

public struct GitExplorerDecoration: Equatable, Sendable {
    public enum Indicator: Equatable, Sendable {
        case statusLetter
        case descendant
    }

    public let presentation: GitStatusPresentation
    public let indicator: Indicator?

    public init(
        presentation: GitStatusPresentation,
        indicator: Indicator?
    ) {
        self.presentation = presentation
        self.indicator = indicator
    }

    public var badgeText: String? {
        switch indicator {
        case .statusLetter:
            return presentation.letter
        case .descendant:
            return "\u{2022}"
        case nil:
            return nil
        }
    }

    public var accessibilityDescription: String {
        switch indicator {
        case .descendant:
            return gitUIStrings.string(
                "Folder contains Git changes: \(presentation.accessibilityDescription)",
                comment: "Accessibility description for a folder whose descendants have Git changes, followed by the full-word status"
            )
        case .statusLetter, nil:
            return presentation.accessibilityDescription
        }
    }

    public static let ignored = GitExplorerDecoration(
        presentation: GitStatusPresentation(status: .ignored, colorRole: .ignored),
        indicator: nil
    )
}

enum GitSourceControlGroup: CaseIterable, Equatable, Hashable, Sendable {
    case mergeChanges
    case stagedChanges
    case changes

    var diffTarget: GitDiffTarget {
        switch self {
        case .mergeChanges, .changes:
            return .workingTreeVsIndex
        case .stagedChanges:
            return .indexVsHead
        }
    }
}

struct GitSourceControlItem: Equatable, Sendable {
    let entry: GitStatusEntry
    let group: GitSourceControlGroup
    let presentation: GitStatusPresentation
}

/// One immutable, per-status-snapshot presentation index shared by Explorer
/// and Source Control. Visible-row rendering performs only dictionary lookups;
/// it never scans the snapshot's complete change list.
public struct GitStatusPresentationIndex: Equatable, Sendable {
    public static let empty = GitStatusPresentationIndex(snapshot: nil)

    private enum PresentationContext {
        case index
        case worktree
    }

    private let entriesByPath: [String: GitStatusEntry]
    private let filePresentationsByPath: [String: GitStatusPresentation]
    private let folderPresentationsByPath: [String: GitStatusPresentation]
    private let sourceControlItemsByGroup: [GitSourceControlGroup: [GitSourceControlItem]]
    let visibleChangeCount: Int

    public init(snapshot: GitStatusSnapshot?) {
        guard let snapshot else {
            entriesByPath = [:]
            filePresentationsByPath = [:]
            folderPresentationsByPath = [:]
            sourceControlItemsByGroup = [:]
            visibleChangeCount = 0
            return
        }

        var entries: [String: GitStatusEntry] = [:]
        var files: [String: GitStatusPresentation] = [:]
        var folders: [String: GitStatusPresentation] = [:]
        var sourceItems: [GitSourceControlGroup: [GitSourceControlItem]] = [:]

        for entry in snapshot.entries {
            let path = Self.normalizedPath(entry.path)
            entries[path] = entry
            if let originalPath = entry.originalPath {
                let normalizedOriginalPath = Self.normalizedPath(originalPath)
                if entries[normalizedOriginalPath] == nil {
                    entries[normalizedOriginalPath] = entry
                }
            }

            if let presentation = Self.explorerPresentation(for: entry) {
                files[path] = presentation
                if Self.shouldPropagateToParentFolders(entry, presentation: presentation) {
                    for parentPath in Self.parentPaths(of: path) {
                        folders[parentPath] = Self.preferredFolderPresentation(
                            folders[parentPath],
                            presentation
                        )
                    }
                }
            }

            if entry.isConflicted {
                let presentation = GitStatusPresentation(status: .conflicted, colorRole: .conflict)
                sourceItems[.mergeChanges, default: []].append(
                    GitSourceControlItem(entry: entry, group: .mergeChanges, presentation: presentation)
                )
                continue
            }
            if entry.isIgnored {
                continue
            }
            if entry.isUntracked {
                let presentation = GitStatusPresentation(status: .untracked, colorRole: .untracked)
                sourceItems[.changes, default: []].append(
                    GitSourceControlItem(entry: entry, group: .changes, presentation: presentation)
                )
                continue
            }
            if entry.isStaged,
               let presentation = Self.sourceControlPresentation(for: entry, in: .stagedChanges) {
                sourceItems[.stagedChanges, default: []].append(
                    GitSourceControlItem(entry: entry, group: .stagedChanges, presentation: presentation)
                )
            }
            if entry.isUnstaged,
               let presentation = Self.sourceControlPresentation(for: entry, in: .changes) {
                sourceItems[.changes, default: []].append(
                    GitSourceControlItem(entry: entry, group: .changes, presentation: presentation)
                )
            }
        }

        for group in GitSourceControlGroup.allCases {
            sourceItems[group]?.sort { lhs, rhs in
                lhs.entry.path.localizedStandardCompare(rhs.entry.path) == .orderedAscending
            }
        }

        entriesByPath = entries
        filePresentationsByPath = files
        folderPresentationsByPath = folders
        sourceControlItemsByGroup = sourceItems
        visibleChangeCount = snapshot.entries.lazy.filter { !$0.isIgnored }.count
    }

    func entry(forRelativePath relativePath: String) -> GitStatusEntry? {
        entriesByPath[Self.normalizedPath(relativePath)]
    }

    public func explorerDecoration(
        forRelativePath relativePath: String,
        isDirectory: Bool
    ) -> GitExplorerDecoration? {
        let path = Self.normalizedPath(relativePath)
        guard isDirectory else {
            guard let presentation = filePresentationsByPath[path] else {
                return nil
            }
            return GitExplorerDecoration(
                presentation: presentation,
                indicator: presentation.status == .ignored ? nil : .statusLetter
            )
        }

        let exactPresentation = filePresentationsByPath[path].flatMap { presentation in
            presentation.status == .deleted ? nil : presentation
        }
        let descendantPresentation = folderPresentationsByPath[path]
        guard let presentation = Self.preferredFolderPresentation(
            exactPresentation,
            descendantPresentation
        ) else {
            return nil
        }

        let indicator: GitExplorerDecoration.Indicator?
        if presentation.status == .ignored, exactPresentation?.status == .ignored {
            indicator = nil
        } else {
            indicator = .descendant
        }
        return GitExplorerDecoration(presentation: presentation, indicator: indicator)
    }

    func sourceControlItems(in group: GitSourceControlGroup) -> [GitSourceControlItem] {
        sourceControlItemsByGroup[group] ?? []
    }

    static func explorerPresentation(for entry: GitStatusEntry) -> GitStatusPresentation? {
        switch entry.shape {
        case .untracked:
            return GitStatusPresentation(status: .untracked, colorRole: .untracked)
        case .ignored:
            return GitStatusPresentation(status: .ignored, colorRole: .ignored)
        case .unmerged:
            return GitStatusPresentation(status: .conflicted, colorRole: .conflict)
        case .ordinary(let indexStatus, let worktreeStatus),
             .renameOrCopy(let indexStatus, let worktreeStatus, _, _):
            let indexPresentation = presentation(for: indexStatus, context: .index)
            let worktreePresentation = presentation(for: worktreeStatus, context: .worktree)
            return preferredResourcePresentation(indexPresentation, worktreePresentation)
        }
    }

    static func sourceControlPresentation(
        for entry: GitStatusEntry,
        in group: GitSourceControlGroup
    ) -> GitStatusPresentation? {
        switch group {
        case .mergeChanges:
            return entry.isConflicted
                ? GitStatusPresentation(status: .conflicted, colorRole: .conflict)
                : nil
        case .stagedChanges:
            guard let status = statusCode(for: entry, useIndex: true) else {
                return nil
            }
            return presentation(for: status, context: .index)
        case .changes:
            switch entry.shape {
            case .untracked:
                return GitStatusPresentation(status: .untracked, colorRole: .untracked)
            case .unmerged:
                return GitStatusPresentation(status: .conflicted, colorRole: .conflict)
            case .ignored:
                return nil
            case .ordinary, .renameOrCopy:
                guard let status = statusCode(for: entry, useIndex: false) else {
                    return nil
                }
                return presentation(for: status, context: .worktree)
            }
        }
    }

    private static func statusCode(
        for entry: GitStatusEntry,
        useIndex: Bool
    ) -> GitStatusChangeCode? {
        switch entry.shape {
        case .ordinary(let indexStatus, let worktreeStatus),
             .renameOrCopy(let indexStatus, let worktreeStatus, _, _):
            return useIndex ? indexStatus : worktreeStatus
        case .unmerged, .untracked, .ignored:
            return nil
        }
    }

    private static func shouldPropagateToParentFolders(
        _ entry: GitStatusEntry,
        presentation: GitStatusPresentation
    ) -> Bool {
        guard presentation.status != .deleted, presentation.status != .ignored else {
            return false
        }
        switch entry.shape {
        case .ordinary(let indexStatus, let worktreeStatus),
             .renameOrCopy(let indexStatus, let worktreeStatus, _, _):
            return indexStatus != .deleted && worktreeStatus != .deleted
        case .untracked, .unmerged:
            return true
        case .ignored:
            return false
        }
    }

    private static func presentation(
        for code: GitStatusChangeCode,
        context: PresentationContext
    ) -> GitStatusPresentation? {
        let status: GitPresentedStatus
        switch code {
        case .unmodified:
            return nil
        case .modified:
            status = .modified
        case .typeChanged:
            status = .typeChanged
        case .added:
            status = .added
        case .deleted:
            status = .deleted
        case .renamed:
            status = .renamed
        case .copied:
            status = .copied
        case .updatedButUnmerged:
            status = .conflicted
        }

        let colorRole: GitDecorationColorRole
        switch status {
        case .modified, .typeChanged:
            colorRole = context == .index ? .stagedModified : .modified
        case .added:
            colorRole = .added
        case .deleted:
            colorRole = context == .index ? .stagedDeleted : .deleted
        case .renamed, .copied:
            colorRole = .renamed
        case .untracked:
            colorRole = .untracked
        case .ignored:
            colorRole = .ignored
        case .conflicted:
            colorRole = .conflict
        }
        return GitStatusPresentation(status: status, colorRole: colorRole)
    }

    /// Worktree wins ties within a priority band, while a higher VS Code
    /// priority always wins regardless of side. This makes `RM` render as M.
    private static func preferredResourcePresentation(
        _ index: GitStatusPresentation?,
        _ worktree: GitStatusPresentation?
    ) -> GitStatusPresentation? {
        guard let index else {
            return worktree
        }
        guard let worktree else {
            return index
        }
        return worktree.status.priority >= index.status.priority ? worktree : index
    }

    private static func preferredFolderPresentation(
        _ lhs: GitStatusPresentation?,
        _ rhs: GitStatusPresentation?
    ) -> GitStatusPresentation? {
        guard let lhs else {
            return rhs
        }
        guard let rhs else {
            return lhs
        }
        if lhs.status.priority != rhs.status.priority {
            return lhs.status.priority > rhs.status.priority ? lhs : rhs
        }
        return lhs.status.folderTieBreakRank >= rhs.status.folderTieBreakRank ? lhs : rhs
    }

    private static func normalizedPath(_ path: String) -> String {
        var normalized = path
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private static func parentPaths(of path: String) -> [String] {
        var result: [String] = []
        var parent = (path as NSString).deletingLastPathComponent
        while !parent.isEmpty, parent != "." {
            result.append(parent)
            let nextParent = (parent as NSString).deletingLastPathComponent
            guard nextParent != parent else {
                break
            }
            parent = nextParent
        }
        return result
    }
}
