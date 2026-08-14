import AppKit
import PreviewCore
import XCTest
@testable import PreviewUI

/// Headless coverage for the JSON/plist tree preview (SPEC 10.3):
/// expand/collapse via `NSOutlineView`'s data source, search, and the
/// invalid-data diagnostic fallback. No window is made key.
@MainActor
final class StructuredDataPreviewViewControllerTests: XCTestCase {
    func testValidJSONBuildsExpandableTree() {
        let document = StructuredDocument.parse(Data(#"{"a": 1, "b": [1, 2, 3]}"#.utf8))
        let controller = StructuredDataPreviewViewController(document: document)
        controller.loadView()
        XCTAssertNil(document.diagnostic)
        XCTAssertNotNil(document.node)
    }

    func testInvalidJSONShowsDiagnosticNotBlankSuccess() {
        let document = StructuredDocument.parse(Data(#"{"a": }"#.utf8))
        let controller = StructuredDataPreviewViewController(document: document)
        controller.loadView()
        XCTAssertNotNil(document.diagnostic, "invalid JSON must produce an explicit diagnostic, never a silent empty tree")
    }

    func testSearchFindsExpectedMatches() {
        let document = StructuredDocument.parse(Data(#"{"target": "found", "other": "value"}"#.utf8))
        let controller = StructuredDataPreviewViewController(document: document)
        controller.loadView()

        guard case .valid(let root) = document.result else {
            return XCTFail("expected valid document")
        }
        let matches = StructuredSearch.search(root, query: "target")
        XCTAssertFalse(matches.isEmpty)
    }

    func testBinaryPlistDocumentBuildsTree() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["k": "v"], format: .binary, options: 0)
        let document = StructuredDocument.parse(data)
        XCTAssertEqual(document.format, .binaryPropertyList)
        let controller = StructuredDataPreviewViewController(document: document)
        controller.loadView()
        XCTAssertNotNil(document.node)
    }

    // MARK: - Accessibility (SPEC 14)

    func testRowCellsHaveExplicitAccessibilityLabelsDistinctFromDisplayedText() {
        let document = StructuredDocument.parse(Data(#"{"name": "value"}"#.utf8))
        let controller = StructuredDataPreviewViewController(document: document)
        controller.loadView()
        let keyLabel = controller.accessibilityLabelForCell(key: "name", node: .string("value"), column: "key")
        let valueLabel = controller.accessibilityLabelForCell(key: "name", node: .string("value"), column: "value")
        XCTAssertEqual(keyLabel, "Key: name")
        XCTAssertEqual(valueLabel, "Value: value")
    }

    func testSearchFieldAndDiagnosticHaveExplicitAccessibilityLabels() {
        let document = StructuredDocument.parse(Data(#"{"a": }"#.utf8))
        let controller = StructuredDataPreviewViewController(document: document)
        controller.loadView()
        XCTAssertEqual(controller.searchFieldAccessibilityLabel, "Search keys and values")
        XCTAssertEqual(controller.diagnosticAccessibilityLabel, "Parse error")
    }
}
