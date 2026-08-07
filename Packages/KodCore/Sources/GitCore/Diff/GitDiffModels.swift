import Foundation

/// One file's Git diff target: which two trees/states are being compared.
/// SPEC 9.1: "File diff against HEAD, index, or working tree as
/// applicable."
public enum GitDiffTarget: Equatable, Sendable {
    /// Unstaged changes: working tree vs the index (`git diff`).
    case workingTreeVsIndex
    /// Staged changes: index vs `HEAD` (`git diff --cached`).
    case indexVsHead
    /// All local changes, staged and unstaged combined: working tree vs
    /// `HEAD` (`git diff HEAD`).
    case workingTreeVsHead
}

/// The kind of change one diff line represents within a hunk.
public enum GitDiffLineKind: Equatable, Sendable {
    case context
    case added
    case removed
    /// Emitted for the literal `\ No newline at end of file` marker Git
    /// appends after a line lacking a trailing newline, so callers can
    /// render it distinctly rather than as a fourth kind of code line.
    case noNewlineAtEndOfFile
}

/// One rendered line within a hunk, carrying both old- and new-side line
/// numbers where applicable (one side is `nil` for pure adds/removes).
public struct GitDiffLine: Equatable, Sendable {
    public let kind: GitDiffLineKind
    public let oldLineNumber: Int?
    public let newLineNumber: Int?
    public let text: String

    public init(kind: GitDiffLineKind, oldLineNumber: Int?, newLineNumber: Int?, text: String) {
        self.kind = kind
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.text = text
    }
}

/// One `@@ -oldStart,oldCount +newStart,newCount @@` hunk and its lines.
public struct GitDiffHunk: Equatable, Sendable {
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    /// Optional trailing function/section context Git appends after the
    /// second `@@` (e.g. `@@ ... @@ func foo() {`).
    public let sectionHeading: String?
    public let lines: [GitDiffLine]

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, sectionHeading: String?, lines: [GitDiffLine]) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.sectionHeading = sectionHeading
        self.lines = lines
    }

    /// Every added line's new-side line number, for gutter/overview
    /// decoration and the "added" line-range summary.
    public var addedLineNumbers: [Int] {
        lines.compactMap { $0.kind == .added ? $0.newLineNumber : nil }
    }

    /// Every removed line's old-side line number.
    public var removedLineNumbers: [Int] {
        lines.compactMap { $0.kind == .removed ? $0.oldLineNumber : nil }
    }
}

/// Whether a file's diff content is renderable text or a binary blob Git
/// cannot usefully line-diff.
public enum GitDiffContent: Equatable, Sendable {
    case text(hunks: [GitDiffHunk])
    case binary
}

/// File-level metadata about a diffed file: whether it was added,
/// deleted, modified in place, or renamed/copied from another path, plus
/// any executable-bit change.
public struct GitDiffFileChange: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case added
        case deleted
        case modified
        case renamed
        case copied
    }

    public let kind: Kind
    public let oldPath: String?
    public let newPath: String
    public let similarityPercentage: Int?
    public let oldMode: String?
    public let newMode: String?

    public init(
        kind: Kind,
        oldPath: String?,
        newPath: String,
        similarityPercentage: Int? = nil,
        oldMode: String? = nil,
        newMode: String? = nil
    ) {
        self.kind = kind
        self.oldPath = oldPath
        self.newPath = newPath
        self.similarityPercentage = similarityPercentage
        self.oldMode = oldMode
        self.newMode = newMode
    }
}

/// A complete, parsed file diff: what changed at the file level plus
/// either its hunks or a binary marker.
public struct GitFileDiff: Equatable, Sendable {
    public let change: GitDiffFileChange
    public let content: GitDiffContent

    public init(change: GitDiffFileChange, content: GitDiffContent) {
        self.change = change
        self.content = content
    }

    public var hunks: [GitDiffHunk] {
        if case .text(let hunks) = content {
            return hunks
        }
        return []
    }
}

// MARK: - Side-by-side projection

/// One row in a side-by-side diff view. Either, both, or neither side may
/// be populated depending on whether the row is a pure add, pure remove,
/// a paired change, or unpaired context/filler.
public struct GitSideBySideRow: Equatable, Sendable {
    public let left: GitDiffLine?
    public let right: GitDiffLine?

    public init(left: GitDiffLine?, right: GitDiffLine?) {
        self.left = left
        self.right = right
    }
}

public enum GitSideBySideProjection {
    /// Projects a hunk's linear (unified) line list into side-by-side
    /// rows by pairing up each maximal run of consecutive `removed` lines
    /// with the maximal run of consecutive `added` lines that immediately
    /// follows it, row for row, padding the shorter run with blank filler
    /// rows on the other side. `context` lines become paired rows with
    /// identical content on both sides. This is a fast, allocation-light
    /// alignment appropriate for rendering; it does not attempt a minimal
    /// intra-line diff.
    public static func rows(for hunk: GitDiffHunk) -> [GitSideBySideRow] {
        var rows: [GitSideBySideRow] = []
        var index = 0
        let lines = hunk.lines

        while index < lines.count {
            let line = lines[index]
            switch line.kind {
            case .context, .noNewlineAtEndOfFile:
                rows.append(GitSideBySideRow(left: line, right: line))
                index += 1

            case .removed:
                var removedRun: [GitDiffLine] = []
                while index < lines.count, lines[index].kind == .removed {
                    removedRun.append(lines[index])
                    index += 1
                }
                var addedRun: [GitDiffLine] = []
                while index < lines.count, lines[index].kind == .added {
                    addedRun.append(lines[index])
                    index += 1
                }
                let pairCount = max(removedRun.count, addedRun.count)
                for pairIndex in 0..<pairCount {
                    rows.append(
                        GitSideBySideRow(
                            left: pairIndex < removedRun.count ? removedRun[pairIndex] : nil,
                            right: pairIndex < addedRun.count ? addedRun[pairIndex] : nil
                        )
                    )
                }

            case .added:
                var addedRun: [GitDiffLine] = []
                while index < lines.count, lines[index].kind == .added {
                    addedRun.append(lines[index])
                    index += 1
                }
                for addedLine in addedRun {
                    rows.append(GitSideBySideRow(left: nil, right: addedLine))
                }
            }
        }

        return rows
    }
}
