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
        XCTAssertEqual(theme.git.added, ThemeColor(hex: "#11AA11"))
        XCTAssertEqual(theme.git.modified, ThemeColor(hex: "#2266AA"))
        XCTAssertEqual(theme.git.deleted, ThemeColor(hex: "#CC2233"))
        XCTAssertEqual(theme.git.renamed, ThemeColor(hex: "#33AA77"))
        XCTAssertEqual(theme.git.untracked, ThemeColor(hex: "#44BB55"))
        XCTAssertEqual(theme.git.ignored, ThemeColor(hex: "#778899"))
        XCTAssertEqual(theme.git.stagedModified, ThemeColor(hex: "#DDAA55"))
        XCTAssertEqual(theme.git.stagedDeleted, ThemeColor(hex: "#EE6677"))
        XCTAssertEqual(theme.git.conflict, ThemeColor(hex: "#FF33AA"))
        XCTAssertEqual(theme.git.gutterAdded, ThemeColor(hex: "#12AB34"))
        XCTAssertEqual(theme.git.gutterModified, ThemeColor(hex: "#3456CD"))
        XCTAssertEqual(theme.git.gutterDeleted, ThemeColor(hex: "#DC3456"))
        XCTAssertEqual(theme.git.insertedBackground, ThemeColor(hex: "#12AB3433"))
        XCTAssertEqual(theme.git.removedBackground, ThemeColor(hex: "#DC345633"))
        XCTAssertEqual(theme.git.insertedTextBackground, ThemeColor(hex: "#12AB3466"))
        XCTAssertEqual(theme.git.removedTextBackground, ThemeColor(hex: "#DC345666"))

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

    func testImportMapsVSCodeMinimapColorRolesWithoutReportingThemUnsupported() throws {
        let json = """
        {
          "name": "Minimap",
          "type": "dark",
          "colors": {
            "minimap.background": "#101112",
            "minimap.foregroundOpacity": "#00000080",
            "minimap.selectionHighlight": "#223344",
            "minimap.findMatchHighlight": "#334455",
            "minimap.errorHighlight": "#AA1122",
            "minimap.warningHighlight": "#BB8833",
            "minimap.infoHighlight": "#3388CC",
            "minimapSlider.background": "#FFFFFF20",
            "minimapSlider.hoverBackground": "#FFFFFF30",
            "minimapSlider.activeBackground": "#FFFFFF40",
            "minimapGutter.addedBackground": "#22AA44",
            "minimapGutter.modifiedBackground": "#4488CC",
            "minimapGutter.deletedBackground": "#CC3344"
          }
        }
        """
        let (theme, report) = try VSCodeThemeImporter.import(
            jsonData: Data(json.utf8),
            identifier: "minimap"
        )

        XCTAssertEqual(theme.minimap.background, ThemeColor(hex: "#101112"))
        XCTAssertEqual(theme.minimap.foregroundOpacity, 128.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(theme.minimap.sliderActive, ThemeColor(hex: "#FFFFFF40"))
        XCTAssertEqual(theme.minimap.gutterModified, ThemeColor(hex: "#4488CC"))
        XCTAssertTrue(report.unmappedColorKeys.isEmpty)
    }
}
