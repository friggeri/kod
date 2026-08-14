import SyntaxCore
import TextDecorationModel
import ThemeCore

/// Converts raw Tree-sitter highlight captures into a `.lexical`
/// `DecorationLayerSnapshot`, resolving each capture's dotted name against
/// the active theme's syntax color table. This mapping is presentation, not
/// parsing: `SyntaxCore` produces captures only and knows nothing about
/// themes.
public enum LexicalDecorationSource {
    public static func layer(
        fromCaptures captures: [SyntaxCapture],
        theme: KodTheme,
        snapshotVersion: Int,
        layerVersion: Int
    ) -> DecorationLayerSnapshot {
        let runs = captures.map { capture -> DecorationRun in
            let style = theme.lexicalStyle(forCapture: capture.name)
            return DecorationRun(
                utf8Range: capture.utf8Range,
                attributes: DecorationAttributes(
                    foreground: style.foreground,
                    background: style.background,
                    isBold: style.isBold,
                    isItalic: style.isItalic,
                    isUnderlined: style.isUnderlined,
                    isStrikethrough: style.isStrikethrough
                )
            )
        }
        return DecorationLayerSnapshot(
            kind: .lexical,
            snapshotVersion: snapshotVersion,
            layerVersion: layerVersion,
            runs: runs
        )
    }
}
