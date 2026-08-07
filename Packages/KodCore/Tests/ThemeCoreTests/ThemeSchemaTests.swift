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
