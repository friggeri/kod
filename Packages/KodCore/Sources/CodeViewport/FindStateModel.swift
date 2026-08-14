import SourceModel

extension CodeDocumentViewController {
    public struct FindState: Equatable, Sendable {
        public let query: String
        public let options: FindOptions
        public let currentMatchIndex: Int?
        public let isVisible: Bool
        let hadKeyboardFocus: Bool
    }
}

enum FindQueryOutcome: Equatable {
    case empty
    case invalid
    case noResults
    case matches
}

/// Pure find-result and navigation state. The controller remains responsible
/// for search-field appearance, focus, and revealing the selected match.
struct FindStateModel {
    private(set) var matches: [FindMatch] = []
    private(set) var currentMatchIndex: Int?

    var currentMatch: FindMatch? {
        guard let currentMatchIndex, matches.indices.contains(currentMatchIndex) else {
            return nil
        }
        return matches[currentMatchIndex]
    }

    var statusText: String {
        guard !matches.isEmpty, let currentMatchIndex else {
            return matches.isEmpty ? "No Results" : ""
        }
        return "\(currentMatchIndex + 1) of \(matches.count)"
    }

    @discardableResult
    mutating func search(
        snapshot: SourceSnapshot,
        query: String,
        options: FindOptions,
        anchorUTF8Offset: Int
    ) -> FindQueryOutcome {
        guard !query.isEmpty else {
            matches = []
            currentMatchIndex = nil
            return .empty
        }
        do {
            matches = try TextFinder.find(in: snapshot, query: query, options: options)
        } catch {
            matches = []
            currentMatchIndex = nil
            return .invalid
        }
        guard !matches.isEmpty else {
            currentMatchIndex = nil
            return .noResults
        }
        currentMatchIndex = matches.firstIndex {
            $0.utf8Range.lowerBound >= anchorUTF8Offset
        } ?? 0
        return .matches
    }

    @discardableResult
    mutating func select(offsetBy delta: Int) -> FindMatch? {
        guard !matches.isEmpty else {
            return nil
        }
        let base = currentMatchIndex ?? 0
        currentMatchIndex = ((base + delta) % matches.count + matches.count) % matches.count
        return currentMatch
    }

    @discardableResult
    mutating func select(index: Int) -> FindMatch? {
        guard matches.indices.contains(index) else {
            return nil
        }
        currentMatchIndex = index
        return currentMatch
    }
}
