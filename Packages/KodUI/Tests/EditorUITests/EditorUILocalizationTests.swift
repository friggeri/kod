import Foundation
import XCTest
@testable import EditorUI

final class EditorUILocalizationTests: XCTestCase {
    func testTargetCatalogIsBundledAndResolvesEnglish() {
        XCTAssertTrue(Bundle.editorUI.localizations.contains("en"))
        XCTAssertEqual(
            editorUIStrings.string(
                "Pinned tab",
                comment: "Accessibility value component indicating a tab chip is pinned"
            ),
            "Pinned tab"
        )
    }

    func testMissingEntryPreservesEnglishSourceFallback() {
        XCTAssertEqual(
            editorUIStrings.string(
                "Editor UI fallback sentinel",
                comment: "Missing-entry fallback test"
            ),
            "Editor UI fallback sentinel"
        )
    }
}
