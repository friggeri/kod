import Foundation

/// Identifies a Quick Diff provider and the immutable source it supplies as
/// the baseline. `id` permits clients to distinguish multiple providers with
/// the same source kind.
public struct GitQuickDiffProvider: Hashable, Sendable {
    public let id: String
    public let source: GitRevisionSource

    public init(id: String, source: GitRevisionSource) {
        self.id = id
        self.source = source
    }

    /// Unstaged changes, projected from the index onto the working tree.
    public static let workingTree = Self(id: "working-tree", source: .index)
    /// Staged changes, projected from `HEAD` onto the index.
    public static let staged = Self(id: "staged", source: .head)
}

/// A stable identifier for one hunk in one provider projection. The index is
/// the parsed-diff order, not a line number, so it remains usable for hunk
/// navigation and gutter ownership.
public struct GitQuickDiffHunkID: Hashable, Sendable, Comparable {
    public let provider: GitQuickDiffProvider
    public let index: Int

    public init(provider: GitQuickDiffProvider, index: Int) {
        self.provider = provider
        self.index = index
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.provider.id != rhs.provider.id {
            return lhs.provider.id < rhs.provider.id
        }
        if lhs.provider.source != rhs.provider.source {
            return lhs.provider.source.rawValue < rhs.provider.source.rawValue
        }
        return lhs.index < rhs.index
    }
}

public enum GitQuickDiffMarkKind: Equatable, Sendable {
    case added
    case modified
}

/// A contiguous, one-based current-side range. Every rendered gutter mark
/// carries its hunk owner, even when a hunk contains multiple changed runs.
public struct GitQuickDiffMark: Equatable, Sendable {
    public let hunkID: GitQuickDiffHunkID
    public let kind: GitQuickDiffMarkKind
    public let currentLineRange: Range<Int>

    public init(
        hunkID: GitQuickDiffHunkID,
        kind: GitQuickDiffMarkKind,
        currentLineRange: Range<Int>
    ) {
        self.hunkID = hunkID
        self.kind = kind
        self.currentLineRange = currentLineRange
    }
}

/// An owner-aware pure-deletion gutter marker. An anchor of zero means before
/// the first current-side line.
public struct GitQuickDiffDeletionAnchor: Equatable, Sendable {
    public let hunkID: GitQuickDiffHunkID
    public let afterCurrentLineNumber: Int

    public init(hunkID: GitQuickDiffHunkID, afterCurrentLineNumber: Int) {
        self.hunkID = hunkID
        self.afterCurrentLineNumber = afterCurrentLineNumber
    }
}

public struct GitQuickDiffHunk: Equatable, Sendable {
    public let id: GitQuickDiffHunkID
    public let diffHunk: GitDiffHunk
    public let marks: [GitQuickDiffMark]
    public let deletionAnchors: [GitQuickDiffDeletionAnchor]

    public init(
        id: GitQuickDiffHunkID,
        diffHunk: GitDiffHunk,
        marks: [GitQuickDiffMark],
        deletionAnchors: [GitQuickDiffDeletionAnchor]
    ) {
        self.id = id
        self.diffHunk = diffHunk
        self.marks = marks
        self.deletionAnchors = deletionAnchors
    }
}

/// Pure Quick Diff data suitable for any editor surface. It deliberately has
/// no viewport, theme, or source-model dependency.
public struct GitQuickDiffProjection: Equatable, Sendable {
    public let provider: GitQuickDiffProvider
    public let hunks: [GitQuickDiffHunk]
    public let navigationHunkIDs: [GitQuickDiffHunkID]

    public var marks: [GitQuickDiffMark] {
        hunks.flatMap(\.marks)
    }

    public var deletionAnchors: [GitQuickDiffDeletionAnchor] {
        hunks.flatMap(\.deletionAnchors)
    }

    public init(
        provider: GitQuickDiffProvider,
        hunks: [GitQuickDiffHunk],
        navigationHunkIDs: [GitQuickDiffHunkID]? = nil
    ) {
        self.provider = provider
        self.hunks = hunks
        self.navigationHunkIDs = navigationHunkIDs ?? hunks.map(\.id)
    }

    /// Projects the parsed diff's current side. Consecutive removals followed
    /// by additions are modifications; unpaired additions are additions; an
    /// unpaired removal becomes a deletion anchor.
    public static func project(
        _ diff: GitFileDiff,
        provider: GitQuickDiffProvider
    ) -> GitQuickDiffProjection {
        project(hunks: diff.hunks, provider: provider)
    }

    public static func project(
        hunks: [GitDiffHunk],
        provider: GitQuickDiffProvider
    ) -> GitQuickDiffProjection {
        let projected = hunks.enumerated().map { index, hunk in
            project(hunk: hunk, id: GitQuickDiffHunkID(provider: provider, index: index))
        }
        return GitQuickDiffProjection(provider: provider, hunks: projected)
    }

    /// Removes only secondary current-side marks that intersect primary
    /// marks. Hunk IDs and deletion anchors are retained, preserving stable
    /// navigation and ownership while avoiding duplicate gutter tinting.
    public func suppressingMarks(overlapping primary: GitQuickDiffProjection) -> GitQuickDiffProjection {
        let primaryRanges = primary.marks.map(\.currentLineRange)
        let filteredHunks = hunks.map { hunk in
            GitQuickDiffHunk(
                id: hunk.id,
                diffHunk: hunk.diffHunk,
                marks: hunk.marks.filter { mark in
                    !primaryRanges.contains { $0.overlaps(mark.currentLineRange) }
                },
                deletionAnchors: hunk.deletionAnchors
            )
        }
        return GitQuickDiffProjection(
            provider: provider,
            hunks: filteredHunks,
            navigationHunkIDs: navigationHunkIDs
        )
    }

    /// Applies VS Code-style primary precedence to a staged (secondary)
    /// projection. The primary is returned unchanged.
    public static func withPrimaryPrecedence(
        primary: GitQuickDiffProjection,
        secondary: GitQuickDiffProjection
    ) -> (primary: GitQuickDiffProjection, secondary: GitQuickDiffProjection) {
        (primary, secondary.suppressingMarks(overlapping: primary))
    }

    private static func project(hunk: GitDiffHunk, id: GitQuickDiffHunkID) -> GitQuickDiffHunk {
        var marks: [GitQuickDiffMark] = []
        var deletions: [GitQuickDiffDeletionAnchor] = []
        var lineIndex = 0
        var lastCurrentLine = max(0, hunk.newStart - 1)

        func appendMark(kind: GitQuickDiffMarkKind, lines: [GitDiffLine]) {
            let numbers = lines.compactMap(\.newLineNumber)
            guard let first = numbers.first else { return }
            var rangeStart = first
            var previous = first
            for number in numbers.dropFirst() {
                if number != previous + 1 {
                    marks.append(GitQuickDiffMark(
                        hunkID: id,
                        kind: kind,
                        currentLineRange: rangeStart..<(previous + 1)
                    ))
                    rangeStart = number
                }
                previous = number
            }
            marks.append(GitQuickDiffMark(
                hunkID: id,
                kind: kind,
                currentLineRange: rangeStart..<(previous + 1)
            ))
            lastCurrentLine = previous
        }

        while lineIndex < hunk.lines.count {
            switch hunk.lines[lineIndex].kind {
            case .context:
                if let line = hunk.lines[lineIndex].newLineNumber {
                    lastCurrentLine = line
                }
                lineIndex += 1
            case .noNewlineAtEndOfFile:
                lineIndex += 1
            case .removed:
                var removed: [GitDiffLine] = []
                while lineIndex < hunk.lines.count, hunk.lines[lineIndex].kind == .removed {
                    removed.append(hunk.lines[lineIndex])
                    lineIndex += 1
                }
                var added: [GitDiffLine] = []
                while lineIndex < hunk.lines.count, hunk.lines[lineIndex].kind == .added {
                    added.append(hunk.lines[lineIndex])
                    lineIndex += 1
                }
                if added.isEmpty {
                    deletions.append(GitQuickDiffDeletionAnchor(
                        hunkID: id,
                        afterCurrentLineNumber: lastCurrentLine
                    ))
                } else {
                    appendMark(kind: .modified, lines: added)
                }
            case .added:
                var added: [GitDiffLine] = []
                while lineIndex < hunk.lines.count, hunk.lines[lineIndex].kind == .added {
                    added.append(hunk.lines[lineIndex])
                    lineIndex += 1
                }
                appendMark(kind: .added, lines: added)
            }
        }

        return GitQuickDiffHunk(
            id: id,
            diffHunk: hunk,
            marks: marks,
            deletionAnchors: deletions
        )
    }
}
