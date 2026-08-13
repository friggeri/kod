import XCTest
@testable import ThemeCore

final class ThemeSchemaTests: XCTestCase {
    func testRoundTripEncodeDecode() throws {
        let original = BundledThemes.dark
        let data = try ThemeFileCodec.encode(original)
        let decoded = try ThemeFileCodec.decode(data)
        XCTAssertEqual(decoded, original)
    }

    func testDecodingRejectsNewerUnsupportedSchemaVersion() throws {
        let data = try ThemeFileCodec.encode(BundledThemes.light)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["schemaVersion"] = KodTheme.currentSchemaVersion + 1
        let futureData = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try ThemeFileCodec.decode(futureData)) { error in
            guard case ThemeSchemaMigrationError.newerThanSupported(let fileVersion, let supportedVersion) = error else {
                return XCTFail("expected newerThanSupported, got \(error)")
            }
            XCTAssertEqual(fileVersion, KodTheme.currentSchemaVersion + 1)
            XCTAssertEqual(supportedVersion, KodTheme.currentSchemaVersion)
        }
    }

    func testDecodingMigratesOlderSchemaVersionForward() throws {
        let data = try ThemeFileCodec.encode(BundledThemes.light)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["schemaVersion"] = 0
        let olderData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try ThemeFileCodec.decode(olderData)
        XCTAssertEqual(decoded.schemaVersion, KodTheme.currentSchemaVersion)
        XCTAssertEqual(decoded.identifier, BundledThemes.light.identifier)
    }

    func testDecodingLegacyGitColorsSuppliesBackwardCompatibleRoles() throws {
        let data = try ThemeFileCodec.encode(BundledThemes.dark)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var git = try XCTUnwrap(object["git"] as? [String: Any])
        [
            "renamed", "untracked", "ignored", "stagedModified", "stagedDeleted",
            "gutterAdded", "gutterModified", "gutterDeleted",
            "insertedBackground", "removedBackground",
            "insertedTextBackground", "removedTextBackground"
        ].forEach {
            git.removeValue(forKey: $0)
        }

        object["git"] = git

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try ThemeFileCodec.decode(legacyData)

        XCTAssertEqual(decoded.git.renamed, decoded.git.modified)
        XCTAssertEqual(decoded.git.untracked, decoded.git.added)
        XCTAssertEqual(decoded.git.ignored, decoded.git.modified)
        XCTAssertEqual(decoded.git.stagedModified, decoded.git.modified)
        XCTAssertEqual(decoded.git.stagedDeleted, decoded.git.deleted)
        XCTAssertEqual(decoded.git.gutterAdded, decoded.git.added)
        XCTAssertEqual(decoded.git.gutterModified, decoded.git.modified)
        XCTAssertEqual(decoded.git.gutterDeleted, decoded.git.deleted)
        XCTAssertEqual(decoded.git.insertedBackground.alpha, 0.16, accuracy: 0.001)
        XCTAssertEqual(decoded.git.removedBackground.alpha, 0.16, accuracy: 0.001)
        XCTAssertEqual(decoded.git.insertedTextBackground.alpha, 77.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(decoded.git.removedTextBackground.alpha, 77.0 / 255.0, accuracy: 0.001)
    }

    func testDecodingLegacyThemeWithoutMinimapDerivesReadableDefaults() throws {
        let data = try ThemeFileCodec.encode(BundledThemes.highContrastDark)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "minimap")

        let decoded = try ThemeFileCodec.decode(
            JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.minimap.background, decoded.editor.background)
        XCTAssertEqual(decoded.minimap.error, decoded.diagnostics.error)
        XCTAssertEqual(decoded.minimap.gutterAdded, decoded.git.gutterAdded)
        XCTAssertGreaterThan(
            decoded.minimap.sliderActive.contrastRatio(against: decoded.minimap.background),
            1
        )
    }

    func testLegacyGitColorInitializerSuppliesBackwardCompatibleRoles() throws {
        let added = try XCTUnwrap(ThemeColor(hex: "#112233"))
        let modified = try XCTUnwrap(ThemeColor(hex: "#445566"))
        let deleted = try XCTUnwrap(ThemeColor(hex: "#778899"))
        let conflict = try XCTUnwrap(ThemeColor(hex: "#AABBCC"))

        let colors = GitDecorationColors(
            added: added,
            modified: modified,
            deleted: deleted,
            conflict: conflict
        )

        XCTAssertEqual(colors.added, added)
        XCTAssertEqual(colors.modified, modified)
        XCTAssertEqual(colors.deleted, deleted)
        XCTAssertEqual(colors.conflict, conflict)
        XCTAssertEqual(colors.renamed, modified)
        XCTAssertEqual(colors.untracked, added)
        XCTAssertEqual(colors.ignored, modified)
        XCTAssertEqual(colors.stagedModified, modified)
        XCTAssertEqual(colors.stagedDeleted, deleted)
        XCTAssertEqual(colors.gutterAdded, added)
        XCTAssertEqual(colors.gutterModified, modified)
        XCTAssertEqual(colors.gutterDeleted, deleted)
        XCTAssertEqual(colors.insertedBackground.alpha, 0.16, accuracy: 0.001)
        XCTAssertEqual(colors.removedBackground.alpha, 0.16, accuracy: 0.001)
        XCTAssertEqual(colors.insertedTextBackground.alpha, 77.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(colors.removedTextBackground.alpha, 77.0 / 255.0, accuracy: 0.001)
    }

    func testDecodingRejectsNonObjectJSON() {
        let data = Data("[1, 2, 3]".utf8)
        XCTAssertThrowsError(try ThemeFileCodec.decode(data)) { error in
            XCTAssertEqual(error as? ThemeSchemaMigrationError, .notAJSONObject)
        }
    }

    func testLexicalStyleFallsBackThroughDottedCapturePath() {
        var theme = BundledThemes.dark
        theme.syntax["keyword"] = TokenStyle(foreground: ThemeColor(hex: "#FF0000"), isBold: true)
        theme.syntax["keyword.conditional"] = TokenStyle(isItalic: true)

        let resolved = theme.lexicalStyle(forCapture: "keyword.conditional.ternary")
        XCTAssertEqual(resolved.foreground, ThemeColor(hex: "#FF0000"))
        XCTAssertTrue(resolved.isBold)
        XCTAssertTrue(resolved.isItalic)
    }

    func testLexicalStyleFallsBackToEditorForegroundWhenUnstyled() {
        let theme = BundledThemes.dark
        let resolved = theme.lexicalStyle(forCapture: "some.totally.unknown.capture")
        XCTAssertEqual(resolved.foreground, theme.editor.foreground)
    }

    func testResolvedTokenStylePrefersSemanticOverLexical() {
        var theme = BundledThemes.dark
        theme.syntax["variable"] = TokenStyle(foreground: ThemeColor(hex: "#111111"))
        theme.semanticTokens = SemanticTokenRules(rules: [
            "variable.readonly": TokenStyle(foreground: ThemeColor(hex: "#222222"))
        ])

        let withSemantic = theme.resolvedTokenStyle(
            captureName: "variable",
            semanticType: "variable",
            semanticModifiers: ["readonly"]
        )
        XCTAssertEqual(withSemantic.foreground, ThemeColor(hex: "#222222"))

        let withoutSemanticMatch = theme.resolvedTokenStyle(
            captureName: "variable",
            semanticType: "function",
            semanticModifiers: []
        )
        XCTAssertEqual(withoutSemanticMatch.foreground, ThemeColor(hex: "#111111"))
    }
}
