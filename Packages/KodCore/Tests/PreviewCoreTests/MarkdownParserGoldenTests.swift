import XCTest
@testable import PreviewCore

final class MarkdownParserGoldenTests: XCTestCase {
    func testParsesHeadingsAllLevels() {
        let source = (1...6).map { String(repeating: "#", count: $0) + " Heading \($0)" }.joined(separator: "\n\n")
        let document = MarkdownParser.parse(source)
        XCTAssertEqual(document.blocks.count, 6)
        for (index, block) in document.blocks.enumerated() {
            guard case .heading(let level, let inlines) = block else {
                return XCTFail("expected heading at index \(index)")
            }
            XCTAssertEqual(level, index + 1)
            XCTAssertEqual(inlines, [.text("Heading \(index + 1)")])
        }
    }

    func testATXHeadingStripsTrailingHashes() {
        let document = MarkdownParser.parse("## Title ##")
        guard case .heading(let level, let inlines) = document.blocks.first else {
            return XCTFail("expected heading")
        }
        XCTAssertEqual(level, 2)
        XCTAssertEqual(inlines, [.text("Title")])
    }

    func testSetextHeadings() {
        let document = MarkdownParser.parse("Title One\n=========\n\nTitle Two\n---------")
        guard case .heading(1, let firstInlines) = document.blocks[0] else {
            return XCTFail("expected level-1 setext heading")
        }
        XCTAssertEqual(firstInlines, [.text("Title One")])
        guard case .heading(2, let secondInlines) = document.blocks[1] else {
            return XCTFail("expected level-2 setext heading")
        }
        XCTAssertEqual(secondInlines, [.text("Title Two")])
    }

    func testParsesParagraphWithSoftBreak() {
        let document = MarkdownParser.parse("line one\nline two")
        guard case .paragraph(let inlines) = document.blocks.first else {
            return XCTFail("expected paragraph")
        }
        XCTAssertEqual(inlines, [.text("line one"), .softBreak, .text("line two")])
    }

    func testParsesHardBreakFromTrailingSpaces() {
        let document = MarkdownParser.parse("line one  \nline two")
        guard case .paragraph(let inlines) = document.blocks.first else {
            return XCTFail("expected paragraph")
        }
        XCTAssertEqual(inlines, [.text("line one"), .hardBreak, .text("line two")])
    }

    func testParsesEmphasisAndStrong() {
        let document = MarkdownParser.parse("*italic* and **bold** and ***both***")
        guard case .paragraph(let inlines) = document.blocks.first else {
            return XCTFail("expected paragraph")
        }
        XCTAssertEqual(inlines, [
            .emphasis([.text("italic")]),
            .text(" and "),
            .strong([.text("bold")]),
            .text(" and "),
            .emphasis([.strong([.text("both")])])
        ])
    }

    func testParsesStrikethrough() {
        let document = MarkdownParser.parse("~~gone~~")
        guard case .paragraph(let inlines) = document.blocks.first else {
            return XCTFail("expected paragraph")
        }
        XCTAssertEqual(inlines, [.strikethrough([.text("gone")])])
    }

    func testParsesCodeSpan() {
        let document = MarkdownParser.parse("Use `let x = 1` here")
        guard case .paragraph(let inlines) = document.blocks.first else {
            return XCTFail("expected paragraph")
        }
        XCTAssertEqual(inlines, [.text("Use "), .code("let x = 1"), .text(" here")])
    }

    func testParsesLinkWithTitle() {
        let document = MarkdownParser.parse(#"[Kod](https://example.com/kod "Kod homepage")"#)
        guard case .paragraph(let inlines) = document.blocks.first,
              case .link(let destination, let title, let children) = inlines.first else {
            return XCTFail("expected link")
        }
        XCTAssertEqual(destination.rawValue, "https://example.com/kod")
        XCTAssertEqual(destination.scheme, .https)
        XCTAssertEqual(title, "Kod homepage")
        XCTAssertEqual(children, [.text("Kod")])
    }

    func testParsesLocalRelativeLink() {
        let document = MarkdownParser.parse("[readme](./README.md)")
        guard case .paragraph(let inlines) = document.blocks.first,
              case .link(let destination, _, _) = inlines.first else {
            return XCTFail("expected link")
        }
        XCTAssertEqual(destination.scheme, .local)
        XCTAssertFalse(destination.requiresConfirmationInUntrustedWorkspace)
    }

    func testParsesImage() {
        let document = MarkdownParser.parse("![alt text](image.png)")
        guard case .paragraph(let inlines) = document.blocks.first,
              case .image(let destination, _, let altText) = inlines.first else {
            return XCTFail("expected image")
        }
        XCTAssertEqual(destination.rawValue, "image.png")
        XCTAssertEqual(altText, "alt text")
    }

    func testParsesAutolink() {
        let document = MarkdownParser.parse("<https://example.com>")
        guard case .paragraph(let inlines) = document.blocks.first,
              case .link(let destination, _, _) = inlines.first else {
            return XCTFail("expected autolink")
        }
        XCTAssertEqual(destination.scheme, .https)
    }

    func testParsesBlockquote() {
        let document = MarkdownParser.parse("> quoted text\n> more text")
        guard case .blockquote(let innerBlocks) = document.blocks.first,
              case .paragraph(let inlines) = innerBlocks.first else {
            return XCTFail("expected blockquote containing a paragraph")
        }
        XCTAssertEqual(inlines, [.text("quoted text"), .softBreak, .text("more text")])
    }

    func testParsesNestedBlockquote() {
        let document = MarkdownParser.parse("> outer\n> > inner")
        guard case .blockquote(let outerBlocks) = document.blocks.first else {
            return XCTFail("expected outer blockquote")
        }
        XCTAssertTrue(outerBlocks.contains {
            if case .blockquote = $0 { return true }
            return false
        })
    }

    func testParsesUnorderedList() {
        let document = MarkdownParser.parse("- one\n- two\n- three")
        guard case .list(let kind, _, let items) = document.blocks.first else {
            return XCTFail("expected list")
        }
        XCTAssertEqual(kind, .unordered(marker: "-"))
        XCTAssertEqual(items.count, 3)
        guard case .paragraph(let inlines) = items[1].blocks.first else {
            return XCTFail("expected paragraph in second item")
        }
        XCTAssertEqual(inlines, [.text("two")])
    }

    func testParsesOrderedListWithCustomStart() {
        let document = MarkdownParser.parse("5. five\n6. six")
        guard case .list(let kind, _, let items) = document.blocks.first else {
            return XCTFail("expected list")
        }
        XCTAssertEqual(kind, .ordered(start: 5, delimiter: "."))
        XCTAssertEqual(items.count, 2)
    }

    func testParsesTaskList() {
        let document = MarkdownParser.parse("- [ ] todo\n- [x] done")
        guard case .list(_, _, let items) = document.blocks.first else {
            return XCTFail("expected list")
        }
        XCTAssertEqual(items[0].checked, false)
        XCTAssertEqual(items[1].checked, true)
    }

    func testParsesFencedCodeBlockWithLanguage() {
        let document = MarkdownParser.parse("```swift\nlet x = 1\n```")
        guard case .codeBlock(let language, let code) = document.blocks.first else {
            return XCTFail("expected code block")
        }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(code, "let x = 1")
    }

    func testParsesFencedCodeBlockWithTildes() {
        let document = MarkdownParser.parse("~~~\nplain\n~~~")
        guard case .codeBlock(let language, let code) = document.blocks.first else {
            return XCTFail("expected code block")
        }
        XCTAssertNil(language)
        XCTAssertEqual(code, "plain")
    }

    func testParsesIndentedCodeBlock() {
        let document = MarkdownParser.parse("    indented code\n    second line")
        guard case .codeBlock(let language, let code) = document.blocks.first else {
            return XCTFail("expected code block")
        }
        XCTAssertNil(language)
        XCTAssertEqual(code, "indented code\nsecond line")
    }

    func testParsesThematicBreak() {
        for marker in ["---", "***", "___", "- - -"] {
            let document = MarkdownParser.parse(marker)
            XCTAssertEqual(document.blocks, [.thematicBreak], "expected thematic break for \(marker)")
        }
    }

    func testParsesGFMTable() {
        let source = """
        | Name | Score |
        | ---- | ----: |
        | Ada  | 100   |
        | Lin  | 95    |
        """
        let document = MarkdownParser.parse(source)
        guard case .table(let alignments, let header, let rows) = document.blocks.first else {
            return XCTFail("expected table")
        }
        XCTAssertEqual(alignments, [.none, .right])
        XCTAssertEqual(header.cells[0], [.text("Name")])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].cells[0], [.text("Ada")])
        XCTAssertEqual(rows[0].cells[1], [.text("100")])
    }

    func testParsesTableAlignmentVariants() {
        let source = """
        | A | B | C | D |
        |---|:--|:-:|--:|
        | 1 | 2 | 3 | 4 |
        """
        let document = MarkdownParser.parse(source)
        guard case .table(let alignments, _, _) = document.blocks.first else {
            return XCTFail("expected table")
        }
        XCTAssertEqual(alignments, [.none, .left, .center, .right])
    }

    func testSanitizesRawHTMLBlockRemovingScript() {
        let document = MarkdownParser.parse("<div>\n<script>alert(1)</script>\n<b>bold</b>\n</div>")
        let combinedText = flattenAllTextIncludingSanitizedHTML(document.blocks)
        XCTAssertFalse(combinedText.lowercased().contains("<script"))
        XCTAssertFalse(combinedText.lowercased().contains("alert"))
        XCTAssertTrue(combinedText.contains("<b>bold</b>"))
        XCTAssertFalse(document.sanitizerDiagnostics.isEmpty, "sanitization must be reported, not silent")
    }

    func testEscapesAreHonored() {
        let document = MarkdownParser.parse(#"\*not emphasis\*"#)
        guard case .paragraph(let inlines) = document.blocks.first else {
            return XCTFail("expected paragraph")
        }
        XCTAssertEqual(inlines, [.text("*not emphasis*")])
    }

    func testNamedAndNumericEntitiesDecode() {
        let document = MarkdownParser.parse("A &amp; B &#169; &#x2014;")
        guard case .paragraph(let inlines) = document.blocks.first else {
            return XCTFail("expected paragraph")
        }
        XCTAssertEqual(inlines, [.text("A & B \u{00A9} \u{2014}")])
    }

    // MARK: - Helpers

    private func flattenAllTextIncludingSanitizedHTML(_ blocks: [MarkdownBlock]) -> String {
        var output = ""
        func walkInlines(_ inlines: [MarkdownInline]) {
            for inline in inlines {
                switch inline {
                case .text(let text): output += text
                case .sanitizedHTML(let text): output += text
                case .code(let text): output += text
                case .emphasis(let children), .strong(let children), .strikethrough(let children):
                    walkInlines(children)
                case .link(_, _, let children): walkInlines(children)
                case .image(_, _, let alt): output += alt
                case .softBreak, .hardBreak: output += " "
                }
            }
        }
        func walkBlocks(_ blocks: [MarkdownBlock]) {
            for block in blocks {
                switch block {
                case .heading(_, let inlines), .paragraph(let inlines):
                    walkInlines(inlines)
                case .blockquote(let inner):
                    walkBlocks(inner)
                case .list(_, _, let items):
                    for item in items { walkBlocks(item.blocks) }
                case .codeBlock(_, let code):
                    output += code
                case .table(_, let header, let rows):
                    header.cells.forEach(walkInlines)
                    for row in rows { row.cells.forEach(walkInlines) }
                case .sanitizedHTMLBlock(let text):
                    output += text
                case .thematicBreak:
                    break
                }
            }
        }
        walkBlocks(blocks)
        return output
    }
}
