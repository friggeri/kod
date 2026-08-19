import SourceModel
import SyntaxCore
import ThemeCore
import XCTest
@testable import PreviewCore

final class MarkdownRendererTests: XCTestCase {
    func testRendersHeadingAndParagraphRuns() async {
        let document = MarkdownParser.parse("# Title\n\nSome **bold** text.")
        let rendered = await MarkdownRenderer.render(document, theme: ThemeFixture.theme)
        guard case .heading(let level, let runs) = rendered.blocks[0] else {
            return XCTFail("expected heading")
        }
        XCTAssertEqual(level, 1)
        XCTAssertEqual(runs.map(\.text), ["Title"])

        guard case .paragraph(let paragraphRuns) = rendered.blocks[1] else {
            return XCTFail("expected paragraph")
        }
        XCTAssertEqual(paragraphRuns.map(\.text), ["Some ", "bold", " text."])
        XCTAssertTrue(paragraphRuns[1].isBold)
    }

    func testFencedSwiftCodeBlockGetsSyntaxHighlighting() async {
        let document = MarkdownParser.parse("```swift\nlet x = 1\n```")
        let rendered = await MarkdownRenderer.render(document, theme: ThemeFixture.theme)
        guard case .codeBlock(let language, let sourceText, let runs) = rendered.blocks[0] else {
            return XCTFail("expected code block")
        }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(sourceText, "let x = 1")
        XCTAssertFalse(runs.isEmpty, "expected at least one highlighted run reusing SyntaxCore/ThemeCore")
    }

    func testUnknownFenceLanguageRendersPlainWithoutCrashing() async {
        let document = MarkdownParser.parse("```brainfuck\n+++++[->++<]\n```")
        let rendered = await MarkdownRenderer.render(document, theme: ThemeFixture.theme)
        guard case .codeBlock(let language, _, let runs) = rendered.blocks[0] else {
            return XCTFail("expected code block")
        }
        XCTAssertEqual(language, "brainfuck")
        XCTAssertEqual(runs, [], "an unrecognized fence language must fall back to plain, unhighlighted text")
    }

    func testFenceAliasesCoverEveryBundledLanguageFamily() {
        let aliases: [(String, SyntaxLanguage)] = [
            ("ts", .typescript),
            ("jsx", .javascript),
            ("py", .python),
            ("rs", .rust),
            ("shellscript", .shell),
            ("md", .markdown),
            ("jsonc", .json),
            ("yml", .yaml),
            ("toml", .toml),
            ("h", .c),
            ("golang", .go),
            ("java", .java),
            ("rb", .ruby),
            ("lua", .lua),
            ("gql", .graphql),
            ("plist", .xml)
        ]
        for (alias, expected) in aliases {
            XCTAssertEqual(
                MarkdownFenceLanguage.syntaxLanguage(forFenceLanguage: alias),
                expected,
                alias
            )
        }
    }

    func testTableRendersHeaderAndRows() async {
        let source = "| A | B |\n| - | - |\n| 1 | 2 |"
        let document = MarkdownParser.parse(source)
        let rendered = await MarkdownRenderer.render(document, theme: ThemeFixture.theme)
        guard case .table(_, let header, let rows) = rendered.blocks[0] else {
            return XCTFail("expected table")
        }
        XCTAssertEqual(header.map { $0.map(\.text) }, [["A"], ["B"]])
        XCTAssertEqual(rows.count, 1)
    }

    func testSanitizerDiagnosticsPropagateToRenderDocument() async {
        let document = MarkdownParser.parse("<script>alert(1)</script>")
        let rendered = await MarkdownRenderer.render(document, theme: ThemeFixture.theme)
        XCTAssertFalse(rendered.sanitizerDiagnostics.isEmpty)
    }
}

enum ThemeFixture {
    static let theme = BundledThemes.dark
}
