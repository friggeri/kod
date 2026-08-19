import AppKit
import FontCore
import LanguageClient
import ThemeCore
import XCTest
@testable import EditorUI
@testable import PreviewUI

@MainActor
final class LanguageHoverPopoverPresenterTests: XCTestCase {
    private func markup(kind: String, value: String) throws -> MarkupContent {
        let data = try JSONSerialization.data(withJSONObject: [
            "kind": kind,
            "value": value
        ])
        return try JSONDecoder().decode(MarkupContent.self, from: data)
    }

    func testMaximumContentSizeUsesReadableCapsAndViewportMargins() {
        XCTAssertEqual(
            LanguageHoverPopoverPresenter.maximumContentSize(
                forViewportSize: NSSize(width: 1_200, height: 900)
            ),
            NSSize(width: 760, height: 320)
        )
        XCTAssertEqual(
            LanguageHoverPopoverPresenter.maximumContentSize(
                forViewportSize: NSSize(width: 500, height: 300)
            ),
            NSSize(width: 468, height: 165)
        )
    }

    func testMarkupKindSelectsMarkdownAndUnknownKindsRemainLiteral() async throws {
        let presenter = LanguageHoverPopoverPresenter()
        let markdownResult = await presenter.makeContent(
            for: try markup(kind: "markdown", value: "**Rendered**"),
            theme: BundledThemes.dark,
            fontSettings: .default
        )
        let markdownController = try XCTUnwrap(markdownResult)
        markdownController.loadView()
        XCTAssertEqual(markdownController.renderedText, "Rendered\n")

        let unknownResult = await presenter.makeContent(
            for: try markup(kind: "future-kind", value: "**Literal**"),
            theme: BundledThemes.dark,
            fontSettings: .default
        )
        let unknownController = try XCTUnwrap(unknownResult)
        unknownController.loadView()
        XCTAssertEqual(unknownController.renderedText, "**Literal**")
    }
}
