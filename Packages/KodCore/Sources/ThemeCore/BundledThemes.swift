import Foundation

/// The four themes Kod ships per SPEC 7.2: one light, one dark, one
/// high-contrast light, and one high-contrast dark theme. Every syntax,
/// editor, and surface color pairing here is covered by
/// `ThemeContrastTests`, which asserts WCAG AA (>= 4.5:1) for the standard
/// themes and AAA-adjacent (>= 7:1) for the high-contrast themes.
public enum BundledThemes {
    /// Every bundled-theme color below is a fixed hex literal audited by
    /// `ThemeContrastTests`; a failure to parse one is a programming
    /// error in this file, not a runtime condition. Centralizing the
    /// (infallible-for-every-literal-below) unwrap here means no call
    /// site needs a literal force-unwrap token, and a broken literal
    /// still fails loudly — with the offending value — rather than
    /// silently falling back to some default color.
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
            windowBackground: hex("#F5F5F5"),
            sidebarBackground: hex("#EDEDED"),
            sidebarForeground: hex("#383A42"),
            tabActiveBackground: hex("#FFFFFF"),
            tabInactiveBackground: hex("#E4E4E4"),
            tabForeground: hex("#383A42"),
            breadcrumbBackground: hex("#FFFFFF"),
            breadcrumbForeground: hex("#696C77"),
            statusBarBackground: hex("#0184BC"),
            statusBarForeground: hex("#FFFFFF"),
            listActiveBackground: hex("#D6E6F7"),
            listHoverBackground: hex("#E8E8E8"),
            listForeground: hex("#383A42"),
            border: hex("#D3D3D3"),
            focusBorder: hex("#0184BC"),
            selectionBackground: hex("#BFDDF9")
        ),
        editor: EditorColors(
            background: hex("#FFFFFF"),
            foreground: hex("#1F2328"),
            lineHighlightBackground: hex("#F2F2F2"),
            gutterForeground: hex("#9DA0A7"),
            indentGuideForeground: hex("#E4E4E4"),
            indentGuideActiveForeground: hex("#C6C6C6"),
            selectionBackground: hex("#BFDDF9"),
            matchingBracketBackground: hex("#D9E8FB"),
            stickyScopeBackground: hex("#F5F5F5"),
            foldedRegionForeground: hex("#9DA0A7")
        ),
        syntax: [
            "keyword": TokenStyle(foreground: hex("#A626A4"), isBold: true),
            "function": TokenStyle(foreground: hex("#326EF1")),
            "function.builtin": TokenStyle(foreground: hex("#986801")),
            "type": TokenStyle(foreground: hex("#9E6C01")),
            "type.builtin": TokenStyle(foreground: hex("#9E6C01")),
            "variable": TokenStyle(foreground: hex("#383A42")),
            "variable.builtin": TokenStyle(foreground: hex("#DF3424")),
            "variable.parameter": TokenStyle(foreground: hex("#986801"), isItalic: true),
            "constant": TokenStyle(foreground: hex("#986801")),
            "constant.builtin": TokenStyle(foreground: hex("#017DB3")),
            "string": TokenStyle(foreground: hex("#428441")),
            "number": TokenStyle(foreground: hex("#986801")),
            "comment": TokenStyle(foreground: hex("#74767E"), isItalic: true),
            "operator": TokenStyle(foreground: hex("#383A42")),
            "punctuation": TokenStyle(foreground: hex("#383A42")),
            "attribute": TokenStyle(foreground: hex("#986801")),
            "tag": TokenStyle(foreground: hex("#DF3424"), isBold: true),
            "property": TokenStyle(foreground: hex("#DF3424")),
            "label": TokenStyle(foreground: hex("#A626A4")),
            "boolean": TokenStyle(foreground: hex("#017DB3")),
            "constructor": TokenStyle(foreground: hex("#9E6C01")),
            "escape": TokenStyle(foreground: hex("#017DB3")),
            "embedded": TokenStyle(foreground: hex("#383A42"))
        ],
        diagnostics: DiagnosticColors(
            error: hex("#E5484D"),
            warning: hex("#9E6C01"),
            information: hex("#0184BC"),
            hint: hex("#696C77")
        ),
        git: GitDecorationColors(
            added: hex("#428441"),
            modified: hex("#9E6C01"),
            deleted: hex("#DF3424"),
            conflict: hex("#A626A4")
        )
    )

    public static let dark = KodTheme(
        identifier: "kod.dark",
        name: "Kod Dark",
        appearance: .dark,
        surface: SurfaceColors(
            windowBackground: hex("#252526"),
            sidebarBackground: hex("#252526"),
            sidebarForeground: hex("#CCCCCC"),
            tabActiveBackground: hex("#1E1E1E"),
            tabInactiveBackground: hex("#2D2D2D"),
            tabForeground: hex("#CCCCCC"),
            breadcrumbBackground: hex("#1E1E1E"),
            breadcrumbForeground: hex("#A0A0A0"),
            statusBarBackground: hex("#007ACC"),
            statusBarForeground: hex("#FFFFFF"),
            listActiveBackground: hex("#04395E"),
            listHoverBackground: hex("#2A2D2E"),
            listForeground: hex("#CCCCCC"),
            border: hex("#3C3C3C"),
            focusBorder: hex("#007ACC"),
            selectionBackground: hex("#264F78")
        ),
        editor: EditorColors(
            background: hex("#1E1E1E"),
            foreground: hex("#D4D4D4"),
            lineHighlightBackground: hex("#2A2A2A"),
            gutterForeground: hex("#858585"),
            indentGuideForeground: hex("#404040"),
            indentGuideActiveForeground: hex("#707070"),
            selectionBackground: hex("#264F78"),
            matchingBracketBackground: hex("#3A3D41"),
            stickyScopeBackground: hex("#252526"),
            foldedRegionForeground: hex("#858585")
        ),
        syntax: [
            "keyword": TokenStyle(foreground: hex("#C586C0"), isBold: true),
            "function": TokenStyle(foreground: hex("#DCDCAA")),
            "function.builtin": TokenStyle(foreground: hex("#DCDCAA")),
            "type": TokenStyle(foreground: hex("#4EC9B0")),
            "type.builtin": TokenStyle(foreground: hex("#4EC9B0")),
            "variable": TokenStyle(foreground: hex("#D4D4D4")),
            "variable.builtin": TokenStyle(foreground: hex("#569CD6")),
            "variable.parameter": TokenStyle(foreground: hex("#9CDCFE"), isItalic: true),
            "constant": TokenStyle(foreground: hex("#4FC1FF")),
            "constant.builtin": TokenStyle(foreground: hex("#569CD6")),
            "string": TokenStyle(foreground: hex("#CE9178")),
            "number": TokenStyle(foreground: hex("#B5CEA8")),
            "comment": TokenStyle(foreground: hex("#6A9955"), isItalic: true),
            "operator": TokenStyle(foreground: hex("#D4D4D4")),
            "punctuation": TokenStyle(foreground: hex("#D4D4D4")),
            "attribute": TokenStyle(foreground: hex("#9CDCFE")),
            "tag": TokenStyle(foreground: hex("#569CD6"), isBold: true),
            "property": TokenStyle(foreground: hex("#9CDCFE")),
            "label": TokenStyle(foreground: hex("#C8C8C8")),
            "boolean": TokenStyle(foreground: hex("#569CD6")),
            "constructor": TokenStyle(foreground: hex("#4EC9B0")),
            "escape": TokenStyle(foreground: hex("#D7BA7D")),
            "embedded": TokenStyle(foreground: hex("#D4D4D4"))
        ],
        diagnostics: DiagnosticColors(
            error: hex("#F14C4C"),
            warning: hex("#CCA700"),
            information: hex("#3794FF"),
            hint: hex("#A0A0A0")
        ),
        git: GitDecorationColors(
            added: hex("#587C0C"),
            modified: hex("#0C7D9D"),
            deleted: hex("#94151B"),
            conflict: hex("#C586C0")
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
            conflict: hex("#D18AFF")
        )
    )
}
