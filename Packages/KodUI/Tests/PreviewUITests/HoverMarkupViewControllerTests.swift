import AppKit
import FontCore
import PreviewCore
import ThemeCore
import XCTest
@testable import PreviewUI

@MainActor
final class HoverMarkupViewControllerTests: XCTestCase {
    private func makeController(
        _ content: HoverMarkupContent,
        isWorkspaceTrusted: Bool = true,
        openExternalURL: @escaping @MainActor (URL) -> Void = { _ in },
        confirmBeforeOpening: @escaping @MainActor (URL) -> Bool = { _ in false }
    ) async throws -> HoverMarkupViewController {
        let result = await HoverMarkupViewController.make(
            content: content,
            theme: BundledThemes.dark,
            fontSettings: .default,
            isWorkspaceTrusted: isWorkspaceTrusted,
            openExternalURL: openExternalURL,
            confirmBeforeOpening: confirmBeforeOpening
        )
        let controller = try XCTUnwrap(result)
        controller.loadView()
        return controller
    }

    func testMarkdownRendersCompactProseCodeAndInlineCode() async throws {
        let controller = try await makeController(
            .markdown(
                """
                ```typescript
                const answer: number = 42
                ```

                ---

                Composition **root** with an inline `Store` dependency.
                """
            )
        )
        let attributed = controller.attributedText
        XCTAssertFalse(attributed.string.contains("```"))
        XCTAssertFalse(attributed.string.contains("**"))
        XCTAssertTrue(attributed.string.contains("const answer: number = 42"))
        XCTAssertTrue(attributed.string.contains("Composition root"))

        let proseRange = (attributed.string as NSString).range(of: "Composition")
        let codeRange = (attributed.string as NSString).range(of: "const answer")
        let inlineCodeRange = (attributed.string as NSString).range(of: "Store")
        let proseFont = try XCTUnwrap(
            attributed.attribute(.font, at: proseRange.location, effectiveRange: nil) as? NSFont
        )
        let codeFont = try XCTUnwrap(
            attributed.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
        )
        XCTAssertFalse(proseFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
        XCTAssertTrue(codeFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
        XCTAssertEqual(proseFont.pointSize, 13, accuracy: 0.01)
        XCTAssertNotNil(
            attributed.attribute(
                .kodMarkdownInlineCodeBackground,
                at: inlineCodeRange.location,
                effectiveRange: nil
            )
        )

        var codeColors: Set<NSColor> = []
        attributed.enumerateAttribute(
            .foregroundColor,
            in: NSRange(
                location: codeRange.location,
                length: (attributed.string as NSString).range(of: "const answer: number = 42").length
            )
        ) { value, _, _ in
            if let color = value as? NSColor {
                codeColors.insert(color)
            }
        }
        XCTAssertGreaterThan(codeColors.count, 1, "the fenced TypeScript signature should carry themed syntax runs")
        XCTAssertFalse(controller.textIsEditable)
        XCTAssertTrue(controller.textIsSelectable)
        XCTAssertEqual(controller.textViewIdentifier?.rawValue, "languageHover.textView")
    }

    func testPlaintextRemainsLiteralAndUsesEditorFont() async throws {
        let controller = try await makeController(.plaintext("  **literal** `text`  "))
        let attributed = controller.attributedText
        XCTAssertEqual(attributed.string, "  **literal** `text`  ")
        let font = try XCTUnwrap(
            attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        )
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    func testLeadingWhitespaceStillProducesIndentedMarkdownCode() async throws {
        let controller = try await makeController(.markdown("    let value = 1"))
        let attributed = controller.attributedText
        let range = (attributed.string as NSString).range(of: "let value = 1")
        let font = try XCTUnwrap(
            attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        )
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    func testSizingCapsLongContentAndOnlyEnablesScrollerWhenNeeded() async throws {
        let longController = try await makeController(
            .markdown(Array(repeating: "A long hover description with `code`.", count: 30).joined(separator: "\n\n"))
        )
        let longSize = longController.fittingContentSize(
            maximumSize: NSSize(width: 520, height: 120)
        )
        XCTAssertLessThanOrEqual(longSize.width, 520)
        XCTAssertEqual(longSize.height, 120, accuracy: 0.5)
        XCTAssertTrue(longController.hasVerticalScroller)
        XCTAssertGreaterThan(longController.renderedTextViewFrame.height, longSize.height)

        let shortController = try await makeController(.markdown("Short description."))
        let shortSize = shortController.fittingContentSize(
            maximumSize: NSSize(width: 520, height: 120)
        )
        XCTAssertGreaterThanOrEqual(shortSize.width, 260)
        XCTAssertLessThan(shortSize.height, 120)
        XCTAssertFalse(shortController.hasVerticalScroller)
    }

    func testNaturalWidthKeepsAFittingSignatureOnOneLine() async throws {
        let signature = "func renderHoverDescription() -> AttributedString"
        let controller = try await makeController(.plaintext(signature))
        _ = controller.fittingContentSize(
            maximumSize: NSSize(width: 520, height: 120)
        )
        XCTAssertEqual(
            controller.renderedLineFragmentCount(containing: signature),
            1
        )
    }

    func testLinksUseWorkspaceTrustPolicyAndBlockUnsafeSchemes() async throws {
        var confirmationURL: URL?
        var openedURL: URL?
        let controller = try await makeController(
            .markdown("[site](https://example.com) [run](command:workbench.action) [readme](./README.md)"),
            isWorkspaceTrusted: false,
            openExternalURL: { openedURL = $0 },
            confirmBeforeOpening: { url in
                confirmationURL = url
                return false
            }
        )
        var openedPath: String?
        controller.openLocalRelativePath = { openedPath = $0 }

        XCTAssertTrue(
            controller.textView(
                NSTextView(),
                clickedOnLink: "https://example.com",
                at: 0
            )
        )
        XCTAssertEqual(confirmationURL, URL(string: "https://example.com"))
        XCTAssertNil(openedURL)

        confirmationURL = nil
        XCTAssertTrue(
            controller.textView(
                NSTextView(),
                clickedOnLink: "command:workbench.action",
                at: 0
            )
        )
        XCTAssertNil(confirmationURL)
        XCTAssertNil(openedURL)

        XCTAssertTrue(
            controller.textView(
                NSTextView(),
                clickedOnLink: "./README.md",
                at: 0
            )
        )
        XCTAssertEqual(openedPath, "./README.md")
    }
}
