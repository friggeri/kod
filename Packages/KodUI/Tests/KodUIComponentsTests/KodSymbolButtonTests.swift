import AppKit
import XCTest
@testable import KodUIComponents

@MainActor
final class KodSymbolButtonTests: XCTestCase {
    func testSymbolButtonUsesNativeBorderlessAccessibleConfiguration() {
        let button = KodSymbolButton(
            systemSymbolName: "magnifyingglass",
            accessibilityLabel: "Search"
        )

        XCTAssertNotNil(button.image)
        XCTAssertEqual(button.toolTip, "Search")
        XCTAssertEqual(button.accessibilityLabel(), "Search")
        XCTAssertFalse(button.isBordered)
        XCTAssertEqual(button.imagePosition, .imageOnly)
        XCTAssertEqual(button.focusRingType, .exterior)
    }

    func testSelectedStyleKeepsAVisibleNonTextualBackground() {
        let button = KodSymbolButton(
            systemSymbolName: "doc.on.doc",
            accessibilityLabel: "Explorer"
        )
        button.isSelectedStyle = true

        XCTAssertEqual(button.contentTintColor, .labelColor)
        XCTAssertNotEqual(
            button.layer?.backgroundColor,
            NSColor.clear.cgColor
        )
    }

    func testResigningFirstResponderClearsCustomContrastOutlineImmediately() {
        let button = KodSymbolButton(
            systemSymbolName: "doc.on.doc",
            accessibilityLabel: "Explorer"
        )
        button.layer?.borderWidth = 2
        button.layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor

        _ = button.resignFirstResponder()

        XCTAssertEqual(button.layer?.borderWidth, 0)
        XCTAssertEqual(button.layer?.borderColor, NSColor.clear.cgColor)
    }
}
