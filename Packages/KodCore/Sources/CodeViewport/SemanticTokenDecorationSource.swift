import LanguageClient
import TextDecorationModel
import ThemeCore

/// Converts validated LSP semantic tokens into a `.semantic`
/// `DecorationLayerSnapshot`, resolving each token's type/modifiers
/// against the active theme's `SemanticTokenRules`. Mirrors
/// `LexicalDecorationSource` deliberately: a token whose type/modifiers
/// combination has no rule contributes no run at all, so the `.lexical`
/// layer underneath shows through unmodified once the compositor overlays
/// both (SPEC 7.1's precedence order: semantic sits above lexical).
/// Lives in the presentation layer, not in `LanguageClient`: the transport
/// produces normalized `SemanticToken` values and never resolves a theme.
public enum SemanticTokenDecorationSource {
    public static func layer(
        fromTokens tokens: [SemanticToken],
        theme: KodTheme,
        snapshotVersion: Int,
        layerVersion: Int
    ) -> DecorationLayerSnapshot {
        let runs = tokens.compactMap { token -> DecorationRun? in
            guard let style = theme.semanticTokens.style(
                type: token.tokenType,
                modifiers: token.tokenModifiers
            ) else {
                return nil
            }
            return DecorationRun(
                utf8Range: token.utf8Range,
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
            kind: .semantic,
            snapshotVersion: snapshotVersion,
            layerVersion: layerVersion,
            runs: runs
        )
    }
}
