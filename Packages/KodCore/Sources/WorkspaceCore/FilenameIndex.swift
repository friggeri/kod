import Foundation

public struct FilenameMatch: Equatable, Sendable {
    public let entry: WorkspaceFileEntry
    public let score: Int
    public let matchedCharacterOffsets: [Int]

    public init(
        entry: WorkspaceFileEntry,
        score: Int,
        matchedCharacterOffsets: [Int]
    ) {
        self.entry = entry
        self.score = score
        self.matchedCharacterOffsets = matchedCharacterOffsets
    }
}

public actor FilenameIndex {
    private struct IndexedEntry: Sendable {
        let entry: WorkspaceFileEntry
        let lowercasedPath: String
        let lowercasedBasename: String
        let lowercasedStem: String
        let depth: Int
    }

    private var entries: [IndexedEntry] = []
    private var exactPaths: [String: Int] = [:]
    private var duplicatePaths: [String: [Int]] = [:]
    private var exactStems: [String: Int] = [:]
    private var duplicateStems: [String: [Int]] = [:]
    /// Tombstoned entry indices from incremental `remove(relativePaths:)`
    /// calls. Kept as a removal set rather than physically compacting the
    /// backing arrays, since the FSEvents-driven callers of this method
    /// remove a handful of paths per coalesced batch, not the whole index.
    private var removedIndices: Set<Int> = []

    public init() {}

    public var count: Int {
        entries.count - removedIndices.count
    }

    public func append(_ newEntries: [WorkspaceFileEntry]) {
        for entry in newEntries where entry.kind != .directory {
            let path = entry.relativePath.lowercased()
            let basename = entry.url.lastPathComponent.lowercased()
            let stem = entry.url.deletingPathExtension()
                .lastPathComponent
                .lowercased()
            let index = entries.count
            entries.append(
                IndexedEntry(
                    entry: entry,
                    lowercasedPath: path,
                    lowercasedBasename: basename,
                    lowercasedStem: stem,
                    depth: entry.relativePath.filter { $0 == "/" }.count
                )
            )
            appendExactIndex(
                index,
                key: path,
                primary: &exactPaths,
                duplicates: &duplicatePaths
            )
            appendExactIndex(
                index,
                key: stem,
                primary: &exactStems,
                duplicates: &duplicateStems
            )
        }
    }

    /// Incrementally removes every entry whose `relativePath` is in
    /// `relativePaths` (exact match, case-sensitive), used to react to
    /// FSEvents-reported deletes/moves without rescanning the workspace.
    /// A no-op for any path not currently indexed.
    public func remove(relativePaths: some Sequence<String>) {
        for relativePath in relativePaths {
            let lowercased = relativePath.lowercased()
            guard let candidates = exactIndices(
                for: lowercased,
                primary: exactPaths,
                duplicates: duplicatePaths
            ) else {
                continue
            }
            for index in candidates
            where entries[index].entry.relativePath == relativePath && !removedIndices.contains(index) {
                removedIndices.insert(index)
            }
        }
    }

    public func removeAll(keepingCapacity: Bool = true) {
        entries.removeAll(keepingCapacity: keepingCapacity)
        exactPaths.removeAll(keepingCapacity: keepingCapacity)
        duplicatePaths.removeAll(keepingCapacity: keepingCapacity)
        exactStems.removeAll(keepingCapacity: keepingCapacity)
        duplicateStems.removeAll(keepingCapacity: keepingCapacity)
        removedIndices.removeAll(keepingCapacity: keepingCapacity)
    }

    public func search(
        _ query: String,
        limit: Int = 100
    ) -> [FilenameMatch] {
        guard limit > 0 else {
            return []
        }

        let normalizedQuery = query.lowercased()
        let queryBytes = Array(normalizedQuery.utf8)
        if normalizedQuery.isEmpty {
            var results: [FilenameMatch] = []
            results.reserveCapacity(limit)
            for (index, indexed) in entries.enumerated() {
                guard !removedIndices.contains(index) else {
                    continue
                }
                results.append(
                    FilenameMatch(
                        entry: indexed.entry,
                        score: -indexed.depth,
                        matchedCharacterOffsets: []
                    )
                )
                if results.count >= limit {
                    break
                }
            }
            return results
        }

        let exactIndices = exactIndices(
            for: normalizedQuery,
            primary: exactPaths,
            duplicates: duplicatePaths
        ) ?? exactIndices(
            for: normalizedQuery,
            primary: exactStems,
            duplicates: duplicateStems
        )
        if let exactIndices {
            return exactIndices
                .filter { !removedIndices.contains($0) }
                .prefix(limit)
                .map { index in
                    FilenameMatch(
                        entry: entries[index].entry,
                        score: 10_000 - entries[index].depth,
                        matchedCharacterOffsets: []
                    )
                }
                .sorted(by: isBetterMatch)
        }

        var best: [FilenameMatch] = []
        best.reserveCapacity(min(limit * 4, entries.count))

        for (index, indexed) in entries.enumerated() {
            guard !removedIndices.contains(index) else {
                continue
            }
            guard let fuzzy = fuzzyMatch(
                query: queryBytes,
                candidate: indexed.lowercasedPath
            ) else {
                continue
            }

            var score = fuzzy.score
            if indexed.lowercasedStem == normalizedQuery {
                score += 3_000
            } else if indexed.lowercasedBasename == normalizedQuery {
                score += 2_000
            } else if indexed.lowercasedBasename.hasPrefix(normalizedQuery) {
                score += 800
            } else if indexed.lowercasedBasename.contains(normalizedQuery) {
                score += 300
            }
            score -= indexed.depth * 8
            score -= indexed.lowercasedPath.count / 4

            best.append(
                FilenameMatch(
                    entry: indexed.entry,
                    score: score,
                    matchedCharacterOffsets: fuzzy.offsets
                )
            )

            if best.count >= limit * 4 {
                best.sort(by: isBetterMatch)
                best.removeSubrange(limit..<best.count)
            }
        }

        best.sort(by: isBetterMatch)
        if best.count > limit {
            best.removeSubrange(limit..<best.count)
        }
        return best
    }

    private func appendExactIndex(
        _ index: Int,
        key: String,
        primary: inout [String: Int],
        duplicates: inout [String: [Int]]
    ) {
        guard let first = primary[key] else {
            primary[key] = index
            return
        }
        if duplicates[key] == nil {
            duplicates[key] = [first]
        }
        duplicates[key]?.append(index)
    }

    private func exactIndices(
        for key: String,
        primary: [String: Int],
        duplicates: [String: [Int]]
    ) -> [Int]? {
        if let duplicates = duplicates[key] {
            return duplicates
        }
        guard let index = primary[key] else {
            return nil
        }
        return [index]
    }
}

private func fuzzyMatch(
    query: [UInt8],
    candidate: String
) -> (score: Int, offsets: [Int])? {
    guard !query.isEmpty, query.count <= candidate.utf8.count else {
        return nil
    }

    var queryIndex = 0
    var offsets: [Int] = []
    offsets.reserveCapacity(query.count)
    var score = 0
    var previousOffset: Int?
    var previousByte: UInt8?
    var offset = 0

    for byte in candidate.utf8 {
        guard queryIndex < query.count else {
            break
        }
        defer {
            previousByte = byte
            offset += 1
        }
        guard byte == query[queryIndex] else {
            continue
        }

        offsets.append(offset)
        score += 20
        if let previousOffset, previousOffset + 1 == offset {
            score += 18
        }
        if offset == 0 || previousByte.map(isPathBoundary) == true {
            score += 24
        }

        previousOffset = offset
        queryIndex += 1
    }

    guard queryIndex == query.count else {
        return nil
    }
    return (score, offsets)
}

private func isPathBoundary(_ byte: UInt8) -> Bool {
    byte == 0x2F || byte == 0x2D || byte == 0x5F || byte == 0x2E
}

private func isBetterMatch(_ lhs: FilenameMatch, _ rhs: FilenameMatch) -> Bool {
    if lhs.score != rhs.score {
        return lhs.score > rhs.score
    }
    return lhs.entry.relativePath.localizedStandardCompare(
        rhs.entry.relativePath
    ) == .orderedAscending
}
