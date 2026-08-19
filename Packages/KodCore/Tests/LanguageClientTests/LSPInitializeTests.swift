import XCTest
@testable import LanguageClient

final class LSPInitializeTests: XCTestCase {
    func testHoverContentFormatsPreferMarkdown() {
        let textDocument = ClientCapabilities.TextDocument(
            semanticTokens: ClientCapabilities.TextDocument.SemanticTokens(
                tokenTypes: [],
                tokenModifiers: []
            )
        )

        XCTAssertEqual(
            textDocument.hover.contentFormat,
            ["markdown", "plaintext"]
        )
    }
}
