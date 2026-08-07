import Foundation

/// One changed new-side line, classified for a gutter/inline background
/// tint. `added` lines exist only in the new content; `modified` lines
/// replace old content at roughly the same position (a removed run
/// immediately followed by an added run within the same hunk).
public struct GitLineDecoration: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case added
        case modified
    }

    public let newLineNumber: Int
    public let kind: Kind

    public init(newLineNumber: Int, kind: Kind) {
        self.newLineNumber = newLineNumber
        self.kind = kind
    }
}

/// A pure-deletion marker: content was removed with no corresponding
/// added line at the same position, so there is no new-side line to tint
/// — instead this records the gutter boundary (immediately after
/// `afterNewLineNumber`, where `0` means "before the first line") a
/// deleted-lines indicator renders at, per SPEC 9.1's "inline ...
/// deleted gutter markers".
public struct GitDeletionMarker: Equatable, Sendable {
    public let afterNewLineNumber: Int

    public init(afterNewLineNumber: Int) {
        self.afterNewLineNumber = afterNewLineNumber
    }
}

/// Classifies a parsed diff's hunks into per-line added/modified tints
/// and deletion-boundary markers — the same distinction most code
/// editors draw in the gutter (green for pure adds, blue/orange for
/// in-place changes, a red marker where lines vanished with nothing
/// replacing them at that position). Pure model, no AppKit/SourceModel
/// dependency, so it is fully unit-testable headlessly.
public enum GitLineDecorationBuilder {
    public static func lineDecorations(
        for hunks: [GitDiffHunk]
    ) -> (changes: [GitLineDecoration], deletions: [GitDeletionMarker]) {
        var changes: [GitLineDecoration] = []
        var deletions: [GitDeletionMarker] = []

        for hunk in hunks {
            let lines = hunk.lines
            var index = 0
            var lastNewLineNumberSeen = hunk.newStart - 1

            while index < lines.count {
                let line = lines[index]
                switch line.kind {
                case .context:
                    if let newLineNumber = line.newLineNumber {
                        lastNewLineNumberSeen = newLineNumber
                    }
                    index += 1

                case .noNewlineAtEndOfFile:
                    index += 1

                case .removed:
                    var removedRun = 0
                    while index < lines.count, lines[index].kind == .removed {
                        removedRun += 1
                        index += 1
                    }
                    _ = removedRun
                    var addedRun: [GitDiffLine] = []
                    while index < lines.count, lines[index].kind == .added {
                        addedRun.append(lines[index])
                        index += 1
                    }
                    if addedRun.isEmpty {
                        deletions.append(GitDeletionMarker(afterNewLineNumber: lastNewLineNumberSeen))
                    } else {
                        for addedLine in addedRun {
                            guard let newLineNumber = addedLine.newLineNumber else {
                                continue
                            }
                            changes.append(GitLineDecoration(newLineNumber: newLineNumber, kind: .modified))
                            lastNewLineNumberSeen = newLineNumber
                        }
                    }

                case .added:
                    var addedRun: [GitDiffLine] = []
                    while index < lines.count, lines[index].kind == .added {
                        addedRun.append(lines[index])
                        index += 1
                    }
                    for addedLine in addedRun {
                        guard let newLineNumber = addedLine.newLineNumber else {
                            continue
                        }
                        changes.append(GitLineDecoration(newLineNumber: newLineNumber, kind: .added))
                        lastNewLineNumberSeen = newLineNumber
                    }
                }
            }
        }

        return (changes, deletions)
    }
}
