import XCTest
@testable import Kod

@MainActor
final class FontSettingsViewTests: XCTestCase {
    func testEmptySearchPreservesDiscoveryOrder() {
        let families = ["SF Mono", "Menlo", "Monaco"]
        XCTAssertEqual(
            FontFamilyPicker.filteredFamilies(families, query: "  "),
            families
        )
    }

    func testSearchIsCaseAndDiacriticInsensitive() {
        let families = ["SF Mono", "Ménlo", "Monaco"]
        XCTAssertEqual(
            FontFamilyPicker.filteredFamilies(families, query: "MEN"),
            ["Ménlo"]
        )
        XCTAssertEqual(
            FontFamilyPicker.filteredFamilies(families, query: "MO"),
            ["SF Mono", "Monaco"]
        )
    }
}
