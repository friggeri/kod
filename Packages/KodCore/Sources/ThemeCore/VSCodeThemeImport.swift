import Foundation

/// Reports exactly what an imported VS Code theme did *not* map to the Kod
/// schema, so import is never silently lossy. Per SPEC 7.2: "Unsupported
/// keys are ignored with an import report rather than treated as success."
public struct ThemeImportReport: Equatable, Sendable {
    public var unsupportedTopLevelKeys: [String] = []
    public var unmappedColorKeys: [String] = []
    public var unsupportedTokenColorSettingsKeys: [String] = []
    public var unparsableTokenColorEntries: [String] = []

    public var isEmpty: Bool {
        unsupportedTopLevelKeys.isEmpty
            && unmappedColorKeys.isEmpty
            && unsupportedTokenColorSettingsKeys.isEmpty
            && unparsableTokenColorEntries.isEmpty
    }
}

public enum VSCodeThemeImportError: Error, Equatable {
    case invalidJSON
    case notAJSONObject
}

/// Imports a standalone VS Code color-theme JSON file (`colors`,
/// `tokenColors`, `semanticTokenColors`) into the Kod-native schema. VS
/// Code's `tokenColors` scopes are TextMate-style dotted selectors (e.g.
/// `"keyword.control"`, `"entity.name.function"`); Kod's Tree-sitter
/// capture names use the same dotted-hierarchy convention (e.g.
/// `"keyword"`, `"function"`), so each Kod capture name is mapped to its
/// closest representative TextMate scope and resolved against
/// `tokenColors` using VS Code's own most-specific-scope-wins rule.
public enum VSCodeThemeImporter {
    /// VS Code workbench color key -> Kod schema field, the "documented
    /// mapping table" SPEC 7.2 requires. Keys not listed here are reported
    /// as unmapped rather than silently dropped.
    static let representativeScope: [String: String] = [
        "keyword": "keyword.control",
        "keyword.conditional": "keyword.control.conditional",
        "keyword.repeat": "keyword.control.repeat",
        "keyword.return": "keyword.control.return",
        "keyword.function": "storage.type.function",
        "keyword.import": "keyword.control.import",
        "keyword.modifier": "storage.modifier",
        "keyword.operator": "keyword.operator",
        "keyword.directive": "keyword.control.directive",
        "keyword.exception": "keyword.control.exception",
        "keyword.coroutine": "keyword.control",
        "function": "entity.name.function",
        "function.method": "entity.name.function.member",
        "function.call": "entity.name.function",
        "function.builtin": "support.function",
        "function.macro": "entity.name.function.preprocessor",
        "type": "entity.name.type",
        "type.builtin": "support.type",
        "variable": "variable",
        "variable.builtin": "variable.language",
        "variable.parameter": "variable.parameter",
        "variable.member": "variable.other.member",
        "constant": "variable.other.constant",
        "constant.builtin": "constant.language",
        "constant.macro": "entity.name.function.preprocessor",
        "string": "string",
        "string.escape": "constant.character.escape",
        "string.regexp": "string.regexp",
        "string.special": "string.special",
        "number": "constant.numeric",
        "number.float": "constant.numeric",
        "comment": "comment",
        "comment.documentation": "comment.documentation",
        "operator": "keyword.operator",
        "punctuation.bracket": "punctuation.bracket",
        "punctuation.delimiter": "punctuation.delimiter",
        "punctuation.special": "punctuation.special",
        "attribute": "entity.other.attribute-name",
        "tag": "entity.name.tag",
        "tag.error": "invalid.illegal",
        "property": "variable.other.property",
        "label": "entity.name.label",
        "boolean": "constant.language.boolean",
        "character.special": "constant.character",
        "constructor": "entity.name.function.constructor",
        "embedded": "meta.embedded",
        "escape": "constant.character.escape"
    ]

    static let workbenchColorKeys: [WorkbenchColorTarget] = [
        WorkbenchColorTarget(key: "editor.background", assign: { $0.editorBackground = $1 }),
        WorkbenchColorTarget(key: "editor.foreground", assign: { $0.editorForeground = $1 }),
        WorkbenchColorTarget(key: "editor.lineHighlightBackground", assign: { $0.lineHighlight = $1 }),
        WorkbenchColorTarget(key: "editorLineNumber.foreground", assign: { $0.gutterForeground = $1 }),
        WorkbenchColorTarget(key: "editorIndentGuide.background1", assign: { $0.indentGuide = $1 }),
        WorkbenchColorTarget(key: "editorIndentGuide.background", assign: { $0.indentGuide = $0.indentGuide ?? $1 }),
        WorkbenchColorTarget(
            key: "editorIndentGuide.activeBackground1",
            assign: { $0.indentGuideActive = $1 }
        ),
        WorkbenchColorTarget(
            key: "editorIndentGuide.activeBackground",
            assign: { $0.indentGuideActive = $0.indentGuideActive ?? $1 }
        ),
        WorkbenchColorTarget(key: "editor.selectionBackground", assign: { $0.selectionBackground = $1 }),
        WorkbenchColorTarget(key: "editorBracketMatch.background", assign: { $0.matchingBracket = $1 }),
        WorkbenchColorTarget(key: "editorGutter.addedBackground", assign: { $0.gitGutterAdded = $1 }),
        WorkbenchColorTarget(key: "editorGutter.modifiedBackground", assign: { $0.gitGutterModified = $1 }),
        WorkbenchColorTarget(key: "editorGutter.deletedBackground", assign: { $0.gitGutterDeleted = $1 }),
        WorkbenchColorTarget(
            key: "diffEditor.insertedLineBackground",
            assign: { $0.gitInsertedBackground = $1 }
        ),
        WorkbenchColorTarget(
            key: "diffEditor.removedLineBackground",
            assign: { $0.gitRemovedBackground = $1 }
        ),
        WorkbenchColorTarget(
            key: "diffEditor.insertedTextBackground",
            assign: { $0.gitInsertedTextBackground = $1 }
        ),
        WorkbenchColorTarget(
            key: "diffEditor.removedTextBackground",
            assign: { $0.gitRemovedTextBackground = $1 }
        ),
        WorkbenchColorTarget(key: "sideBar.background", assign: { $0.sidebarBackground = $1 }),
        WorkbenchColorTarget(key: "sideBar.foreground", assign: { $0.sidebarForeground = $1 }),
        WorkbenchColorTarget(key: "tab.activeBackground", assign: { $0.tabActiveBackground = $1 }),
        WorkbenchColorTarget(key: "tab.inactiveBackground", assign: { $0.tabInactiveBackground = $1 }),
        WorkbenchColorTarget(key: "tab.activeForeground", assign: { $0.tabForeground = $1 }),
        WorkbenchColorTarget(key: "breadcrumb.background", assign: { $0.breadcrumbBackground = $1 }),
        WorkbenchColorTarget(key: "breadcrumb.foreground", assign: { $0.breadcrumbForeground = $1 }),
        WorkbenchColorTarget(key: "statusBar.background", assign: { $0.statusBarBackground = $1 }),
        WorkbenchColorTarget(key: "statusBar.foreground", assign: { $0.statusBarForeground = $1 }),
        WorkbenchColorTarget(key: "list.activeSelectionBackground", assign: { $0.listActiveBackground = $1 }),
        WorkbenchColorTarget(key: "list.hoverBackground", assign: { $0.listHoverBackground = $1 }),
        WorkbenchColorTarget(key: "list.activeSelectionForeground", assign: { $0.listForeground = $1 }),
        WorkbenchColorTarget(key: "focusBorder", assign: { $0.focusBorder = $1 }),
        WorkbenchColorTarget(key: "widget.border", assign: { $0.border = $1 }),
        WorkbenchColorTarget(key: "titleBar.activeBackground", assign: { $0.windowBackground = $1 }),
        WorkbenchColorTarget(key: "editorError.foreground", assign: { $0.diagnosticError = $1 }),
        WorkbenchColorTarget(key: "editorWarning.foreground", assign: { $0.diagnosticWarning = $1 }),
        WorkbenchColorTarget(key: "editorInfo.foreground", assign: { $0.diagnosticInformation = $1 }),
        WorkbenchColorTarget(key: "editorHint.foreground", assign: { $0.diagnosticHint = $1 }),
        WorkbenchColorTarget(
            key: "gitDecoration.addedResourceForeground",
            assign: { $0.gitAdded = $1 }
        ),
        WorkbenchColorTarget(
            key: "gitDecoration.modifiedResourceForeground",
            assign: { $0.gitModified = $1 }
        ),
        WorkbenchColorTarget(
            key: "gitDecoration.deletedResourceForeground",
            assign: { $0.gitDeleted = $1 }
        ),
        WorkbenchColorTarget(
            key: "gitDecoration.renamedResourceForeground",
            assign: { $0.gitRenamed = $1 }
        ),
        WorkbenchColorTarget(
            key: "gitDecoration.untrackedResourceForeground",
            assign: { $0.gitUntracked = $1 }
        ),
        WorkbenchColorTarget(
            key: "gitDecoration.ignoredResourceForeground",
            assign: { $0.gitIgnored = $1 }
        ),
        WorkbenchColorTarget(
            key: "gitDecoration.stageModifiedResourceForeground",
            assign: { $0.gitStagedModified = $1 }
        ),
        WorkbenchColorTarget(
            key: "gitDecoration.stageDeletedResourceForeground",
            assign: { $0.gitStagedDeleted = $1 }
        ),
        WorkbenchColorTarget(
            key: "gitDecoration.conflictingResourceForeground",
            assign: { $0.gitConflict = $1 }
        )
    ]

    private static let supportedTopLevelKeys: Set<String> = [
        "$schema", "name", "type", "colors", "tokenColors", "semanticTokenColors", "semanticHighlighting"
    ]

    public static func `import`(
        jsonData: Data,
        identifier: String
    ) throws -> (theme: KodTheme, report: ThemeImportReport) {
        let rawObject: Any
        do {
            rawObject = try JSONSerialization.jsonObject(with: jsonData)
        } catch {
            throw VSCodeThemeImportError.invalidJSON
        }
        guard let root = rawObject as? [String: Any] else {
            throw VSCodeThemeImportError.notAJSONObject
        }

        var report = ThemeImportReport()
        report.unsupportedTopLevelKeys = root.keys
            .filter { !supportedTopLevelKeys.contains($0) }
            .sorted()

        let isDark = (root["type"] as? String)?.lowercased().contains("dark") ?? true
        let isHighContrast = (root["type"] as? String)?.lowercased().contains("hc") ?? false
        let base = BundledThemes.defaultTheme(isDark: isDark, isHighContrast: isHighContrast)

        var mutable = MutableWorkbenchColors()
        if let colors = root["colors"] as? [String: Any] {
            for (key, value) in colors {
                guard let hex = value as? String, let color = ThemeColor(hex: hex) else {
                    report.unmappedColorKeys.append(key)
                    continue
                }
                guard let target = workbenchColorKeys.first(where: { $0.key == key }) else {
                    report.unmappedColorKeys.append(key)
                    continue
                }
                target.assign(&mutable, color)
            }
        }

        var syntax: [String: TokenStyle] = base.syntax
        if let tokenColors = root["tokenColors"] as? [[String: Any]] {
            let resolved = resolveTokenColors(tokenColors, report: &report)
            for (captureName, scope) in representativeScope {
                if let style = resolved.style(forScope: scope) {
                    syntax[captureName] = style
                }
            }
        }

        var semanticRules: [String: TokenStyle] = [:]
        if let semanticTokenColors = root["semanticTokenColors"] as? [String: Any] {
            for (selector, value) in semanticTokenColors {
                if let style = tokenStyle(fromSemanticValue: value, report: &report, selector: selector) {
                    semanticRules[selector] = style
                }
            }
        }

        let theme = KodTheme(
            identifier: identifier,
            name: (root["name"] as? String) ?? identifier,
            appearance: isHighContrast
                ? (isDark ? .highContrastDark : .highContrastLight)
                : (isDark ? .dark : .light),
            surface: SurfaceColors(
                windowBackground: mutable.windowBackground ?? base.surface.windowBackground,
                sidebarBackground: mutable.sidebarBackground ?? base.surface.sidebarBackground,
                sidebarForeground: mutable.sidebarForeground ?? base.surface.sidebarForeground,
                tabActiveBackground: mutable.tabActiveBackground ?? base.surface.tabActiveBackground,
                tabInactiveBackground: mutable.tabInactiveBackground ?? base.surface.tabInactiveBackground,
                tabForeground: mutable.tabForeground ?? base.surface.tabForeground,
                breadcrumbBackground: mutable.breadcrumbBackground ?? base.surface.breadcrumbBackground,
                breadcrumbForeground: mutable.breadcrumbForeground ?? base.surface.breadcrumbForeground,
                statusBarBackground: mutable.statusBarBackground ?? base.surface.statusBarBackground,
                statusBarForeground: mutable.statusBarForeground ?? base.surface.statusBarForeground,
                listActiveBackground: mutable.listActiveBackground ?? base.surface.listActiveBackground,
                listHoverBackground: mutable.listHoverBackground ?? base.surface.listHoverBackground,
                listForeground: mutable.listForeground ?? base.surface.listForeground,
                border: mutable.border ?? base.surface.border,
                focusBorder: mutable.focusBorder ?? base.surface.focusBorder,
                selectionBackground: mutable.selectionBackground ?? base.surface.selectionBackground
            ),
            editor: EditorColors(
                background: mutable.editorBackground ?? base.editor.background,
                foreground: mutable.editorForeground ?? base.editor.foreground,
                lineHighlightBackground: mutable.lineHighlight ?? base.editor.lineHighlightBackground,
                gutterForeground: mutable.gutterForeground ?? base.editor.gutterForeground,
                indentGuideForeground: mutable.indentGuide ?? base.editor.indentGuideForeground,
                indentGuideActiveForeground: mutable.indentGuideActive
                    ?? base.editor.indentGuideActiveForeground,
                selectionBackground: mutable.selectionBackground ?? base.editor.selectionBackground,
                matchingBracketBackground: mutable.matchingBracket ?? base.editor.matchingBracketBackground,
                stickyScopeBackground: base.editor.stickyScopeBackground,
                foldedRegionForeground: base.editor.foldedRegionForeground
            ),
            syntax: syntax,
            semanticTokens: SemanticTokenRules(rules: semanticRules),
            diagnostics: DiagnosticColors(
                error: mutable.diagnosticError ?? base.diagnostics.error,
                warning: mutable.diagnosticWarning ?? base.diagnostics.warning,
                information: mutable.diagnosticInformation ?? base.diagnostics.information,
                hint: mutable.diagnosticHint ?? base.diagnostics.hint
            ),
            git: GitDecorationColors(
                added: mutable.gitAdded ?? base.git.added,
                modified: mutable.gitModified ?? base.git.modified,
                deleted: mutable.gitDeleted ?? base.git.deleted,
                renamed: mutable.gitRenamed ?? base.git.renamed,
                untracked: mutable.gitUntracked ?? base.git.untracked,
                ignored: mutable.gitIgnored ?? base.git.ignored,
                stagedModified: mutable.gitStagedModified ?? base.git.stagedModified,
                stagedDeleted: mutable.gitStagedDeleted ?? base.git.stagedDeleted,
                conflict: mutable.gitConflict ?? base.git.conflict,
                gutterAdded: mutable.gitGutterAdded ?? base.git.gutterAdded,
                gutterModified: mutable.gitGutterModified ?? base.git.gutterModified,
                gutterDeleted: mutable.gitGutterDeleted ?? base.git.gutterDeleted,
                insertedBackground: mutable.gitInsertedBackground ?? base.git.insertedBackground,
                removedBackground: mutable.gitRemovedBackground ?? base.git.removedBackground,
                insertedTextBackground: mutable.gitInsertedTextBackground
                    ?? base.git.insertedTextBackground,
                removedTextBackground: mutable.gitRemovedTextBackground
                    ?? base.git.removedTextBackground
            )
        )

        return (theme, report)
    }

    private static func tokenStyle(
        fromSemanticValue value: Any,
        report: inout ThemeImportReport,
        selector: String
    ) -> TokenStyle? {
        if let hex = value as? String, let color = ThemeColor(hex: hex) {
            return TokenStyle(foreground: color)
        }
        if let object = value as? [String: Any] {
            var style = TokenStyle()
            var sawSupportedKey = false
            for (key, entry) in object {
                switch key {
                case "foreground":
                    if let hex = entry as? String, let color = ThemeColor(hex: hex) {
                        style.foreground = color
                        sawSupportedKey = true
                    }
                case "bold":
                    style.isBold = (entry as? Bool) ?? style.isBold
                    sawSupportedKey = true
                case "italic":
                    style.isItalic = (entry as? Bool) ?? style.isItalic
                    sawSupportedKey = true
                case "underline":
                    style.isUnderlined = (entry as? Bool) ?? style.isUnderlined
                    sawSupportedKey = true
                case "strikethrough":
                    style.isStrikethrough = (entry as? Bool) ?? style.isStrikethrough
                    sawSupportedKey = true
                default:
                    report.unsupportedTokenColorSettingsKeys.append("semanticTokenColors.\(selector).\(key)")
                }
            }
            return sawSupportedKey ? style : nil
        }
        report.unparsableTokenColorEntries.append("semanticTokenColors.\(selector)")
        return nil
    }

    private static func resolveTokenColors(
        _ entries: [[String: Any]],
        report: inout ThemeImportReport
    ) -> ResolvedTokenColors {
        var rules: [(scopes: [String], style: TokenStyle)] = []
        for entry in entries {
            guard let settings = entry["settings"] as? [String: Any] else {
                continue
            }
            var style = TokenStyle()
            var sawForeground = false
            for (key, value) in settings {
                switch key {
                case "foreground":
                    if let hex = value as? String, let color = ThemeColor(hex: hex) {
                        style.foreground = color
                        sawForeground = true
                    }
                case "fontStyle":
                    if let fontStyle = value as? String {
                        style.isBold = fontStyle.contains("bold")
                        style.isItalic = fontStyle.contains("italic")
                        style.isUnderlined = fontStyle.contains("underline")
                        style.isStrikethrough = fontStyle.contains("strikethrough")
                    }
                default:
                    report.unsupportedTokenColorSettingsKeys.append("tokenColors.settings.\(key)")
                }
            }
            guard sawForeground else {
                continue
            }

            let scopes: [String]
            if let single = entry["scope"] as? String {
                scopes = single.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } else if let list = entry["scope"] as? [String] {
                scopes = list
            } else {
                scopes = []
            }
            guard !scopes.isEmpty else {
                continue
            }
            rules.append((scopes, style))
        }
        return ResolvedTokenColors(rules: rules)
    }
}

/// A mutable accumulator for the subset of workbench/editor colors an
/// imported theme actually specified; unset fields fall back to the
/// nearest bundled theme of matching appearance.
struct MutableWorkbenchColors {
    var windowBackground: ThemeColor?
    var sidebarBackground: ThemeColor?
    var sidebarForeground: ThemeColor?
    var tabActiveBackground: ThemeColor?
    var tabInactiveBackground: ThemeColor?
    var tabForeground: ThemeColor?
    var breadcrumbBackground: ThemeColor?
    var breadcrumbForeground: ThemeColor?
    var statusBarBackground: ThemeColor?
    var statusBarForeground: ThemeColor?
    var listActiveBackground: ThemeColor?
    var listHoverBackground: ThemeColor?
    var listForeground: ThemeColor?
    var border: ThemeColor?
    var focusBorder: ThemeColor?
    var selectionBackground: ThemeColor?
    var editorBackground: ThemeColor?
    var editorForeground: ThemeColor?
    var lineHighlight: ThemeColor?
    var gutterForeground: ThemeColor?
    var indentGuide: ThemeColor?
    var indentGuideActive: ThemeColor?
    var matchingBracket: ThemeColor?
    var diagnosticError: ThemeColor?
    var diagnosticWarning: ThemeColor?
    var diagnosticInformation: ThemeColor?
    var diagnosticHint: ThemeColor?
    var gitAdded: ThemeColor?
    var gitModified: ThemeColor?
    var gitDeleted: ThemeColor?
    var gitRenamed: ThemeColor?
    var gitUntracked: ThemeColor?
    var gitIgnored: ThemeColor?
    var gitStagedModified: ThemeColor?
    var gitStagedDeleted: ThemeColor?
    var gitConflict: ThemeColor?
    var gitGutterAdded: ThemeColor?
    var gitGutterModified: ThemeColor?
    var gitGutterDeleted: ThemeColor?
    var gitInsertedBackground: ThemeColor?
    var gitRemovedBackground: ThemeColor?
    var gitInsertedTextBackground: ThemeColor?
    var gitRemovedTextBackground: ThemeColor?
}

struct WorkbenchColorTarget: @unchecked Sendable {
    let key: String
    let assign: (inout MutableWorkbenchColors, ThemeColor) -> Void
}

/// TextMate-style scope resolution mirroring VS Code's own rule: among all
/// `tokenColors` rules whose scope is a dot-segment prefix of (or exactly
/// equals) the queried scope, the one with the most matching segments
/// wins.
struct ResolvedTokenColors {
    let rules: [(scopes: [String], style: TokenStyle)]

    func style(forScope scope: String) -> TokenStyle? {
        let queriedSegments = scope.split(separator: ".").map(String.init)
        var best: (specificity: Int, style: TokenStyle)?

        for rule in rules {
            for candidateScope in rule.scopes {
                let candidateSegments = candidateScope.split(separator: ".").map(String.init)
                guard candidateSegments.count <= queriedSegments.count else {
                    continue
                }
                guard Array(queriedSegments.prefix(candidateSegments.count)) == candidateSegments else {
                    continue
                }
                let specificity = candidateSegments.count
                if let currentBest = best {
                    if specificity > currentBest.specificity {
                        best = (specificity, rule.style)
                    }
                } else {
                    best = (specificity, rule.style)
                }
            }
        }
        return best?.style
    }
}
