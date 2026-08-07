import XCTest
@testable import ThemeCore

final class VSCodeThemeImportTests: XCTestCase {
    private func fixtureData() throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "sample-vscode-theme", withExtension: "json", subdirectory: "Fixtures")
        )
        return try Data(contentsOf: url)
    }

    func testImportMapsKnownColorsAndReportsUnsupportedOnes() throws {
        let (theme, report) = try VSCodeThemeImporter.import(
            jsonData: fixtureData(),
            identifier: "imported.sample"
        )

        XCTAssertEqual(theme.editor.background, ThemeColor(hex: "#101418"))
        XCTAssertEqual(theme.editor.foreground, ThemeColor(hex: "#E6E6E6"))
        XCTAssertEqual(theme.editor.gutterForeground, ThemeColor(hex: "#5C6773"))
        XCTAssertEqual(theme.surface.sidebarBackground, ThemeColor(hex: "#0B0E11"))
        XCTAssertEqual(theme.surface.statusBarBackground, ThemeColor(hex: "#123456"))
        XCTAssertEqual(theme.appearance, .dark)

        XCTAssertTrue(report.unmappedColorKeys.contains("editor.someTotallyMadeUpKey"))
        XCTAssertTrue(report.unsupportedTopLevelKeys.contains("someTopLevelKeyKodDoesNotUnderstand"))
        XCTAssertTrue(
            report.unsupportedTokenColorSettingsKeys.contains("tokenColors.settings.someUnsupportedTokenSetting")
        )
        XCTAssertTrue(
            report.unsupportedTokenColorSettingsKeys
                .contains("semanticTokenColors.class.someUnsupportedSemanticSetting")
        )
        XCTAssertFalse(report.isEmpty)
    }

    func testImportResolvesTokenColorsByScopeSpecificity() throws {
        let (theme, _) = try VSCodeThemeImporter.import(
            jsonData: fixtureData(),
            identifier: "imported.sample"
        )

        // "keyword.conditional" maps to representative scope
        // "keyword.control.conditional", which the fixture's token color
        // rule lists explicitly (alongside the less specific
        // "keyword.control"), so it must resolve to that rule's color.
        XCTAssertEqual(theme.syntax["keyword.conditional"]?.foreground, ThemeColor(hex: "#FF6AC1"))
        XCTAssertTrue(theme.syntax["keyword.conditional"]?.isBold == true)

        XCTAssertEqual(theme.syntax["comment"]?.foreground, ThemeColor(hex: "#5C7E10"))
        XCTAssertTrue(theme.syntax["comment"]?.isItalic == true)
        XCTAssertEqual(theme.syntax["string"]?.foreground, ThemeColor(hex: "#C3E88D"))
    }

    func testImportDecodesSemanticTokenRules() throws {
        let (theme, _) = try VSCodeThemeImporter.import(
            jsonData: fixtureData(),
            identifier: "imported.sample"
        )

        XCTAssertEqual(
            theme.semanticTokens.rules["variable.readonly"]?.foreground,
            ThemeColor(hex: "#82AAFF")
        )
        XCTAssertEqual(theme.semanticTokens.rules["class"]?.foreground, ThemeColor(hex: "#FFCB6B"))
        XCTAssertTrue(theme.semanticTokens.rules["class"]?.isBold == true)
    }

    func testImportRejectsInvalidJSON() {
        let invalidData = Data("not json at all".utf8)
        XCTAssertThrowsError(
            try VSCodeThemeImporter.import(jsonData: invalidData, identifier: "broken")
        ) { error in
            XCTAssertEqual(error as? VSCodeThemeImportError, .invalidJSON)
        }
    }

    func testImportRejectsNonObjectJSON() {
        let arrayData = Data("[1, 2, 3]".utf8)
        XCTAssertThrowsError(
            try VSCodeThemeImporter.import(jsonData: arrayData, identifier: "broken")
        ) { error in
            XCTAssertEqual(error as? VSCodeThemeImportError, .notAJSONObject)
        }
    }

    func testImportedThemeRoundTripsThroughKodNativeCodec() throws {
        let (theme, _) = try VSCodeThemeImporter.import(
            jsonData: fixtureData(),
            identifier: "imported.sample"
        )
        let data = try ThemeFileCodec.encode(theme)
        let decoded = try ThemeFileCodec.decode(data)
        XCTAssertEqual(decoded, theme)
    }
}
