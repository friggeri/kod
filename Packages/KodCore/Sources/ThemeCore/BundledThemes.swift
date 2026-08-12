import Foundation

/// The four themes Kod ships per SPEC 7.2: one light, one dark, one
/// high-contrast light, and one high-contrast dark theme. Kod Light and Kod
/// Dark adapt the PVC 1.0.8 palettes; the dedicated high-contrast themes use
/// Kod's enhanced-contrast palettes.
public enum BundledThemes {
    /// Every bundled-theme color below is a fixed hex literal; a failure to
    /// parse one is a programming error in this file, not a runtime condition.
    /// Centralizing the (infallible-for-every-literal-below) unwrap here means
    /// no call site needs a literal force-unwrap token, and a broken literal
    /// still fails loudly rather than silently falling back to a default.
    private static func hex(_ value: String) -> ThemeColor {
        guard let color = ThemeColor(hex: value) else {
            preconditionFailure("Bundled theme color literal failed to parse: \(value)")
        }
        return color
    }

    private static func hex(_ value: String, alpha: Double) -> ThemeColor {
        guard let color = ThemeColor(hex: value, alpha: alpha) else {
            preconditionFailure("Bundled theme color literal failed to parse: \(value)")
        }
        return color
    }

    public static let all: [KodTheme] = [light, dark, highContrastLight, highContrastDark]

    public static func theme(forIdentifier identifier: String) -> KodTheme? {
        all.first { $0.identifier == identifier }
    }

    /// The bundled theme that best matches a system appearance, used as the
    /// initial default before a user picks or imports one.
    public static func defaultTheme(isDark: Bool, isHighContrast: Bool) -> KodTheme {
        switch (isDark, isHighContrast) {
        case (false, false): light
        case (true, false): dark
        case (false, true): highContrastLight
        case (true, true): highContrastDark
        }
    }

    public static let light = KodTheme(
        identifier: "kod.light",
        name: "Kod Light",
        appearance: .light,
        surface: SurfaceColors(
            windowBackground: hex("#F2F2F2"),
            sidebarBackground: hex("#FFFFFF"),
            sidebarForeground: hex("#242728"),
            tabActiveBackground: hex("#FFFFFF"),
            tabInactiveBackground: hex("#F2F2F2"),
            tabForeground: hex("#242728"),
            breadcrumbBackground: hex("#FFFFFF"),
            breadcrumbForeground: hex("#575A5B"),
            statusBarBackground: hex("#FFFFFF"),
            statusBarForeground: hex("#242728"),
            listActiveBackground: hex("#FFAA001A"),
            listHoverBackground: hex("#F2F2F2"),
            listForeground: hex("#242728"),
            border: hex("#E6E6E6"),
            focusBorder: hex("#FFAA00"),
            selectionBackground: hex("#D9D9D9")
        ),
        editor: EditorColors(
            background: hex("#FFFFFF"),
            foreground: hex("#242728"),
            lineHighlightBackground: hex("#F2F2F2"),
            gutterForeground: hex("#BDC0C1"),
            indentGuideForeground: hex("#F2F2F2"),
            indentGuideActiveForeground: hex("#FFAA00"),
            selectionBackground: hex("#D9D9D9"),
            matchingBracketBackground: hex("#FFFFFF"),
            stickyScopeBackground: hex("#F2F2F2"),
            foldedRegionForeground: hex("#798286")
        ),
        syntax: [
            "keyword": TokenStyle(foreground: hex("#FF006A")),
            "keyword.function": TokenStyle(foreground: hex("#00AAFF")),
            "function": TokenStyle(foreground: hex("#88CC00")),
            "function.builtin": TokenStyle(foreground: hex("#00AAFF")),
            "type": TokenStyle(foreground: hex("#88CC00")),
            "type.builtin": TokenStyle(foreground: hex("#00AAFF")),
            "variable": TokenStyle(foreground: hex("#242728")),
            "variable.builtin": TokenStyle(foreground: hex("#E67300")),
            "variable.parameter": TokenStyle(foreground: hex("#E67300")),
            "constant": TokenStyle(foreground: hex("#7733FF")),
            "constant.builtin": TokenStyle(foreground: hex("#7733FF")),
            "constant.macro": TokenStyle(foreground: hex("#88CC00")),
            "string": TokenStyle(foreground: hex("#E6BF00")),
            "string.escape": TokenStyle(foreground: hex("#7733FF")),
            "number": TokenStyle(foreground: hex("#7733FF")),
            "comment": TokenStyle(foreground: hex("#798286")),
            "operator": TokenStyle(foreground: hex("#FF006A")),
            "punctuation": TokenStyle(foreground: hex("#242728")),
            "attribute": TokenStyle(foreground: hex("#88CC00")),
            "tag": TokenStyle(foreground: hex("#FF006A")),
            "tag.error": TokenStyle(foreground: hex("#E60000")),
            "property": TokenStyle(foreground: hex("#242728")),
            "label": TokenStyle(foreground: hex("#242728")),
            "boolean": TokenStyle(foreground: hex("#7733FF")),
            "character.special": TokenStyle(foreground: hex("#7733FF")),
            "constructor": TokenStyle(foreground: hex("#88CC00")),
            "escape": TokenStyle(foreground: hex("#7733FF")),
            "embedded": TokenStyle(foreground: hex("#242728"))
        ],
        diagnostics: DiagnosticColors(
            error: hex("#E60000"),
            warning: hex("#E67300"),
            information: hex("#FF006A"),
            hint: hex("#798286")
        ),
        git: GitDecorationColors(
            added: hex("#779933"),
            modified: hex("#4095BF"),
            deleted: hex("#AC3939"),
            renamed: hex("#007100"),
            untracked: hex("#587C0C"),
            ignored: hex("#8E8E90"),
            stagedModified: hex("#895503"),
            stagedDeleted: hex("#AC3939"),
            conflict: hex("#FF006A")
        )
    )

    public static let dark = KodTheme(
        identifier: "kod.dark",
        name: "Kod Dark",
        appearance: .dark,
        surface: SurfaceColors(
            windowBackground: hex("#313435"),
            sidebarBackground: hex("#242728"),
            sidebarForeground: hex("#FAFAFA"),
            tabActiveBackground: hex("#242728"),
            tabInactiveBackground: hex("#313435"),
            tabForeground: hex("#FAFAFA"),
            breadcrumbBackground: hex("#242728"),
            breadcrumbForeground: hex("#C7C7C7"),
            statusBarBackground: hex("#242728"),
            statusBarForeground: hex("#FAFAFA"),
            listActiveBackground: hex("#FFBB331A"),
            listHoverBackground: hex("#313435"),
            listForeground: hex("#FAFAFA"),
            border: hex("#3D4041"),
            focusBorder: hex("#FFBB33"),
            selectionBackground: hex("#4A4D4E")
        ),
        editor: EditorColors(
            background: hex("#242728"),
            foreground: hex("#FAFAFA"),
            lineHighlightBackground: hex("#313435"),
            gutterForeground: hex("#616161"),
            indentGuideForeground: hex("#313435"),
            indentGuideActiveForeground: hex("#FFBB33"),
            selectionBackground: hex("#4A4D4E"),
            matchingBracketBackground: hex("#181A1B"),
            stickyScopeBackground: hex("#313435"),
            foldedRegionForeground: hex("#798286")
        ),
        syntax: [
            "keyword": TokenStyle(foreground: hex("#FF1A79")),
            "keyword.function": TokenStyle(foreground: hex("#66CCFF")),
            "function": TokenStyle(foreground: hex("#AAFF00")),
            "function.builtin": TokenStyle(foreground: hex("#66CCFF")),
            "type": TokenStyle(foreground: hex("#AAFF00")),
            "type.builtin": TokenStyle(foreground: hex("#66CCFF")),
            "variable": TokenStyle(foreground: hex("#FAFAFA")),
            "variable.builtin": TokenStyle(foreground: hex("#FF8000")),
            "variable.parameter": TokenStyle(foreground: hex("#FF8000")),
            "constant": TokenStyle(foreground: hex("#9966FF")),
            "constant.builtin": TokenStyle(foreground: hex("#9966FF")),
            "constant.macro": TokenStyle(foreground: hex("#AAFF00")),
            "string": TokenStyle(foreground: hex("#FFE666")),
            "string.escape": TokenStyle(foreground: hex("#9966FF")),
            "number": TokenStyle(foreground: hex("#9966FF")),
            "comment": TokenStyle(foreground: hex("#798286")),
            "operator": TokenStyle(foreground: hex("#FF1A79")),
            "punctuation": TokenStyle(foreground: hex("#FAFAFA")),
            "attribute": TokenStyle(foreground: hex("#AAFF00")),
            "tag": TokenStyle(foreground: hex("#FF1A79")),
            "tag.error": TokenStyle(foreground: hex("#FF6666")),
            "property": TokenStyle(foreground: hex("#FAFAFA")),
            "label": TokenStyle(foreground: hex("#FAFAFA")),
            "boolean": TokenStyle(foreground: hex("#9966FF")),
            "character.special": TokenStyle(foreground: hex("#9966FF")),
            "constructor": TokenStyle(foreground: hex("#AAFF00")),
            "escape": TokenStyle(foreground: hex("#9966FF")),
            "embedded": TokenStyle(foreground: hex("#FAFAFA"))
        ],
        diagnostics: DiagnosticColors(
            error: hex("#FF6666"),
            warning: hex("#FF8000"),
            information: hex("#FF1A79"),
            hint: hex("#798286")
        ),
        git: GitDecorationColors(
            added: hex("#95BF40"),
            modified: hex("#8CBFD9"),
            deleted: hex("#D98C8C"),
            renamed: hex("#73C991"),
            untracked: hex("#73C991"),
            ignored: hex("#8C8C8C"),
            stagedModified: hex("#E5BA7D"),
            stagedDeleted: hex("#D98C8C"),
            conflict: hex("#FF1A79")
        )
    )

    public static let highContrastLight = KodTheme(
        identifier: "kod.hc-light",
        name: "Kod High Contrast Light",
        appearance: .highContrastLight,
        surface: SurfaceColors(
            windowBackground: hex("#FFFFFF"),
            sidebarBackground: hex("#FFFFFF"),
            sidebarForeground: hex("#000000"),
            tabActiveBackground: hex("#FFFFFF"),
            tabInactiveBackground: hex("#F5F5F5"),
            tabForeground: hex("#000000"),
            breadcrumbBackground: hex("#FFFFFF"),
            breadcrumbForeground: hex("#000000"),
            statusBarBackground: hex("#000000"),
            statusBarForeground: hex("#FFFFFF"),
            listActiveBackground: hex("#0F4A99"),
            listHoverBackground: hex("#E5E5E5"),
            listForeground: hex("#000000"),
            border: hex("#000000"),
            focusBorder: hex("#0F4A99"),
            selectionBackground: hex("#0F4A99", alpha: 0.35)
        ),
        editor: EditorColors(
            background: hex("#FFFFFF"),
            foreground: hex("#000000"),
            lineHighlightBackground: hex("#EDEDED"),
            gutterForeground: hex("#000000"),
            indentGuideForeground: hex("#B0B0B0"),
            indentGuideActiveForeground: hex("#000000"),
            selectionBackground: hex("#0F4A99", alpha: 0.35),
            matchingBracketBackground: hex("#0F4A99", alpha: 0.25),
            stickyScopeBackground: hex("#F0F0F0"),
            foldedRegionForeground: hex("#000000")
        ),
        syntax: [
            "keyword": TokenStyle(foreground: hex("#6F0089"), isBold: true),
            "function": TokenStyle(foreground: hex("#003C9E")),
            "function.builtin": TokenStyle(foreground: hex("#7A3E00")),
            "type": TokenStyle(foreground: hex("#7A4E00")),
            "type.builtin": TokenStyle(foreground: hex("#7A4E00")),
            "variable": TokenStyle(foreground: hex("#000000")),
            "variable.builtin": TokenStyle(foreground: hex("#9E1A00")),
            "variable.parameter": TokenStyle(foreground: hex("#7A3E00"), isItalic: true),
            "constant": TokenStyle(foreground: hex("#7A3E00")),
            "constant.builtin": TokenStyle(foreground: hex("#00548C")),
            "string": TokenStyle(foreground: hex("#032F62")),
            "number": TokenStyle(foreground: hex("#7A3E00")),
            "comment": TokenStyle(foreground: hex("#4B4D52"), isItalic: true),
            "operator": TokenStyle(foreground: hex("#000000")),
            "punctuation": TokenStyle(foreground: hex("#000000")),
            "attribute": TokenStyle(foreground: hex("#7A3E00")),
            "tag": TokenStyle(foreground: hex("#9E1A00"), isBold: true),
            "property": TokenStyle(foreground: hex("#9E1A00")),
            "label": TokenStyle(foreground: hex("#6F0089")),
            "boolean": TokenStyle(foreground: hex("#00548C")),
            "constructor": TokenStyle(foreground: hex("#7A4E00")),
            "escape": TokenStyle(foreground: hex("#00548C")),
            "embedded": TokenStyle(foreground: hex("#000000"))
        ],
        diagnostics: DiagnosticColors(
            error: hex("#B00020"),
            warning: hex("#7A4E00"),
            information: hex("#003C9E"),
            hint: hex("#4B4D52")
        ),
        git: GitDecorationColors(
            added: hex("#0A5C00"),
            modified: hex("#003C9E"),
            deleted: hex("#9E1A00"),
            renamed: hex("#0A5C00"),
            untracked: hex("#587C0C"),
            ignored: hex("#595959"),
            stagedModified: hex("#667309"),
            stagedDeleted: hex("#9E1A00"),
            conflict: hex("#6F0089")
        )
    )

    public static let highContrastDark = KodTheme(
        identifier: "kod.hc-dark",
        name: "Kod High Contrast Dark",
        appearance: .highContrastDark,
        surface: SurfaceColors(
            windowBackground: hex("#000000"),
            sidebarBackground: hex("#000000"),
            sidebarForeground: hex("#FFFFFF"),
            tabActiveBackground: hex("#000000"),
            tabInactiveBackground: hex("#0A0A0A"),
            tabForeground: hex("#FFFFFF"),
            breadcrumbBackground: hex("#000000"),
            breadcrumbForeground: hex("#FFFFFF"),
            statusBarBackground: hex("#FFFFFF"),
            statusBarForeground: hex("#000000"),
            listActiveBackground: hex("#2B75CC"),
            listHoverBackground: hex("#1A1A1A"),
            listForeground: hex("#FFFFFF"),
            border: hex("#FFFFFF"),
            focusBorder: hex("#2B75CC"),
            selectionBackground: hex("#2B75CC", alpha: 0.4)
        ),
        editor: EditorColors(
            background: hex("#000000"),
            foreground: hex("#FFFFFF"),
            lineHighlightBackground: hex("#161616"),
            gutterForeground: hex("#FFFFFF"),
            indentGuideForeground: hex("#5A5A5A"),
            indentGuideActiveForeground: hex("#FFFFFF"),
            selectionBackground: hex("#2B75CC", alpha: 0.4),
            matchingBracketBackground: hex("#2B75CC", alpha: 0.3),
            stickyScopeBackground: hex("#0F0F0F"),
            foldedRegionForeground: hex("#FFFFFF")
        ),
        syntax: [
            "keyword": TokenStyle(foreground: hex("#D18AFF"), isBold: true),
            "function": TokenStyle(foreground: hex("#FFFFAA")),
            "function.builtin": TokenStyle(foreground: hex("#FFD98A")),
            "type": TokenStyle(foreground: hex("#7CE0C6")),
            "type.builtin": TokenStyle(foreground: hex("#7CE0C6")),
            "variable": TokenStyle(foreground: hex("#FFFFFF")),
            "variable.builtin": TokenStyle(foreground: hex("#8CC8FF")),
            "variable.parameter": TokenStyle(foreground: hex("#C6ECFF"), isItalic: true),
            "constant": TokenStyle(foreground: hex("#8CE1FF")),
            "constant.builtin": TokenStyle(foreground: hex("#8CC8FF")),
            "string": TokenStyle(foreground: hex("#FFB392")),
            "number": TokenStyle(foreground: hex("#D6EFC0")),
            "comment": TokenStyle(foreground: hex("#9FE39F"), isItalic: true),
            "operator": TokenStyle(foreground: hex("#FFFFFF")),
            "punctuation": TokenStyle(foreground: hex("#FFFFFF")),
            "attribute": TokenStyle(foreground: hex("#C6ECFF")),
            "tag": TokenStyle(foreground: hex("#8CC8FF"), isBold: true),
            "property": TokenStyle(foreground: hex("#C6ECFF")),
            "label": TokenStyle(foreground: hex("#E6E6E6")),
            "boolean": TokenStyle(foreground: hex("#8CC8FF")),
            "constructor": TokenStyle(foreground: hex("#7CE0C6")),
            "escape": TokenStyle(foreground: hex("#F0DDA0")),
            "embedded": TokenStyle(foreground: hex("#FFFFFF"))
        ],
        diagnostics: DiagnosticColors(
            error: hex("#FF8A8A"),
            warning: hex("#FFE066"),
            information: hex("#8CC8FF"),
            hint: hex("#E6E6E6")
        ),
        git: GitDecorationColors(
            added: hex("#8FE388"),
            modified: hex("#8CC8FF"),
            deleted: hex("#FF8A8A"),
            renamed: hex("#73C991"),
            untracked: hex("#73C991"),
            ignored: hex("#B3B3B3"),
            stagedModified: hex("#E5BA7D"),
            stagedDeleted: hex("#FF8A8A"),
            conflict: hex("#D18AFF")
        )
    )
}
