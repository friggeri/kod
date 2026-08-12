import Foundation

/// The overall light/dark/high-contrast appearance a theme declares. Kod
/// uses this to decide `NSAppearance` matching and to pick a default theme
/// per system appearance.
public enum ThemeAppearance: String, Codable, Equatable, Sendable, CaseIterable {
    case light
    case dark
    case highContrastLight
    case highContrastDark

    public var isDark: Bool {
        self == .dark || self == .highContrastDark
    }

    public var isHighContrast: Bool {
        self == .highContrastLight || self == .highContrastDark
    }
}

/// Font traits attached to a token style, independent of family/size (which
/// come from `FontCore` settings).
public struct TokenStyle: Codable, Equatable, Sendable {
    public var foreground: ThemeColor?
    public var background: ThemeColor?
    public var isBold: Bool
    public var isItalic: Bool
    public var isUnderlined: Bool
    public var isStrikethrough: Bool

    public init(
        foreground: ThemeColor? = nil,
        background: ThemeColor? = nil,
        isBold: Bool = false,
        isItalic: Bool = false,
        isUnderlined: Bool = false,
        isStrikethrough: Bool = false
    ) {
        self.foreground = foreground
        self.background = background
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderlined = isUnderlined
        self.isStrikethrough = isStrikethrough
    }

    /// Overlays `other`'s non-nil/true fields on top of `self`, used when
    /// falling back from a specific dotted capture name to a parent prefix
    /// (`keyword.conditional.ternary` -> `keyword.conditional` -> `keyword`).
    public func merging(fallback other: TokenStyle) -> TokenStyle {
        TokenStyle(
            foreground: foreground ?? other.foreground,
            background: background ?? other.background,
            isBold: isBold || other.isBold,
            isItalic: isItalic || other.isItalic,
            isUnderlined: isUnderlined || other.isUnderlined,
            isStrikethrough: isStrikethrough || other.isStrikethrough
        )
    }
}

/// Window chrome, sidebar, tabs, breadcrumbs, status bar, lists, borders,
/// and focus/selection colors, per SPEC ("Window, sidebar, tab, breadcrumb,
/// status, list, border, focus, and selection colors").
public struct SurfaceColors: Codable, Equatable, Sendable {
    public var windowBackground: ThemeColor
    public var sidebarBackground: ThemeColor
    public var sidebarForeground: ThemeColor
    public var tabActiveBackground: ThemeColor
    public var tabInactiveBackground: ThemeColor
    public var tabForeground: ThemeColor
    public var breadcrumbBackground: ThemeColor
    public var breadcrumbForeground: ThemeColor
    public var statusBarBackground: ThemeColor
    public var statusBarForeground: ThemeColor
    public var listActiveBackground: ThemeColor
    public var listHoverBackground: ThemeColor
    public var listForeground: ThemeColor
    public var border: ThemeColor
    public var focusBorder: ThemeColor
    public var selectionBackground: ThemeColor

    public init(
        windowBackground: ThemeColor,
        sidebarBackground: ThemeColor,
        sidebarForeground: ThemeColor,
        tabActiveBackground: ThemeColor,
        tabInactiveBackground: ThemeColor,
        tabForeground: ThemeColor,
        breadcrumbBackground: ThemeColor,
        breadcrumbForeground: ThemeColor,
        statusBarBackground: ThemeColor,
        statusBarForeground: ThemeColor,
        listActiveBackground: ThemeColor,
        listHoverBackground: ThemeColor,
        listForeground: ThemeColor,
        border: ThemeColor,
        focusBorder: ThemeColor,
        selectionBackground: ThemeColor
    ) {
        self.windowBackground = windowBackground
        self.sidebarBackground = sidebarBackground
        self.sidebarForeground = sidebarForeground
        self.tabActiveBackground = tabActiveBackground
        self.tabInactiveBackground = tabInactiveBackground
        self.tabForeground = tabForeground
        self.breadcrumbBackground = breadcrumbBackground
        self.breadcrumbForeground = breadcrumbForeground
        self.statusBarBackground = statusBarBackground
        self.statusBarForeground = statusBarForeground
        self.listActiveBackground = listActiveBackground
        self.listHoverBackground = listHoverBackground
        self.listForeground = listForeground
        self.border = border
        self.focusBorder = focusBorder
        self.selectionBackground = selectionBackground
    }
}

/// Base editor surface colors plus the decoration colors CodeViewport needs
/// for folding, indentation guides, bracket matching, and sticky headers.
public struct EditorColors: Codable, Equatable, Sendable {
    public var background: ThemeColor
    public var foreground: ThemeColor
    public var lineHighlightBackground: ThemeColor
    public var gutterForeground: ThemeColor
    public var indentGuideForeground: ThemeColor
    public var indentGuideActiveForeground: ThemeColor
    public var selectionBackground: ThemeColor
    public var matchingBracketBackground: ThemeColor
    public var stickyScopeBackground: ThemeColor
    public var foldedRegionForeground: ThemeColor

    public init(
        background: ThemeColor,
        foreground: ThemeColor,
        lineHighlightBackground: ThemeColor,
        gutterForeground: ThemeColor,
        indentGuideForeground: ThemeColor,
        indentGuideActiveForeground: ThemeColor,
        selectionBackground: ThemeColor,
        matchingBracketBackground: ThemeColor,
        stickyScopeBackground: ThemeColor,
        foldedRegionForeground: ThemeColor
    ) {
        self.background = background
        self.foreground = foreground
        self.lineHighlightBackground = lineHighlightBackground
        self.gutterForeground = gutterForeground
        self.indentGuideForeground = indentGuideForeground
        self.indentGuideActiveForeground = indentGuideActiveForeground
        self.selectionBackground = selectionBackground
        self.matchingBracketBackground = matchingBracketBackground
        self.stickyScopeBackground = stickyScopeBackground
        self.foldedRegionForeground = foldedRegionForeground
    }
}

public struct DiagnosticColors: Codable, Equatable, Sendable {
    public var error: ThemeColor
    public var warning: ThemeColor
    public var information: ThemeColor
    public var hint: ThemeColor

    public init(error: ThemeColor, warning: ThemeColor, information: ThemeColor, hint: ThemeColor) {
        self.error = error
        self.warning = warning
        self.information = information
        self.hint = hint
    }
}

public struct GitDecorationColors: Codable, Equatable, Sendable {
    public var added: ThemeColor
    public var modified: ThemeColor
    public var deleted: ThemeColor
    public var renamed: ThemeColor
    public var untracked: ThemeColor
    public var ignored: ThemeColor
    public var stagedModified: ThemeColor
    public var stagedDeleted: ThemeColor
    public var conflict: ThemeColor
    public var gutterAdded: ThemeColor
    public var gutterModified: ThemeColor
    public var gutterDeleted: ThemeColor
    public var insertedBackground: ThemeColor
    public var removedBackground: ThemeColor
    public var insertedTextBackground: ThemeColor
    public var removedTextBackground: ThemeColor

    /// Preserves source compatibility with Kod's original four-color public
    /// API. New roles inherit the same nearest legacy colors used when
    /// decoding older native and UserDefaults-persisted themes.
    public init(
        added: ThemeColor,
        modified: ThemeColor,
        deleted: ThemeColor,
        conflict: ThemeColor
    ) {
        self.init(
            added: added,
            modified: modified,
            deleted: deleted,
            renamed: modified,
            untracked: added,
            ignored: modified,
            stagedModified: modified,
            stagedDeleted: deleted,
            conflict: conflict
        )
    }

    public init(
        added: ThemeColor,
        modified: ThemeColor,
        deleted: ThemeColor,
        renamed: ThemeColor,
        untracked: ThemeColor,
        ignored: ThemeColor,
        stagedModified: ThemeColor,
        stagedDeleted: ThemeColor,
        conflict: ThemeColor
    ) {
        self.init(
            added: added,
            modified: modified,
            deleted: deleted,
            renamed: renamed,
            untracked: untracked,
            ignored: ignored,
            stagedModified: stagedModified,
            stagedDeleted: stagedDeleted,
            conflict: conflict,
            gutterAdded: added,
            gutterModified: modified,
            gutterDeleted: deleted,
            insertedBackground: Self.withAlpha(added, 41.0 / 255.0),
            removedBackground: Self.withAlpha(deleted, 41.0 / 255.0)
        )
    }

    public init(
        added: ThemeColor,
        modified: ThemeColor,
        deleted: ThemeColor,
        renamed: ThemeColor,
        untracked: ThemeColor,
        ignored: ThemeColor,
        stagedModified: ThemeColor,
        stagedDeleted: ThemeColor,
        conflict: ThemeColor,
        gutterAdded: ThemeColor,
        gutterModified: ThemeColor,
        gutterDeleted: ThemeColor,
        insertedBackground: ThemeColor,
        removedBackground: ThemeColor,
        insertedTextBackground: ThemeColor? = nil,
        removedTextBackground: ThemeColor? = nil
    ) {
        self.added = added
        self.modified = modified
        self.deleted = deleted
        self.renamed = renamed
        self.untracked = untracked
        self.ignored = ignored
        self.stagedModified = stagedModified
        self.stagedDeleted = stagedDeleted
        self.conflict = conflict
        self.gutterAdded = gutterAdded
        self.gutterModified = gutterModified
        self.gutterDeleted = gutterDeleted
        self.insertedBackground = insertedBackground
        self.removedBackground = removedBackground
        self.insertedTextBackground = insertedTextBackground
            ?? Self.withAlpha(added, 77.0 / 255.0)
        self.removedTextBackground = removedTextBackground
            ?? Self.withAlpha(deleted, 77.0 / 255.0)
    }

    private enum CodingKeys: String, CodingKey {
        case added
        case modified
        case deleted
        case renamed
        case untracked
        case ignored
        case stagedModified
        case stagedDeleted
        case conflict
        case gutterAdded
        case gutterModified
        case gutterDeleted
        case insertedBackground
        case removedBackground
        case insertedTextBackground
        case removedTextBackground
    }

    /// Themes persisted by older Kod builds contain only the original four
    /// Git colors. Missing roles inherit the closest legacy color so those
    /// themes remain usable instead of being quarantined as corrupt.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        added = try container.decode(ThemeColor.self, forKey: .added)
        modified = try container.decode(ThemeColor.self, forKey: .modified)
        deleted = try container.decode(ThemeColor.self, forKey: .deleted)
        conflict = try container.decode(ThemeColor.self, forKey: .conflict)
        renamed = try container.decodeIfPresent(ThemeColor.self, forKey: .renamed) ?? modified
        untracked = try container.decodeIfPresent(ThemeColor.self, forKey: .untracked) ?? added
        ignored = try container.decodeIfPresent(ThemeColor.self, forKey: .ignored) ?? modified
        stagedModified = try container.decodeIfPresent(ThemeColor.self, forKey: .stagedModified) ?? modified
        stagedDeleted = try container.decodeIfPresent(ThemeColor.self, forKey: .stagedDeleted) ?? deleted
        gutterAdded = try container.decodeIfPresent(ThemeColor.self, forKey: .gutterAdded) ?? added
        gutterModified = try container.decodeIfPresent(ThemeColor.self, forKey: .gutterModified) ?? modified
        gutterDeleted = try container.decodeIfPresent(ThemeColor.self, forKey: .gutterDeleted) ?? deleted
        insertedBackground = try container.decodeIfPresent(
            ThemeColor.self,
            forKey: .insertedBackground
        ) ?? Self.withAlpha(added, 41.0 / 255.0)
        removedBackground = try container.decodeIfPresent(
            ThemeColor.self,
            forKey: .removedBackground
        ) ?? Self.withAlpha(deleted, 41.0 / 255.0)
        insertedTextBackground = try container.decodeIfPresent(
            ThemeColor.self,
            forKey: .insertedTextBackground
        ) ?? Self.withAlpha(added, 77.0 / 255.0)
        removedTextBackground = try container.decodeIfPresent(
            ThemeColor.self,
            forKey: .removedTextBackground
        ) ?? Self.withAlpha(deleted, 77.0 / 255.0)
    }

    private static func withAlpha(_ color: ThemeColor, _ alpha: Double) -> ThemeColor {
        ThemeColor(red: color.red, green: color.green, blue: color.blue, alpha: alpha)
    }
}

/// LSP semantic-token type/modifier rules, keyed by a canonical string of
/// `"type"` or `"type.modifier1.modifier2"` with modifiers sorted
/// lexicographically so lookups are order-independent. Prepared for the
/// language-server semantic token layer; not yet fed by a live LSP
/// connection in this phase.
public struct SemanticTokenRules: Codable, Equatable, Sendable {
    public var rules: [String: TokenStyle]

    public init(rules: [String: TokenStyle] = [:]) {
        self.rules = rules
    }

    public static func key(type: String, modifiers: [String]) -> String {
        guard !modifiers.isEmpty else {
            return type
        }
        return ([type] + modifiers.sorted()).joined(separator: ".")
    }

    /// Looks up the most specific rule for `type`/`modifiers`, falling back
    /// from the full modifier set down to the bare type.
    public func style(type: String, modifiers: [String]) -> TokenStyle? {
        let sortedModifiers = modifiers.sorted()
        var candidateModifiers = sortedModifiers
        while true {
            let key = Self.key(type: type, modifiers: candidateModifiers)
            if let style = rules[key] {
                return style
            }
            guard !candidateModifiers.isEmpty else {
                break
            }
            candidateModifiers.removeLast()
        }
        return rules[type]
    }
}

/// The Kod-native, versioned theme schema described in SPEC 7.2: metadata
/// and schema version; light/dark/high-contrast appearance; window,
/// sidebar, tab, breadcrumb, status, list, border, focus, and selection
/// colors; editor base colors; Tree-sitter capture colors and font traits;
/// LSP semantic token type/modifier rules; and diagnostic/Git decoration
/// colors.
public struct KodTheme: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var identifier: String
    public var name: String
    public var appearance: ThemeAppearance
    public var surface: SurfaceColors
    public var editor: EditorColors
    /// Keyed by Tree-sitter highlight capture name (e.g. `"keyword"`,
    /// `"function.method"`), matching the dotted, hierarchical capture
    /// names emitted by the bundled `highlights.scm` queries so a theme can
    /// style a broad category or a specific subcategory.
    public var syntax: [String: TokenStyle]
    public var semanticTokens: SemanticTokenRules
    public var diagnostics: DiagnosticColors
    public var git: GitDecorationColors

    public init(
        schemaVersion: Int = KodTheme.currentSchemaVersion,
        identifier: String,
        name: String,
        appearance: ThemeAppearance,
        surface: SurfaceColors,
        editor: EditorColors,
        syntax: [String: TokenStyle],
        semanticTokens: SemanticTokenRules = SemanticTokenRules(),
        diagnostics: DiagnosticColors,
        git: GitDecorationColors
    ) {
        self.schemaVersion = schemaVersion
        self.identifier = identifier
        self.name = name
        self.appearance = appearance
        self.surface = surface
        self.editor = editor
        self.syntax = syntax
        self.semanticTokens = semanticTokens
        self.diagnostics = diagnostics
        self.git = git
    }

    /// Resolves the style for a Tree-sitter capture name by walking up its
    /// dotted path (`"keyword.conditional.ternary"` ->
    /// `"keyword.conditional"` -> `"keyword"`) and merging each more general
    /// ancestor in as a fallback for fields the most specific entry left
    /// unset, ending at the bare editor foreground color.
    public func lexicalStyle(forCapture captureName: String) -> TokenStyle {
        var components = captureName.split(separator: ".").map(String.init)
        var resolved = TokenStyle()
        var foundAny = false

        while !components.isEmpty {
            let key = components.joined(separator: ".")
            if let style = syntax[key] {
                resolved = foundAny ? resolved.merging(fallback: style) : style
                foundAny = true
            }
            components.removeLast()
        }

        if !foundAny {
            return TokenStyle(foreground: editor.foreground)
        }
        return resolved.foreground == nil
            ? resolved.merging(fallback: TokenStyle(foreground: editor.foreground))
            : resolved
    }

    /// Resolves the effective style for a token, applying the pipeline
    /// precedence from SPEC 7.1: an LSP semantic-token rule (when a
    /// semantic type is supplied) overrides the lexical Tree-sitter capture
    /// style, which itself falls back to the base editor foreground.
    public func resolvedTokenStyle(
        captureName: String?,
        semanticType: String? = nil,
        semanticModifiers: [String] = []
    ) -> TokenStyle {
        let lexical = captureName.map(lexicalStyle(forCapture:)) ?? TokenStyle(foreground: editor.foreground)
        guard let semanticType, let semanticStyle = semanticTokens.style(
            type: semanticType,
            modifiers: semanticModifiers
        ) else {
            return lexical
        }
        return semanticStyle.merging(fallback: lexical)
    }
}
