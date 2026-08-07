import Foundation

public enum GitDiffParserError: Error, Equatable, Sendable {
    case malformedRawRecord(String)
    case malformedHunkHeader(String)
}

/// Parses Git's raw (`--raw -z`) and unified-patch (`-p`) diff formats.
/// The two are used together by `GitDiffService`: the raw, NUL-separated
/// format gives unambiguous, byte-exact file identity (status, old/new
/// path, old/new mode) with no path-quoting ambiguity, while the patch
/// format is only ever requested already restricted to the specific
/// path(s) that identity step resolved — so this parser never needs to
/// decode a possibly-quoted `diff --git a/X b/Y` header path itself.
public enum GitDiffParser {
    // MARK: Raw identity (`git diff --raw -z`)

    /// Parses zero or more raw diff records from `-z`-separated output.
    /// Each record's fields (mode/sha/status) are ASCII; only the
    /// trailing path component(s) may contain arbitrary bytes, which are
    /// preserved byte-for-byte.
    public static func parseRawIdentity(_ data: Data) throws -> [GitDiffFileChange] {
        var changes: [GitDiffFileChange] = []
        let tokens = data.split(separator: 0x00, omittingEmptySubsequences: true)
        var index = 0

        while index < tokens.count {
            let header = String(decoding: tokens[index], as: UTF8.self)
            guard header.hasPrefix(":") else {
                throw GitDiffParserError.malformedRawRecord(header)
            }
            let fields = header.dropFirst().split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 5 else {
                throw GitDiffParserError.malformedRawRecord(header)
            }
            let oldMode = String(fields[0])
            let newMode = String(fields[1])
            let statusField = String(fields[4])
            guard let statusLetter = statusField.first else {
                throw GitDiffParserError.malformedRawRecord(header)
            }
            let similarity = Int(statusField.dropFirst())

            index += 1
            guard index < tokens.count else {
                throw GitDiffParserError.malformedRawRecord(header)
            }
            let firstPath = String(decoding: tokens[index], as: UTF8.self)
            index += 1

            let change: GitDiffFileChange
            switch statusLetter {
            case "A":
                change = GitDiffFileChange(kind: .added, oldPath: nil, newPath: firstPath, oldMode: oldMode, newMode: newMode)
            case "D":
                change = GitDiffFileChange(kind: .deleted, oldPath: nil, newPath: firstPath, oldMode: oldMode, newMode: newMode)
            case "R", "C":
                guard index < tokens.count else {
                    throw GitDiffParserError.malformedRawRecord(header)
                }
                let secondPath = String(decoding: tokens[index], as: UTF8.self)
                index += 1
                change = GitDiffFileChange(
                    kind: statusLetter == "R" ? .renamed : .copied,
                    oldPath: firstPath,
                    newPath: secondPath,
                    similarityPercentage: similarity,
                    oldMode: oldMode,
                    newMode: newMode
                )
            default:
                // M (modified), T (type change), U (unmerged), X
                // (unknown) — all treated as an in-place modification at
                // one path, which is what every one of these statuses
                // means for a two-tree comparison's single-path record.
                change = GitDiffFileChange(kind: .modified, oldPath: nil, newPath: firstPath, oldMode: oldMode, newMode: newMode)
            }
            changes.append(change)
        }

        return changes
    }

    // MARK: Patch content (`git diff -p`, restricted to one file's path(s))

    /// Parses one file's unified-diff body (already isolated to a single
    /// file, per `GitDiffService`) into hunks, or detects a binary marker.
    public static func parseContent(_ text: String) throws -> GitDiffContent {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        if lines.contains(where: { $0.hasPrefix("Binary files ") || $0.hasPrefix("GIT binary patch") }) {
            return .binary
        }

        var hunks: [GitDiffHunk] = []
        var index = 0
        while index < lines.count {
            guard lines[index].hasPrefix("@@ ") || lines[index] == "@@" else {
                index += 1
                continue
            }
            let (hunk, nextIndex) = try parseHunk(lines: lines, startIndex: index)
            hunks.append(hunk)
            index = nextIndex
        }
        return .text(hunks: hunks)
    }

    private static func parseHunk(lines: [String], startIndex: Int) throws -> (GitDiffHunk, Int) {
        let header = lines[startIndex]
        guard let parsed = parseHunkHeader(header) else {
            throw GitDiffParserError.malformedHunkHeader(header)
        }

        var oldLine = parsed.oldStart
        var newLine = parsed.newStart
        var diffLines: [GitDiffLine] = []
        var index = startIndex + 1

        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("@@ ") || line == "@@" || line.hasPrefix("diff --git ") {
                break
            }
            if line.isEmpty, index == lines.count - 1 {
                // Trailing empty element from the final split (the text
                // ending in "\n"); not a real diff line.
                break
            }

            guard let marker = line.first else {
                index += 1
                continue
            }
            let content = String(line.dropFirst())
            switch marker {
            case " ":
                diffLines.append(GitDiffLine(kind: .context, oldLineNumber: oldLine, newLineNumber: newLine, text: content))
                oldLine += 1
                newLine += 1
            case "-":
                diffLines.append(GitDiffLine(kind: .removed, oldLineNumber: oldLine, newLineNumber: nil, text: content))
                oldLine += 1
            case "+":
                diffLines.append(GitDiffLine(kind: .added, oldLineNumber: nil, newLineNumber: newLine, text: content))
                newLine += 1
            case "\\":
                diffLines.append(GitDiffLine(kind: .noNewlineAtEndOfFile, oldLineNumber: nil, newLineNumber: nil, text: content))
            default:
                break
            }
            index += 1
        }

        let hunk = GitDiffHunk(
            oldStart: parsed.oldStart,
            oldCount: parsed.oldCount,
            newStart: parsed.newStart,
            newCount: parsed.newCount,
            sectionHeading: parsed.sectionHeading,
            lines: diffLines
        )
        return (hunk, index)
    }

    private struct ParsedHunkHeader {
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
        let sectionHeading: String?
    }

    /// Parses `@@ -oldStart[,oldCount] +newStart[,newCount] @@[ heading]`.
    /// A missing count means a count of 1 (Git's own convention).
    private static func parseHunkHeader(_ header: String) -> ParsedHunkHeader? {
        guard header.hasPrefix("@@ -") else {
            return nil
        }
        let afterMarker = header.dropFirst(4)
        guard let secondAtRange = afterMarker.range(of: " @@") else {
            return nil
        }
        let rangesPart = afterMarker[afterMarker.startIndex..<secondAtRange.lowerBound]
        let heading = afterMarker[secondAtRange.upperBound...]
        let sectionHeading = heading.isEmpty ? nil : String(heading)

        let components = rangesPart.components(separatedBy: " +")
        guard components.count == 2 else {
            return nil
        }
        guard let old = parseRange(components[0]), let new = parseRange(components[1]) else {
            return nil
        }
        return ParsedHunkHeader(
            oldStart: old.start,
            oldCount: old.count,
            newStart: new.start,
            newCount: new.count,
            sectionHeading: sectionHeading
        )
    }

    private static func parseRange(_ text: String) -> (start: Int, count: Int)? {
        let parts = text.split(separator: ",", maxSplits: 1)
        guard let start = Int(parts[0]) else {
            return nil
        }
        if parts.count == 2 {
            guard let count = Int(parts[1]) else {
                return nil
            }
            return (start, count)
        }
        return (start, 1)
    }
}
