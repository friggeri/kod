import XCTest
@testable import ThemeCore

final class ThemeContrastTests: XCTestCase {
    func testStandardThemesMeetAANormalTextContrast() {
        for theme in [BundledThemes.light, BundledThemes.dark] {
            assertContrast(theme, minimumRatio: 4.5)
        }
    }

    func testHighContrastThemesMeetEnhancedContrast() {
        for theme in [BundledThemes.highContrastLight, BundledThemes.highContrastDark] {
            assertContrast(theme, minimumRatio: 7.0)
        }
    }

    func testAllBundledThemesAreDistinctAndCoverAllAppearances() {
        let appearances = Set(BundledThemes.all.map(\.appearance))
        XCTAssertEqual(appearances, Set(ThemeAppearance.allCases))

        let identifiers = Set(BundledThemes.all.map(\.identifier))
        XCTAssertEqual(identifiers.count, BundledThemes.all.count, "theme identifiers must be unique")
    }

    func testDefaultThemeSelection() {
        XCTAssertEqual(
            BundledThemes.defaultTheme(isDark: false, isHighContrast: false).identifier,
            BundledThemes.light.identifier
        )
        XCTAssertEqual(
            BundledThemes.defaultTheme(isDark: true, isHighContrast: false).identifier,
            BundledThemes.dark.identifier
        )
        XCTAssertEqual(
            BundledThemes.defaultTheme(isDark: false, isHighContrast: true).identifier,
            BundledThemes.highContrastLight.identifier
        )
        XCTAssertEqual(
            BundledThemes.defaultTheme(isDark: true, isHighContrast: true).identifier,
            BundledThemes.highContrastDark.identifier
        )
    }

    /// System-accent independence (SPEC 14): every bundled theme's own
    /// selection/focus highlight is a real, theme-defined color (never
    /// fully transparent/absent), and `ThemeColor` — the only type these
    /// colors are expressed in — is declared in `ThemeCore` with no
    /// `AppKit`/`NSColor` dependency at all (confirmed by this target
    /// building and running `import Foundation`-only; see
    /// `ThemeColor.swift`), so a theme's selection color can never
    /// silently be "whatever `NSColor.controlAccentColor` is right now"
    /// — a system accent-color change cannot clash with or override a
    /// bundled theme's own chosen highlight. Live-UI chrome that *should*
    /// track the system accent (e.g. the active-editor-group header
    /// tint in `EditorGroupViewController`) uses
    /// `NSColor.controlAccentColor` directly instead of a theme color,
    /// so the two concerns stay cleanly separated.
    func testBundledThemeSelectionColorsAreFixedThemeDataNotLiveSystemAccent() {
        for theme in BundledThemes.all {
            XCTAssertGreaterThan(
                theme.editor.selectionBackground.alpha,
                0,
                "\(theme.identifier): selectionBackground must be a real, visible theme-defined color"
            )
            XCTAssertGreaterThan(
                theme.surface.selectionBackground.alpha,
                0,
                "\(theme.identifier): surface selectionBackground must be a real, visible theme-defined color"
            )
        }
    }

    private func assertContrast(_ theme: KodTheme, minimumRatio: Double, file: StaticString = #filePath, line: UInt = #line) {
        let backgroundRatio = theme.editor.foreground.contrastRatio(against: theme.editor.background)
        XCTAssertGreaterThanOrEqual(
            backgroundRatio,
            minimumRatio,
            "\(theme.identifier): editor foreground/background contrast \(backgroundRatio) below \(minimumRatio)",
            file: file,
            line: line
        )

        for (captureName, style) in theme.syntax {
            guard let foreground = style.foreground else {
                continue
            }
            let ratio = foreground.contrastRatio(against: theme.editor.background)
            XCTAssertGreaterThanOrEqual(
                ratio,
                minimumRatio,
                "\(theme.identifier): syntax token \"\(captureName)\" contrast \(ratio) below \(minimumRatio)",
                file: file,
                line: line
            )
        }
    }
}
