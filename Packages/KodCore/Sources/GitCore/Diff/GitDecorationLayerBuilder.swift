import Foundation
import SourceModel
import SyntaxCore
import ThemeCore

/// Converts a file's Git line decorations into a `DecorationLayerSnapshot`
/// for `DecorationCompositor`'s `.gitChange` layer (SPEC 9.1's inline
/// added/modified gutter markers, integrated through the same versioned
/// layer/composition pipeline as syntax highlighting, search, and
/// diagnostics — see `DecorationLayerKind`). Pure deletion markers (no
/// corresponding added line) are returned alongside rather than folded
/// into the byte-range layer, since there is no line of current content
/// for them to tint; callers render those directly as a gutter boundary
/// indicator.
public enum GitDecorationLayerBuilder {
    public static func layer(
        for hunks: [GitDiffHunk],
        snapshot: SourceSnapshot,
        colors: GitDecorationColors,
        snapshotVersion: Int,
        layerVersion: Int
    ) -> (layer: DecorationLayerSnapshot, deletions: [GitDeletionMarker]) {
        let (changes, deletions) = GitLineDecorationBuilder.lineDecorations(for: hunks)

        var runs: [DecorationRun] = []
        runs.reserveCapacity(changes.count)
        for change in changes {
            // Git line numbers are 1-based; `SourceSnapshot`'s line
            // storage is 0-based.
            guard let range = snapshot.utf8RangeForLine(change.newLineNumber - 1), !range.isEmpty else {
                continue
            }
            let color: ThemeColor
            switch change.kind {
            case .added:
                color = colors.added
            case .modified:
                color = colors.modified
            }
            runs.append(DecorationRun(utf8Range: range, attributes: DecorationAttributes(background: color)))
        }

        let layer = DecorationLayerSnapshot(
            kind: .gitChange,
            snapshotVersion: snapshotVersion,
            layerVersion: layerVersion,
            runs: runs
        )
        return (layer, deletions)
    }
}
