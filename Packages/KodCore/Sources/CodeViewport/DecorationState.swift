import SyntaxCore
import TextDecorationModel
import ThemeCore

/// Versioned visual-decoration state. Rendering consumes only composed runs;
/// lexical captures are retained solely to recolor them on a theme change.
@MainActor
final class DecorationState {
    private let compositor: DecorationCompositor
    private(set) var lexicalCaptures: [SyntaxCapture] = []

    init(snapshotVersion: Int) {
        compositor = DecorationCompositor(activeSnapshotVersion: snapshotVersion)
    }

    @discardableResult
    func applyLexical(
        _ captures: [SyntaxCapture],
        theme: KodTheme,
        snapshotVersion: Int,
        layerVersion: Int
    ) -> Bool {
        let layer = LexicalDecorationSource.layer(
            fromCaptures: captures,
            theme: theme,
            snapshotVersion: snapshotVersion,
            layerVersion: layerVersion
        )
        guard compositor.apply(layer) else {
            return false
        }
        lexicalCaptures = captures
        return true
    }

    @discardableResult
    func apply(_ layer: DecorationLayerSnapshot) -> Bool {
        compositor.apply(layer)
    }

    func reapplyLexical(theme: KodTheme) {
        guard !lexicalCaptures.isEmpty,
              let version = compositor.layerVersion(for: .lexical) else {
            return
        }
        let layer = LexicalDecorationSource.layer(
            fromCaptures: lexicalCaptures,
            theme: theme,
            snapshotVersion: compositor.activeSnapshotVersion,
            layerVersion: version
        )
        compositor.apply(layer)
    }

    func composedRuns(in range: Range<Int>) -> [DecorationRun] {
        compositor.composedRuns(inUTF8Range: range)
    }

    var bracketExclusionRanges: [Range<Int>] {
        lexicalCaptures
            .filter { $0.name.hasPrefix("string") || $0.name.hasPrefix("comment") }
            .map(\.utf8Range)
    }
}
