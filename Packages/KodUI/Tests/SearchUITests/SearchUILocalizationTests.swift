import Foundation
import XCTest
@testable import SearchUI

final class SearchUILocalizationTests: XCTestCase {
    func testTargetCatalogIsBundledAndResolvesEnglish() {
        XCTAssertTrue(Bundle.searchUI.localizations.contains("en"))
        XCTAssertEqual(
            searchUIStrings.string(
                "No results.",
                comment: "Status label shown when a workspace search finds no matches"
            ),
            "No results."
        )
    }

    func testMissingEntryPreservesEnglishSourceFallback() {
        XCTAssertEqual(
            searchUIStrings.string(
                "Search UI fallback sentinel",
                comment: "Missing-entry fallback test"
            ),
            "Search UI fallback sentinel"
        )
    }
}
