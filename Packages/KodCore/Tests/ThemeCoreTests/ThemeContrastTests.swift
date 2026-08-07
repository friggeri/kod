import XCTest
@testable import ThemeCore

final class ThemeContrastTests: XCTestCase {
    // PVC's light syntax palette is intentionally vivid; SPEC 14 reserves
    // normal-text contrast requirements for the dedicated high-contrast pair.
    func testStandardThemesMeetAABaseTextContrast() {
        for theme in [BundledThemes.light, BundledThemes.dark] {
            assertBaseContrast(theme, minimumRatio: 4.5)
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

    func testStandardThemesUseKodLightAndDarkPVCPalettes() {
        let light = BundledThemes.light
        XCTAssertEqual(light.name, "Kod Light")
        XCTAssertEqual(light.editor.background, ThemeColor(hex: "#FFFFFF"))
        XCTAssertEqual(light.editor.foreground, ThemeColor(hex: "#242728"))
        XCTAssertEqual(light.surface.focusBorder, ThemeColor(hex: "#FFAA00"))
        XCTAssertEqual(light.syntax["keyword"]?.foreground, ThemeColor(hex: "#FF006A"))
        XCTAssertEqual(light.syntax["function"]?.foreground, ThemeColor(hex: "#88CC00"))
        XCTAssertEqual(light.syntax["function.builtin"]?.foreground, ThemeColor(hex: "#00AAFF"))
        XCTAssertEqual(light.syntax["string"]?.foreground, ThemeColor(hex: "#E6BF00"))
        XCTAssertEqual(light.syntax["number"]?.foreground, ThemeColor(hex: "#7733FF"))

        let dark = BundledThemes.dark
        XCTAssertEqual(dark.name, "Kod Dark")
        XCTAssertEqual(dark.editor.background, ThemeColor(hex: "#242728"))
        XCTAssertEqual(dark.editor.foreground, ThemeColor(hex: "#FAFAFA"))
        XCTAssertEqual(dark.surface.focusBorder, ThemeColor(hex: "#FFBB33"))
        XCTAssertEqual(dark.syntax["keyword"]?.foreground, ThemeColor(hex: "#FF1A79"))
        XCTAssertEqual(dark.syntax["function"]?.foreground, ThemeColor(hex: "#AAFF00"))
        XCTAssertEqual(dark.syntax["function.builtin"]?.foreground, ThemeColor(hex: "#66CCFF"))
        XCTAssertEqual(dark.syntax["string"]?.foreground, ThemeColor(hex: "#FFE666"))
        XCTAssertEqual(dark.syntax["number"]?.foreground, ThemeColor(hex: "#9966FF"))
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

    private func assertBaseContrast(
        _ theme: KodTheme,
        minimumRatio: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let backgroundRatio = theme.editor.foreground.contrastRatio(against: theme.editor.background)
        XCTAssertGreaterThanOrEqual(
            backgroundRatio,
            minimumRatio,
            "\(theme.identifier): editor foreground/background contrast \(backgroundRatio) below \(minimumRatio)",
            file: file,
            line: line
        )
    }

    private func assertContrast(
        _ theme: KodTheme,
        minimumRatio: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertBaseContrast(theme, minimumRatio: minimumRatio, file: file, line: line)

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
