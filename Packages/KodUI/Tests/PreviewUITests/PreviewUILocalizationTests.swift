import Foundation
import XCTest
@testable import PreviewUI

final class PreviewUILocalizationTests: XCTestCase {
    func testTargetCatalogIsBundledAndResolvesEnglish() {
        XCTAssertTrue(Bundle.previewUI.localizations.contains("en"))
        XCTAssertEqual(
            previewUIStrings.string(
                "Open Link?",
                comment: "Alert title asking whether to open an external link from an untrusted workspace"
            ),
            "Open Link?"
        )
    }

    func testMissingEntryPreservesEnglishSourceFallback() {
        XCTAssertEqual(
            previewUIStrings.string(
                "Preview UI fallback sentinel",
                comment: "Missing-entry fallback test"
            ),
            "Preview UI fallback sentinel"
        )
    }
}
