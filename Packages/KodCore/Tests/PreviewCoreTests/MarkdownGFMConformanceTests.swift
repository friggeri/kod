import XCTest
@testable import PreviewCore

final class MarkdownGFMConformanceTests: XCTestCase {
    func testBareURLAndEmailAutolinksAreGFMLinks() {
        let document = MarkdownParser.parse("Visit https://example.com/a?q=1 and email person@example.com.")
        guard case .paragraph(let inlines) = document.blocks.first else {
            return XCTFail("expected paragraph")
        }
        let destinations = links(in: inlines).map(\.rawValue)
        XCTAssertEqual(destinations, ["https://example.com/a?q=1", "mailto:person@example.com"])
    }

    func testEveryFormalGFMExtensionIsEnabled() {
        let source = """
        ~~deleted~~

        - [x] complete

        | Name | Score |
        | :--- | ----: |
        | Ada | 100 |

        www.example.com

        <xmp>filtered</xmp>
        """
        let document = MarkdownParser.parse(source)
        XCTAssertTrue(document.blocks.contains { block in
            guard case .paragraph(let inlines) = block else { return false }
            return inlines.contains { if case .strikethrough = $0 { return true }; return false }
        })
        XCTAssertTrue(document.blocks.contains { block in
            guard case .list(_, _, let items) = block else { return false }
            return items.first?.checked == true
        })
        XCTAssertTrue(document.blocks.contains { if case .table = $0 { return true }; return false })
        XCTAssertTrue(document.blocks.contains { block in
            guard case .paragraph(let inlines) = block else { return false }
            return links(in: inlines).contains { $0.rawValue == "http://www.example.com" }
        })
        XCTAssertFalse(flatten(document.blocks).lowercased().contains("<xmp>"))
    }

    func testFootnotesRemainPlainTextBecauseTheyAreNotEnabled() {
        let document = MarkdownParser.parse("Text[^1]\n\n[^1]: not a footnote extension")
        XCTAssertTrue(flatten(document.blocks).contains("[^1]"))
        XCTAssertFalse(document.blocks.contains { block in
            if case .sanitizedHTMLBlock = block { return true }
            return false
        })
    }

    func testCommonMarkReferenceLinksAndNestedContainers() {
        let document = MarkdownParser.parse("> 3. [CommonMark][spec]\n>    - nested\n\n[spec]: https://spec.commonmark.org/ \"Spec\"")
        guard case .blockquote(let quote) = document.blocks.first,
              case .list(.ordered(start: 3, delimiter: "."), _, let items) = quote.first else {
            return XCTFail("expected nested ordered list in block quote")
        }
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(flatten(items[0].blocks).contains("CommonMark"))
    }

    func testTableColumnLimitProducesExplicitDiagnostic() {
        let limits = MarkdownLimits(maximumTableColumns: 1)
        let document = MarkdownParser.parse("| A | B |\n| - | - |\n| 1 | 2 |", limits: limits)
        XCTAssertTrue(document.sanitizerDiagnostics.contains { $0.contains("column preview limit") })
        XCTAssertEqual(flatten(document.blocks), "(table truncated at the column preview limit)")
    }

    func testZeroBasedOrderedListStartIsPreserved() {
        let document = MarkdownParser.parse("0. zero\n1. one")
        guard case .list(let kind, _, _) = document.blocks.first else {
            return XCTFail("expected ordered list")
        }
        XCTAssertEqual(kind, .ordered(start: 0, delimiter: "."))
    }

    func testListItemsShareTheDocumentNodeBudget() {
        let source = (0..<100).map { "- item \($0)" }.joined(separator: "\n")
        let limits = MarkdownLimits(maximumBlockCount: 8)
        let document = MarkdownParser.parse(source, limits: limits)
        guard case .list(_, _, let items) = document.blocks.first else {
            return XCTFail("expected list")
        }
        XCTAssertLessThanOrEqual(items.count, 8)
        XCTAssertTrue(document.sanitizerDiagnostics.contains { $0.contains("block count") })
    }

    func testDeepImageAltTextUsesInlineDepthLimit() {
        let delimiters = String(repeating: "*", count: 32)
        let document = MarkdownParser.parse("![\(delimiters)alt\(delimiters)](image.png)", limits: MarkdownLimits(maximumInlineDepth: 2))
        XCTAssertFalse(document.blocks.isEmpty)
    }

    private func links(in inlines: [MarkdownInline]) -> [MarkdownDestination] {
        inlines.flatMap { inline -> [MarkdownDestination] in
            switch inline {
            case .link(let destination, _, let children):
                return [destination] + links(in: children)
            case .emphasis(let children), .strong(let children), .strikethrough(let children):
                return links(in: children)
            default:
                return []
            }
        }
    }

    private func flatten(_ blocks: [MarkdownBlock]) -> String {
        func inlineText(_ inlines: [MarkdownInline]) -> String {
            inlines.map { inline in
                switch inline {
                case .text(let text), .code(let text), .sanitizedHTML(let text): return text
                case .emphasis(let children), .strong(let children), .strikethrough(let children):
                    return inlineText(children)
                case .link(_, _, let children): return inlineText(children)
                case .image(_, _, let altText): return altText
                case .softBreak, .hardBreak: return "\n"
                }
            }.joined()
        }
        return blocks.map { block in
            switch block {
            case .heading(_, let inlines), .paragraph(let inlines): return inlineText(inlines)
            case .blockquote(let children): return flatten(children)
            case .list(_, _, let items): return items.map { flatten($0.blocks) }.joined()
            case .codeBlock(_, let code), .sanitizedHTMLBlock(let code): return code
            case .table(_, let header, let rows):
                return ([header] + rows).flatMap(\.cells).map(inlineText).joined()
            case .thematicBreak: return ""
            }
        }.joined()
    }
}
