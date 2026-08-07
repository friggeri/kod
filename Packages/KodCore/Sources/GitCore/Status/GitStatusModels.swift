import Foundation

/// One side's (index or worktree) single-character status code from
/// porcelain v2's `XY` pair, matching Git's own letters exactly.
public enum GitStatusChangeCode: Character, Sendable {
    case unmodified = "."
    case modified = "M"
    case typeChanged = "T"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    /// Git's `git-status` documentation lists `C` (copied) as a valid
    /// XY code for symmetry with `git diff --raw`, even though a plain
    /// `git status` invocation (which only supports `-M`/`--find-
    /// renames`, never `-C`/`--find-copies`) never actually emits it.
    /// Parsing still recognizes it defensively rather than failing.
    case copied = "C"
    case updatedButUnmerged = "U"
}

/// The three merge stages Git tracks for an unmerged (conflicted) path.
public struct GitUnmergedStage: Equatable, Sendable {
    public let mode: String
    public let objectID: String

    public init(mode: String, objectID: String) {
        self.mode = mode
        self.objectID = objectID
    }
}

/// One parsed entry from `git status --porcelain=v2 -z`. Exactly one of
/// `ordinary`, `renameOrCopy`, `unmerged`, `untracked`, or `ignored`
/// describes the entry's shape; the computed properties below classify
/// it into the groups SPEC 9.1 asks for (staged, unstaged, untracked,
/// conflicted, ignored, renamed).
public struct GitStatusEntry: Equatable, Sendable {
    public enum Shape: Equatable, Sendable {
        /// Format `1`: an ordinary added/modified/deleted/type-changed
        /// path with no rename/copy pairing.
        case ordinary(indexStatus: GitStatusChangeCode, worktreeStatus: GitStatusChangeCode)
        /// Format `2`: a rename or copy, pairing `originalPath` (the old
        /// name) with `path` (the new name).
        case renameOrCopy(indexStatus: GitStatusChangeCode, worktreeStatus: GitStatusChangeCode, similarityPercentage: Int, originalPath: String)
        /// Format `u`: an unmerged (conflicted) path with base/ours/
        /// theirs stages.
        case unmerged(code: String, base: GitUnmergedStage?, ours: GitUnmergedStage, theirs: GitUnmergedStage)
        /// Format `?`: untracked.
        case untracked
        /// Format `!`: ignored.
        case ignored
    }

    public let path: String
    public let shape: Shape
    public let headMode: String?
    public let indexMode: String?
    public let worktreeMode: String?
    public let headObjectID: String?
    public let indexObjectID: String?

    public init(
        path: String,
        shape: Shape,
        headMode: String? = nil,
        indexMode: String? = nil,
        worktreeMode: String? = nil,
        headObjectID: String? = nil,
        indexObjectID: String? = nil
    ) {
        self.path = path
        self.shape = shape
        self.headMode = headMode
        self.indexMode = indexMode
        self.worktreeMode = worktreeMode
        self.headObjectID = headObjectID
        self.indexObjectID = indexObjectID
    }

    public var originalPath: String? {
        if case .renameOrCopy(_, _, _, let originalPath) = shape {
            return originalPath
        }
        return nil
    }

    public var isConflicted: Bool {
        if case .unmerged = shape {
            return true
        }
        return false
    }

    public var isUntracked: Bool {
        shape == .untracked
    }

    public var isIgnored: Bool {
        shape == .ignored
    }

    public var isRenamed: Bool {
        if case .renameOrCopy(_, _, _, _) = shape {
            return true
        }
        return false
    }

    public var isCopied: Bool {
        if case .renameOrCopy(let indexStatus, _, _, _) = shape, indexStatus == .copied {
            return true
        }
        return false
    }

    /// `true` when there is a staged (index vs `HEAD`) change: an
    /// ordinary/rename entry whose index-side status is not
    /// `.unmodified`. Untracked, ignored, and unmerged entries are never
    /// "staged" in this sense.
    public var isStaged: Bool {
        switch shape {
        case .ordinary(let indexStatus, _):
            return indexStatus != .unmodified
        case .renameOrCopy(let indexStatus, _, _, _):
            return indexStatus != .unmodified
        case .unmerged, .untracked, .ignored:
            return false
        }
    }

    /// `true` when there is an unstaged (worktree vs index) change.
    public var isUnstaged: Bool {
        switch shape {
        case .ordinary(_, let worktreeStatus):
            return worktreeStatus != .unmodified
        case .renameOrCopy(_, let worktreeStatus, _, _):
            return worktreeStatus != .unmodified
        case .unmerged, .untracked, .ignored:
            return false
        }
    }

    /// A full-word description of this entry's change kind — "Added",
    /// "Modified", "Deleted", "Renamed", "Copied", "Type changed",
    /// "Conflicted", "Untracked", or "Ignored" — so any UI surfacing Git
    /// status (Source Control sidebar, Explorer badges) can spell it out
    /// as text rather than relying on a single letter or a color alone
    /// (SPEC 14: "No status is communicated by color alone"). Prefers
    /// whichever side (index for staged, worktree otherwise) actually
    /// changed; falls back to "Modified" only for the vanishingly rare
    /// case where an `.ordinary` entry reports both sides unmodified.
    public var changeDescription: String {
        switch shape {
        case .unmerged:
            return "Conflicted"
        case .untracked:
            return "Untracked"
        case .ignored:
            return "Ignored"
        case .renameOrCopy(let indexStatus, let worktreeStatus, _, _):
            if indexStatus == .copied || worktreeStatus == .copied {
                return "Copied"
            }
            return "Renamed"
        case .ordinary(let indexStatus, let worktreeStatus):
            let status = indexStatus != .unmodified ? indexStatus : worktreeStatus
            return Self.description(for: status)
        }
    }

    private static func description(for code: GitStatusChangeCode) -> String {
        switch code {
        case .unmodified: return "Unmodified"
        case .modified: return "Modified"
        case .typeChanged: return "Type changed"
        case .added: return "Added"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .copied: return "Copied"
        case .updatedButUnmerged: return "Conflicted"
        }
    }
}

/// A full, parsed `git status` result: every entry plus a fast lookup by
/// path for the common "does this open file have Git changes?" query.
public struct GitStatusSnapshot: Equatable, Sendable {
    public let entries: [GitStatusEntry]

    public init(entries: [GitStatusEntry]) {
        self.entries = entries
    }

    public var staged: [GitStatusEntry] { entries.filter(\.isStaged) }
    public var unstaged: [GitStatusEntry] { entries.filter { $0.isUnstaged && !$0.isConflicted } }
    public var untracked: [GitStatusEntry] { entries.filter(\.isUntracked) }
    public var ignored: [GitStatusEntry] { entries.filter(\.isIgnored) }
    public var conflicted: [GitStatusEntry] { entries.filter(\.isConflicted) }

    public func entry(forPath path: String) -> GitStatusEntry? {
        entries.first { $0.path == path || $0.originalPath == path }
    }
}
