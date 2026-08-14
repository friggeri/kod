import Foundation
import XCTest
@testable import GitUI

final class GitUILocalizationTests: XCTestCase {
    func testTargetCatalogIsBundledAndResolvesEnglish() {
        XCTAssertTrue(Bundle.gitUI.localizations.contains("en"))
        XCTAssertEqual(
            gitUIStrings.string(
                "Side by Side",
                comment: "Diff view mode segment: side-by-side diff layout"
            ),
            "Side by Side"
        )
    }

    func testMissingEntryPreservesEnglishSourceFallback() {
        XCTAssertEqual(
            gitUIStrings.string(
                "Git UI fallback sentinel",
                comment: "Missing-entry fallback test"
            ),
            "Git UI fallback sentinel"
        )
    }

    func testStatusPresentationUsesTheGitUIBundle() {
        let presentation = GitStatusPresentation(
            status: .modified,
            colorRole: .modified
        )
        XCTAssertEqual(presentation.letter, "M")
        XCTAssertEqual(presentation.accessibilityDescription, "Modified")
        XCTAssertEqual(
            GitExplorerDecoration(
                presentation: presentation,
                indicator: .descendant
            ).accessibilityDescription,
            "Folder contains Git changes: Modified"
        )
    }
}
