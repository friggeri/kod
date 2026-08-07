import SourceModel

/// The reading state Kod tries to preserve when an open file's snapshot is
/// replaced (SPEC 5.6: "Reload preserves the selected logical line, nearest
/// symbol, folds, and viewport anchor when possible"). Folds are represented
/// by their header line number, matching `CodeViewport`'s
/// `foldedHeaderLines`.
public struct ReadingAnchor: Equatable, Sendable {
    public var selection: EditorSelection?
    public var viewportAnchorLine: Int
    public var foldedHeaderLines: Set<Int>

    public init(
        selection: EditorSelection? = nil,
        viewportAnchorLine: Int = 0,
        foldedHeaderLines: Set<Int> = []
    ) {
        self.selection = selection
        self.viewportAnchorLine = viewportAnchorLine
        self.foldedHeaderLines = foldedHeaderLines
    }
}

/// Maps a `ReadingAnchor` computed against one `SourceSnapshot` onto the
/// next snapshot of the same file after an external change, on a
/// best-effort basis, without ever throwing or requiring the content to be
/// identical.
///
/// The strategy is deliberately simple and content-addressed rather than a
/// full diff/patience-diff algorithm: for each anchored line, search
/// outward (nearest offset first) within a bounded window for a line in the
/// new snapshot with byte-identical content, and fall back to a clamped
/// line number when no match is found nearby. This is O(window) per
/// anchored line, cheap enough to run synchronously on every external
/// reload, and good enough for the common case of a small, local edit
/// leaving most of the file's lines unchanged and in roughly the same
/// place.
public enum ReadingAnchorReconciler {
    /// How many lines away from the original position to search for a
    /// matching line before giving up and clamping instead.
    public static let defaultSearchWindow = 200

    public static func reconcile(
        _ anchor: ReadingAnchor,
        from oldSnapshot: SourceSnapshot,
        to newSnapshot: SourceSnapshot,
        searchWindow: Int = defaultSearchWindow
    ) -> ReadingAnchor {
        let newViewportLine = reconcileLine(
            anchor.viewportAnchorLine,
            from: oldSnapshot,
            to: newSnapshot,
            searchWindow: searchWindow
        )
        let newSelection = anchor.selection.map {
            reconcileSelection($0, from: oldSnapshot, to: newSnapshot, searchWindow: searchWindow)
        }
        let newFolds = Set(
            anchor.foldedHeaderLines.map {
                reconcileLine($0, from: oldSnapshot, to: newSnapshot, searchWindow: searchWindow)
            }
        )

        return ReadingAnchor(
            selection: newSelection,
            viewportAnchorLine: newViewportLine,
            foldedHeaderLines: newFolds
        )
    }

    /// Finds the best line in `newSnapshot` to represent `line` from
    /// `oldSnapshot`: the nearest line (by absolute line-number distance,
    /// preferring the original line itself, then earlier lines over later
    /// ones on ties) whose text is byte-identical, or `line` clamped into
    /// `newSnapshot`'s bounds if no such line exists within `searchWindow`.
    private static func reconcileLine(
        _ line: Int,
        from oldSnapshot: SourceSnapshot,
        to newSnapshot: SourceSnapshot,
        searchWindow: Int
    ) -> Int {
        let clampedFallback = max(0, min(line, newSnapshot.lineCount - 1))
        guard newSnapshot.lineCount > 0 else {
            return 0
        }
        guard let oldText = oldSnapshot.line(at: line) else {
            return clampedFallback
        }
        if newSnapshot.line(at: line) == oldText {
            return line
        }

        for delta in 1...max(1, searchWindow) {
            let earlier = line - delta
            if earlier >= 0, newSnapshot.line(at: earlier) == oldText {
                return earlier
            }
            let later = line + delta
            if later < newSnapshot.lineCount, newSnapshot.line(at: later) == oldText {
                return later
            }
        }

        return clampedFallback
    }

    private static func reconcileSelection(
        _ selection: EditorSelection,
        from oldSnapshot: SourceSnapshot,
        to newSnapshot: SourceSnapshot,
        searchWindow: Int
    ) -> EditorSelection {
        guard newSnapshot.lineCount > 0 else {
            return EditorSelection(lowerBound: 0, upperBound: 0)
        }

        guard let startPosition = try? oldSnapshot.position(
            forUTF8Offset: selection.lowerBound,
            encoding: .utf8
        ), let endPosition = try? oldSnapshot.position(
            forUTF8Offset: selection.upperBound,
            encoding: .utf8
        ) else {
            return EditorSelection(lowerBound: 0, upperBound: 0)
        }

        let newStart = reconcileOffset(
            line: startPosition.line,
            character: startPosition.character,
            from: oldSnapshot,
            to: newSnapshot,
            searchWindow: searchWindow
        )
        let newEnd = startPosition.line == endPosition.line
            ? reconcileOffset(
                line: startPosition.line,
                character: endPosition.character,
                from: oldSnapshot,
                to: newSnapshot,
                searchWindow: searchWindow,
                reconciledLine: newStart.line
            )
            : reconcileOffset(
                line: endPosition.line,
                character: endPosition.character,
                from: oldSnapshot,
                to: newSnapshot,
                searchWindow: searchWindow
            )

        let lowerBound = min(newStart.utf8Offset, newEnd.utf8Offset)
        let upperBound = max(newStart.utf8Offset, newEnd.utf8Offset)
        return EditorSelection(lowerBound: lowerBound, upperBound: upperBound)
    }

    private static func reconcileOffset(
        line: Int,
        character: Int,
        from oldSnapshot: SourceSnapshot,
        to newSnapshot: SourceSnapshot,
        searchWindow: Int,
        reconciledLine: Int? = nil
    ) -> (line: Int, utf8Offset: Int) {
        let newLine = reconciledLine ?? reconcileLine(
            line,
            from: oldSnapshot,
            to: newSnapshot,
            searchWindow: searchWindow
        )
        guard let newRange = newSnapshot.utf8RangeForLine(newLine) else {
            return (newLine, 0)
        }
        let newLineLength = newRange.upperBound - newRange.lowerBound
        let clampedCharacter = max(0, min(character, newLineLength))
        return (newLine, newRange.lowerBound + clampedCharacter)
    }
}
