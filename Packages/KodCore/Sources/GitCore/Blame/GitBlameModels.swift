import Foundation

/// One commit's identity and metadata as reported by `git blame
/// --porcelain`, shared across every line the commit is responsible for
/// (Git prints the full header once per commit, then only a compact
/// repeat for subsequent lines from the same commit — see
/// `GitBlameParser`).
public struct GitBlameCommit: Equatable, Sendable {
    public let commitID: String
    public let authorName: String
    public let authorEmail: String
    public let authorTime: Date
    public let authorTimeZone: String
    public let committerName: String
    public let committerEmail: String
    public let committerTime: Date
    public let committerTimeZone: String
    public let summary: String
    /// `true` for a boundary commit — typically the repository's root
    /// commit, or the far end of a bounded/shallow blame — beyond which
    /// Git does not attribute further history.
    public let isBoundary: Bool
    /// `true` for the synthetic all-zero commit id Git uses to represent
    /// working-tree content that has not been committed.
    public let isUncommitted: Bool

    public init(
        commitID: String,
        authorName: String,
        authorEmail: String,
        authorTime: Date,
        authorTimeZone: String,
        committerName: String,
        committerEmail: String,
        committerTime: Date,
        committerTimeZone: String,
        summary: String,
        isBoundary: Bool,
        isUncommitted: Bool
    ) {
        self.commitID = commitID
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authorTime = authorTime
        self.authorTimeZone = authorTimeZone
        self.committerName = committerName
        self.committerEmail = committerEmail
        self.committerTime = committerTime
        self.committerTimeZone = committerTimeZone
        self.summary = summary
        self.isBoundary = isBoundary
        self.isUncommitted = isUncommitted
    }
}

/// One blamed line: which commit is responsible, its original line
/// number (in the commit that introduced it) and final line number (in
/// the file as blamed), and the line's text.
public struct GitBlameLine: Equatable, Sendable {
    public let commit: GitBlameCommit
    public let originalLineNumber: Int
    public let finalLineNumber: Int
    public let filename: String
    public let text: String
    /// The immediately preceding commit/path this line's content came
    /// from, when Git reports one (absent for a line's first
    /// appearance/boundary commit).
    public let previousCommitID: String?
    public let previousFilename: String?

    public init(
        commit: GitBlameCommit,
        originalLineNumber: Int,
        finalLineNumber: Int,
        filename: String,
        text: String,
        previousCommitID: String?,
        previousFilename: String?
    ) {
        self.commit = commit
        self.originalLineNumber = originalLineNumber
        self.finalLineNumber = finalLineNumber
        self.filename = filename
        self.text = text
        self.previousCommitID = previousCommitID
        self.previousFilename = previousFilename
    }
}

/// A complete, parsed `git blame` result for one file.
public struct GitBlameResult: Equatable, Sendable {
    public let lines: [GitBlameLine]

    public init(lines: [GitBlameLine]) {
        self.lines = lines
    }

    public func line(atFinalLineNumber finalLineNumber: Int) -> GitBlameLine? {
        lines.first { $0.finalLineNumber == finalLineNumber }
    }

    /// Every distinct commit referenced, in first-appearance order — the
    /// data a commit popover needs without duplicating full metadata per
    /// line.
    public var commits: [GitBlameCommit] {
        var seen = Set<String>()
        var result: [GitBlameCommit] = []
        for line in lines where !seen.contains(line.commit.commitID) {
            seen.insert(line.commit.commitID)
            result.append(line.commit)
        }
        return result
    }
}
