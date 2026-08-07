import Foundation

public enum GitStatusParserError: Error, Equatable, Sendable {
    case malformedRecord(String)
    case unknownEntryType(String)
}

/// Parses `git status --porcelain=v2 -z` output into `GitStatusEntry`
/// values. Operating on `-z`-separated raw bytes (never the human
/// `--porcelain=v1`/long format) means every path is delivered
/// unescaped and unquoted — including paths containing non-ASCII bytes,
/// tabs, or other characters Git would otherwise C-style-quote — so
/// paths round-trip byte-for-byte through this parser with no lossy
/// escaping step to get wrong.
public enum GitStatusParser {
    public static func parse(_ data: Data) throws -> GitStatusSnapshot {
        var entries: [GitStatusEntry] = []
        let tokens = data.split(separator: 0x00, omittingEmptySubsequences: true)
        var index = 0

        while index < tokens.count {
            let line = String(decoding: tokens[index], as: UTF8.self)
            index += 1
            guard let entryType = line.first else {
                continue
            }

            switch entryType {
            case "1":
                entries.append(try parseOrdinary(line))
            case "2":
                guard index < tokens.count else {
                    throw GitStatusParserError.malformedRecord(line)
                }
                let originalPath = String(decoding: tokens[index], as: UTF8.self)
                index += 1
                entries.append(try parseRenameOrCopy(line, originalPath: originalPath))
            case "u":
                entries.append(try parseUnmerged(line))
            case "?":
                entries.append(try parseUntrackedOrIgnored(line, isIgnored: false))
            case "!":
                entries.append(try parseUntrackedOrIgnored(line, isIgnored: true))
            default:
                throw GitStatusParserError.unknownEntryType(line)
            }
        }

        return GitStatusSnapshot(entries: entries)
    }

    // MARK: Format `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>`

    private static func parseOrdinary(_ line: String) throws -> GitStatusEntry {
        let fields = fieldsAndPath(line, expectedFieldCount: 7)
        guard let fields else {
            throw GitStatusParserError.malformedRecord(line)
        }
        guard let xy = statusCodePair(fields.fields[0]) else {
            throw GitStatusParserError.malformedRecord(line)
        }
        return GitStatusEntry(
            path: fields.path,
            shape: .ordinary(indexStatus: xy.index, worktreeStatus: xy.worktree),
            headMode: fields.fields[2],
            indexMode: fields.fields[3],
            worktreeMode: fields.fields[4],
            headObjectID: fields.fields[5],
            indexObjectID: fields.fields[6]
        )
    }

    // MARK: Format `2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <Xscore> <path>` + `\0<origPath>`

    private static func parseRenameOrCopy(_ line: String, originalPath: String) throws -> GitStatusEntry {
        let fields = fieldsAndPath(line, expectedFieldCount: 8)
        guard let fields else {
            throw GitStatusParserError.malformedRecord(line)
        }
        guard let xy = statusCodePair(fields.fields[0]) else {
            throw GitStatusParserError.malformedRecord(line)
        }
        let scoreField = fields.fields[7]
        guard let similarity = Int(scoreField.dropFirst()) else {
            throw GitStatusParserError.malformedRecord(line)
        }
        return GitStatusEntry(
            path: fields.path,
            shape: .renameOrCopy(
                indexStatus: xy.index,
                worktreeStatus: xy.worktree,
                similarityPercentage: similarity,
                originalPath: originalPath
            ),
            headMode: fields.fields[2],
            indexMode: fields.fields[3],
            worktreeMode: fields.fields[4],
            headObjectID: fields.fields[5],
            indexObjectID: fields.fields[6]
        )
    }

    // MARK: Format `u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>`

    private static func parseUnmerged(_ line: String) throws -> GitStatusEntry {
        let fields = fieldsAndPath(line, expectedFieldCount: 9)
        guard let fields else {
            throw GitStatusParserError.malformedRecord(line)
        }
        let code = fields.fields[0]

        func stage(mode: String, objectID: String) -> GitUnmergedStage? {
            mode == "000000" ? nil : GitUnmergedStage(mode: mode, objectID: objectID)
        }

        let base = stage(mode: fields.fields[2], objectID: fields.fields[6])
        guard let ours = stage(mode: fields.fields[3], objectID: fields.fields[7]) else {
            throw GitStatusParserError.malformedRecord(line)
        }
        guard let theirs = stage(mode: fields.fields[4], objectID: fields.fields[8]) else {
            throw GitStatusParserError.malformedRecord(line)
        }

        return GitStatusEntry(
            path: fields.path,
            shape: .unmerged(code: code, base: base, ours: ours, theirs: theirs),
            worktreeMode: fields.fields[5]
        )
    }

    // MARK: Formats `? <path>` and `! <path>`

    private static func parseUntrackedOrIgnored(_ line: String, isIgnored: Bool) throws -> GitStatusEntry {
        guard line.count >= 2 else {
            throw GitStatusParserError.malformedRecord(line)
        }
        let path = String(line.dropFirst(2))
        return GitStatusEntry(path: path, shape: isIgnored ? .ignored : .untracked)
    }

    // MARK: Shared field splitting

    private struct SplitFields {
        let fields: [String]
        let path: String
    }

    /// Splits a header line of the form `<type> <f1> <f2> ... <fN> <path>`
    /// into exactly `expectedFieldCount` space-delimited fields plus a
    /// trailing path (which may itself legitimately contain spaces, so it
    /// is taken as everything after the Nth field separator rather than
    /// being split further).
    private static func fieldsAndPath(_ line: String, expectedFieldCount: Int) -> SplitFields? {
        var remainder = line[line.index(after: line.startIndex)...]
        guard remainder.first == " " else {
            return nil
        }
        remainder = remainder.dropFirst()

        var fields: [String] = []
        for _ in 0..<expectedFieldCount {
            guard let spaceIndex = remainder.firstIndex(of: " ") else {
                return nil
            }
            fields.append(String(remainder[remainder.startIndex..<spaceIndex]))
            remainder = remainder[remainder.index(after: spaceIndex)...]
        }
        guard !remainder.isEmpty else {
            return nil
        }
        return SplitFields(fields: fields, path: String(remainder))
    }

    private static func statusCodePair(_ xy: String) -> (index: GitStatusChangeCode, worktree: GitStatusChangeCode)? {
        guard xy.count == 2 else {
            return nil
        }
        let characters = Array(xy)
        guard let index = GitStatusChangeCode(rawValue: characters[0]),
              let worktree = GitStatusChangeCode(rawValue: characters[1]) else {
            return nil
        }
        return (index, worktree)
    }
}
