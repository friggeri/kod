import Foundation

/// Changed spans for one rendered line in a Git hunk. Ranges use UTF-16
/// offsets so NSString-based renderers can apply them directly.
public struct GitIntralineHighlight: Equatable, Sendable {
    public let lineIndex: Int
    public let utf16Ranges: [Range<Int>]

    public init(lineIndex: Int, utf16Ranges: [Range<Int>]) {
        self.lineIndex = lineIndex
        self.utf16Ranges = utf16Ranges
    }
}

public enum GitIntralineDiff {
    private static let maximumDetailedCharacterCount = 4_096
    private static let maximumShortMatchLength = 2

    private struct CharacterChange {
        var removed: Range<Int>
        var added: Range<Int>
    }

    private struct BlockLine {
        let hunkLineIndex: Int
        let characters: [Character]
        let start: Int

        var range: Range<Int> {
            start..<(start + characters.count)
        }
    }

    private struct CharacterBlock {
        let characters: [Character]
        let lines: [BlockLine]

        init(_ entries: [(index: Int, line: GitDiffLine)]) {
            var characters: [Character] = []
            var lines: [BlockLine] = []
            for (entryIndex, entry) in entries.enumerated() {
                let lineCharacters = Array(entry.line.text)
                lines.append(
                    BlockLine(
                        hunkLineIndex: entry.index,
                        characters: lineCharacters,
                        start: characters.count
                    )
                )
                characters.append(contentsOf: lineCharacters)
                if entryIndex < entries.count - 1 {
                    characters.append("\n")
                }
            }
            self.characters = characters
            self.lines = lines
        }
    }

    /// Computes intraline spans across each complete removed/added block.
    /// Treating the block as one character sequence matches VS Code's
    /// behavior when edits reflow text across line boundaries.
    public static func highlights(for hunk: GitDiffHunk) -> [GitIntralineHighlight] {
        var result: [GitIntralineHighlight] = []
        var index = 0

        while index < hunk.lines.count {
            guard hunk.lines[index].kind == .removed else {
                index += 1
                continue
            }

            var removed: [(index: Int, line: GitDiffLine)] = []
            while index < hunk.lines.count, hunk.lines[index].kind == .removed {
                removed.append((index, hunk.lines[index]))
                index += 1
            }

            var addedIndex = index
            while addedIndex < hunk.lines.count,
                  hunk.lines[addedIndex].kind == .noNewlineAtEndOfFile {
                addedIndex += 1
            }
            guard addedIndex < hunk.lines.count, hunk.lines[addedIndex].kind == .added else {
                continue
            }

            var added: [(index: Int, line: GitDiffLine)] = []
            while addedIndex < hunk.lines.count, hunk.lines[addedIndex].kind == .added {
                added.append((addedIndex, hunk.lines[addedIndex]))
                addedIndex += 1
            }
            index = addedIndex

            let removedBlock = CharacterBlock(removed)
            let addedBlock = CharacterBlock(added)
            let changes = characterChanges(
                removedCharacters: removedBlock.characters,
                addedCharacters: addedBlock.characters
            )
            result.append(
                contentsOf: lineHighlights(
                    changes: changes.map(\.removed),
                    block: removedBlock
                )
            )
            result.append(
                contentsOf: lineHighlights(
                    changes: changes.map(\.added),
                    block: addedBlock
                )
            )
        }

        return result.sorted { $0.lineIndex < $1.lineIndex }
    }

    private static func characterChanges(
        removedCharacters: [Character],
        addedCharacters: [Character]
    ) -> [CharacterChange] {
        guard removedCharacters != addedCharacters else {
            return []
        }

        guard removedCharacters.count + addedCharacters.count <= maximumDetailedCharacterCount else {
            return [changedMiddleRange(
                removedCharacters: removedCharacters,
                addedCharacters: addedCharacters
            )]
        }

        let difference = addedCharacters.difference(from: removedCharacters)
        var removedOffsets = Set<Int>()
        var addedOffsets = Set<Int>()
        removedOffsets.reserveCapacity(difference.removals.count)
        addedOffsets.reserveCapacity(difference.insertions.count)

        for change in difference {
            switch change {
            case .remove(let offset, _, _):
                removedOffsets.insert(offset)
            case .insert(let offset, _, _):
                addedOffsets.insert(offset)
            }
        }

        var changes: [CharacterChange] = []
        var removedOffset = 0
        var addedOffset = 0

        while removedOffset < removedCharacters.count || addedOffset < addedCharacters.count {
            let removesCharacter = removedOffsets.contains(removedOffset)
            let addsCharacter = addedOffsets.contains(addedOffset)
            if removesCharacter || addsCharacter {
                let removedStart = removedOffset
                let addedStart = addedOffset
                while removedOffsets.contains(removedOffset) || addedOffsets.contains(addedOffset) {
                    if removedOffsets.contains(removedOffset) {
                        removedOffset += 1
                    }
                    if addedOffsets.contains(addedOffset) {
                        addedOffset += 1
                    }
                }
                changes.append(
                    CharacterChange(
                        removed: removedStart..<removedOffset,
                        added: addedStart..<addedOffset
                    )
                )
                continue
            }

            guard removedOffset < removedCharacters.count,
                  addedOffset < addedCharacters.count else {
                changes.append(
                    CharacterChange(
                        removed: removedOffset..<removedCharacters.count,
                        added: addedOffset..<addedCharacters.count
                    )
                )
                break
            }
            removedOffset += 1
            addedOffset += 1
        }

        changes = mergeAcrossShortMatches(changes)
        changes = extendToWordBoundaries(
            changes,
            removedCharacters: removedCharacters,
            addedCharacters: addedCharacters
        )
        return mergeAcrossShortMatches(changes)
    }

    private static func changedMiddleRange(
        removedCharacters: [Character],
        addedCharacters: [Character]
    ) -> CharacterChange {
        let sharedCount = min(removedCharacters.count, addedCharacters.count)
        var prefixCount = 0
        while prefixCount < sharedCount,
              removedCharacters[prefixCount] == addedCharacters[prefixCount] {
            prefixCount += 1
        }

        var suffixCount = 0
        while suffixCount < sharedCount - prefixCount,
              removedCharacters[removedCharacters.count - suffixCount - 1]
                == addedCharacters[addedCharacters.count - suffixCount - 1] {
            suffixCount += 1
        }

        return CharacterChange(
            removed: prefixCount..<(removedCharacters.count - suffixCount),
            added: prefixCount..<(addedCharacters.count - suffixCount)
        )
    }

    /// VS Code folds tiny equal islands back into the surrounding change.
    /// This prevents repeated letters and punctuation from producing a
    /// distracting checkerboard of one-character highlights.
    private static func mergeAcrossShortMatches(
        _ changes: [CharacterChange]
    ) -> [CharacterChange] {
        guard var previous = changes.first else {
            return []
        }

        var result: [CharacterChange] = []
        for current in changes.dropFirst() {
            let removedGap = current.removed.lowerBound - previous.removed.upperBound
            let addedGap = current.added.lowerBound - previous.added.upperBound
            if removedGap <= maximumShortMatchLength || addedGap <= maximumShortMatchLength {
                previous.removed = previous.removed.lowerBound..<current.removed.upperBound
                previous.added = previous.added.lowerBound..<current.added.upperBound
            } else {
                result.append(previous)
                previous = current
            }
        }
        result.append(previous)
        return result
    }

    /// Expands fragmented character changes to their containing words when
    /// less than two thirds of those words remain equal.
    private static func extendToWordBoundaries(
        _ changes: [CharacterChange],
        removedCharacters: [Character],
        addedCharacters: [Character]
    ) -> [CharacterChange] {
        changes.map { change in
            guard let removedWord = wordRange(
                containing: change.removed,
                in: removedCharacters
            ),
            let addedWord = wordRange(
                containing: change.added,
                in: addedCharacters
            ) else {
                return change
            }

            let removedChangedCount = changes.reduce(0) {
                $0 + intersectionLength($1.removed, removedWord)
            }
            let addedChangedCount = changes.reduce(0) {
                $0 + intersectionLength($1.added, addedWord)
            }
            let totalCount = removedWord.count + addedWord.count
            let equalCount = totalCount - removedChangedCount - addedChangedCount
            guard equalCount * 3 < totalCount * 2 else {
                return change
            }

            return CharacterChange(removed: removedWord, added: addedWord)
        }
    }

    private static func wordRange(
        containing range: Range<Int>,
        in characters: [Character]
    ) -> Range<Int>? {
        guard !range.isEmpty,
              range.lowerBound >= 0,
              range.upperBound <= characters.count,
              range.allSatisfy({ isWordCharacter(characters[$0]) }) else {
            return nil
        }

        var lowerBound = range.lowerBound
        while lowerBound > 0, isWordCharacter(characters[lowerBound - 1]) {
            lowerBound -= 1
        }
        var upperBound = range.upperBound
        while upperBound < characters.count, isWordCharacter(characters[upperBound]) {
            upperBound += 1
        }
        return lowerBound..<upperBound
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_"
        }
    }

    private static func intersectionLength(
        _ lhs: Range<Int>,
        _ rhs: Range<Int>
    ) -> Int {
        max(0, min(lhs.upperBound, rhs.upperBound) - max(lhs.lowerBound, rhs.lowerBound))
    }

    private static func lineHighlights(
        changes: [Range<Int>],
        block: CharacterBlock
    ) -> [GitIntralineHighlight] {
        block.lines.compactMap { line in
            let boundaries = utf16Boundaries(for: line.characters)
            let ranges = mergeUTF16Ranges(
                changes.compactMap { change in
                    let lowerBound = max(change.lowerBound, line.range.lowerBound)
                    let upperBound = min(change.upperBound, line.range.upperBound)
                    guard lowerBound < upperBound else {
                        return nil
                    }
                    let localLowerBound = lowerBound - line.start
                    let localUpperBound = upperBound - line.start
                    guard line.characters[localLowerBound..<localUpperBound].contains(
                        where: { !isWhitespace($0) }
                    ) else {
                        return nil
                    }
                    return boundaries[localLowerBound]..<boundaries[localUpperBound]
                }
            )
            guard !ranges.isEmpty else {
                return nil
            }
            return GitIntralineHighlight(
                lineIndex: line.hunkLineIndex,
                utf16Ranges: ranges
            )
        }
    }

    private static func mergeUTF16Ranges(_ ranges: [Range<Int>]) -> [Range<Int>] {
        guard var previous = ranges.first else {
            return []
        }
        var result: [Range<Int>] = []
        for current in ranges.dropFirst() {
            if current.lowerBound <= previous.upperBound {
                previous = previous.lowerBound..<max(previous.upperBound, current.upperBound)
            } else {
                result.append(previous)
                previous = current
            }
        }
        result.append(previous)
        return result
    }

    private static func isWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    private static func utf16Boundaries(for characters: [Character]) -> [Int] {
        var result = [0]
        result.reserveCapacity(characters.count + 1)
        for character in characters {
            result.append(result[result.count - 1] + String(character).utf16.count)
        }
        return result
    }
}
