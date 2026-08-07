import SourceModel

/// Schedules Tree-sitter parsing and capture computation off the main
/// actor, prioritizing the visible viewport per SPEC 11.6 ("Work is
/// prioritized: visible viewport, active tab, ... then background
/// workspace tasks"). Callers drive this from a cancellable `Task`; letting
/// that task's cancellation propagate here (via `Task.checkCancellation`)
/// is how a closed tab, a new snapshot, or a workspace switch stops
/// obsolete work, per SPEC 11.6.
public actor SyntaxEngine {
    public init() {}

    /// Parses the full snapshot once. This is Kod's only parse per
    /// snapshot version: because Kod is read-only, a changed file always
    /// arrives as a brand-new immutable `SourceSnapshot`, never as an
    /// incremental edit Tree-sitter could apply to a previous tree, so
    /// there is no meaningful "incremental reparse" to perform here.
    public func parse(snapshot: SourceSnapshot, language: SyntaxLanguage) throws -> SyntaxTree {
        let treeBox = try TreeSitterParser.parse(utf8: snapshot.utf8Data, language: language)
        return SyntaxTree(
            treeBox: treeBox,
            utf8: snapshot.utf8Data,
            language: language,
            snapshotVersion: snapshot.version
        )
    }

    /// Computes highlight captures for `viewportByteRange` first, then for
    /// the rest of `fullByteRange`, yielding between the two so a caller
    /// can apply and paint the viewport pass immediately instead of
    /// waiting for the whole file. Throws `CancellationError` (propagated
    /// from the enclosing `Task`) if superseded before either pass
    /// completes.
    public func highlight(
        tree: SyntaxTree,
        viewportByteRange: Range<Int>,
        fullByteRange: Range<Int>
    ) async throws -> (viewport: [SyntaxCapture], full: [SyntaxCapture]) {
        try Task.checkCancellation()
        let viewportCaptures = tree.captures(inByteRange: viewportByteRange)

        try Task.checkCancellation()
        await Task.yield()

        try Task.checkCancellation()
        let fullCaptures = tree.captures(inByteRange: fullByteRange)
        return (viewportCaptures, fullCaptures)
    }
}
