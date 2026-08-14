import LanguageClient
import TextDecorationModel
import ThemeCore
import XCTest
@testable import CodeViewport

final class SemanticTokenDecorationSourceTests: XCTestCase {
    func testTokensWithARuleProduceARunAndTokensWithoutOneAreOmitted() {
        var theme = BundledThemes.dark
        theme.semanticTokens = SemanticTokenRules(rules: [
            "function": TokenStyle(foreground: ThemeColor(red: 1, green: 0, blue: 0, alpha: 1))
        ])

        let tokens = [
            SemanticToken(utf8Range: 0..<4, tokenType: "function", tokenModifiers: []),
            SemanticToken(utf8Range: 5..<9, tokenType: "unstyledType", tokenModifiers: [])
        ]

        let layer = SemanticTokenDecorationSource.layer(
            fromTokens: tokens,
            theme: theme,
            snapshotVersion: 3,
            layerVersion: 1
        )

        XCTAssertEqual(layer.kind, .semantic)
        XCTAssertEqual(layer.snapshotVersion, 3)
        XCTAssertEqual(layer.layerVersion, 1)
        XCTAssertEqual(layer.runs.count, 1, "Only the token with a matching rule should contribute a run")
        XCTAssertEqual(layer.runs.first?.utf8Range, 0..<4)
        XCTAssertEqual(layer.runs.first?.attributes.foreground, ThemeColor(red: 1, green: 0, blue: 0, alpha: 1))
    }

    func testModifierSpecificRuleTakesPrecedenceOverBareType() {
        var theme = BundledThemes.dark
        theme.semanticTokens = SemanticTokenRules(rules: [
            "variable": TokenStyle(foreground: ThemeColor(red: 0, green: 1, blue: 0, alpha: 1)),
            "variable.readonly": TokenStyle(foreground: ThemeColor(red: 0, green: 0, blue: 1, alpha: 1))
        ])

        let tokens = [SemanticToken(utf8Range: 0..<3, tokenType: "variable", tokenModifiers: ["readonly"])]
        let layer = SemanticTokenDecorationSource.layer(
            fromTokens: tokens,
            theme: theme,
            snapshotVersion: 1,
            layerVersion: 1
        )

        XCTAssertEqual(layer.runs.first?.attributes.foreground, ThemeColor(red: 0, green: 0, blue: 1, alpha: 1))
    }
}
