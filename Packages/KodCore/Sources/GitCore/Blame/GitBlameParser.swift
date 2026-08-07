import Foundation

public enum GitBlameParserError: Error, Equatable, Sendable {
    case malformedHeaderLine(String)
    case missingMetadata(commitID: String, field: String)
    case missingContentLine(String)
}

/// Parses `git blame --porcelain` output.
///
/// Porcelain blame prints full per-commit metadata (author/committer/
/// summary/boundary/previous/filename) only the first time a given
/// commit id appears anywhere in the stream; every later line
/// attributed to that same commit — even non-consecutively, interleaved
/// with other commits' lines — repeats only the compact `<sha> <orig>
/// <final>` header and omits every metadata line entirely. This parser
/// therefore caches each commit's full metadata (filename included, since
/// empirically Git treats it as part of that bundle rather than
/// re-evaluating it independently) the first time it is parsed and reuses
/// the cached record for every subsequent occurrence.
public enum GitBlameParser {
    private struct PendingCommit {
        var authorName: String?
        var authorEmail: String?
        var authorTime: Date?
        var authorTimeZone: String?
        var committerName: String?
        var committerEmail: String?
        var committerTime: Date?
        var committerTimeZone: String?
        var summary: String?
        var isBoundary = false
        var previousCommitID: String?
        var previousFilename: String?
        var filename: String?
    }

    public static func parse(_ text: String) throws -> GitBlameResult {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Drop the split artifact from a trailing "\n".
        if lines.last == "" {
            lines.removeLast()
        }

        var commitCache: [String: GitBlameCommit] = [:]
        var pendingByCommit: [String: PendingCommit] = [:]
        var result: [GitBlameLine] = []

        var index = 0
        while index < lines.count {
            let header = lines[index]
            guard let parsedHeader = parseHeaderLine(header) else {
                throw GitBlameParserError.malformedHeaderLine(header)
            }
            index += 1

            var pending = pendingByCommit[parsedHeader.commitID] ?? PendingCommit()
            var mostRecentPreviousCommitID: String?
            var mostRecentPreviousFilename: String?
            var mostRecentFilename: String?

            while index < lines.count, !lines[index].hasPrefix("\t") {
                let metadataLine = lines[index]
                if let value = value(metadataLine, forKey: "author ") {
                    pending.authorName = value
                } else if let value = value(metadataLine, forKey: "author-mail ") {
                    pending.authorEmail = unwrapAngleBrackets(value)
                } else if let value = value(metadataLine, forKey: "author-time ") {
                    pending.authorTime = epochDate(value)
                } else if let value = value(metadataLine, forKey: "author-tz ") {
                    pending.authorTimeZone = value
                } else if let value = value(metadataLine, forKey: "committer ") {
                    pending.committerName = value
                } else if let value = value(metadataLine, forKey: "committer-mail ") {
                    pending.committerEmail = unwrapAngleBrackets(value)
                } else if let value = value(metadataLine, forKey: "committer-time ") {
                    pending.committerTime = epochDate(value)
                } else if let value = value(metadataLine, forKey: "committer-tz ") {
                    pending.committerTimeZone = value
                } else if let value = value(metadataLine, forKey: "summary ") {
                    pending.summary = value
                } else if metadataLine == "boundary" {
                    pending.isBoundary = true
                } else if let value = value(metadataLine, forKey: "previous ") {
                    let parts = value.split(separator: " ", maxSplits: 1)
                    mostRecentPreviousCommitID = String(parts[0])
                    if parts.count == 2 {
                        mostRecentPreviousFilename = String(parts[1])
                    }
                } else if let value = value(metadataLine, forKey: "filename ") {
                    mostRecentFilename = value
                }
                // Any other porcelain metadata key (e.g. a future
                // addition) is intentionally ignored rather than
                // treated as an error, so long as it is not the
                // tab-prefixed content line that ends this record.
                index += 1
            }

            if let mostRecentPreviousCommitID {
                pending.previousCommitID = mostRecentPreviousCommitID
                pending.previousFilename = mostRecentPreviousFilename
            }
            if let mostRecentFilename {
                pending.filename = mostRecentFilename
            }
            pendingByCommit[parsedHeader.commitID] = pending

            guard index < lines.count, lines[index].hasPrefix("\t") else {
                throw GitBlameParserError.missingContentLine(header)
            }
            let contentLine = String(lines[index].dropFirst())
            index += 1

            let commit = try resolveCommit(
                commitID: parsedHeader.commitID,
                pending: pending,
                cache: &commitCache
            )
            guard let filename = pending.filename else {
                throw GitBlameParserError.missingMetadata(commitID: parsedHeader.commitID, field: "filename")
            }

            result.append(
                GitBlameLine(
                    commit: commit,
                    originalLineNumber: parsedHeader.originalLineNumber,
                    finalLineNumber: parsedHeader.finalLineNumber,
                    filename: filename,
                    text: contentLine,
                    previousCommitID: pending.previousCommitID,
                    previousFilename: pending.previousFilename
                )
            )
        }

        return GitBlameResult(lines: result)
    }

    private static func resolveCommit(
        commitID: String,
        pending: PendingCommit,
        cache: inout [String: GitBlameCommit]
    ) throws -> GitBlameCommit {
        if let cached = cache[commitID] {
            return cached
        }

        let isUncommitted = commitID == String(repeating: "0", count: commitID.count)

        func require(_ value: String?, field: String) throws -> String {
            guard let value else {
                throw GitBlameParserError.missingMetadata(commitID: commitID, field: field)
            }
            return value
        }
        func require(_ value: Date?, field: String) throws -> Date {
            guard let value else {
                throw GitBlameParserError.missingMetadata(commitID: commitID, field: field)
            }
            return value
        }

        let commit = GitBlameCommit(
            commitID: commitID,
            authorName: try require(pending.authorName, field: "author"),
            authorEmail: try require(pending.authorEmail, field: "author-mail"),
            authorTime: try require(pending.authorTime, field: "author-time"),
            authorTimeZone: try require(pending.authorTimeZone, field: "author-tz"),
            committerName: try require(pending.committerName, field: "committer"),
            committerEmail: try require(pending.committerEmail, field: "committer-mail"),
            committerTime: try require(pending.committerTime, field: "committer-time"),
            committerTimeZone: try require(pending.committerTimeZone, field: "committer-tz"),
            summary: pending.summary ?? "",
            isBoundary: pending.isBoundary,
            isUncommitted: isUncommitted
        )
        cache[commitID] = commit
        return commit
    }

    private struct ParsedHeader {
        let commitID: String
        let originalLineNumber: Int
        let finalLineNumber: Int
    }

    /// Parses `<sha> <origline> <finalline>[ <numlines>]`. The trailing
    /// line count is only present the first time a commit's hunk group
    /// starts and is not needed here since every line gets its own
    /// header record regardless.
    private static func parseHeaderLine(_ line: String) -> ParsedHeader? {
        let components = line.split(separator: " ")
        guard components.count == 3 || components.count == 4 else {
            return nil
        }
        guard components[0].count == 40, components[0].allSatisfy(\.isHexDigit) else {
            return nil
        }
        guard let originalLineNumber = Int(components[1]), let finalLineNumber = Int(components[2]) else {
            return nil
        }
        return ParsedHeader(commitID: String(components[0]), originalLineNumber: originalLineNumber, finalLineNumber: finalLineNumber)
    }

    private static func value(_ line: String, forKey key: String) -> String? {
        guard line.hasPrefix(key) else {
            return nil
        }
        return String(line.dropFirst(key.count))
    }

    private static func unwrapAngleBrackets(_ value: String) -> String {
        var result = value
        if result.hasPrefix("<") {
            result.removeFirst()
        }
        if result.hasSuffix(">") {
            result.removeLast()
        }
        return result
    }

    private static func epochDate(_ value: String) -> Date? {
        guard let seconds = TimeInterval(value) else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }
}
