import AppKit
import SourceModel
import XCTest
@testable import CodeViewport

@MainActor
final class CodeViewportSelectionTests: XCTestCase {
    func testProgrammaticSelectAllAndAccessibilitySelectionShareOneCallback() throws {
        let snapshot = SourceSnapshot(text: "A😀B")
        let viewport = CodeViewport(snapshot: snapshot)
        var observed: [CodeViewportSelectionState] = []
        viewport.onSelectionStateChange = { observed.append($0) }

        try viewport.selectUTF8Range(1..<5)
        viewport.selectAll(nil)
        try viewport.selectUTF16Range(NSRange(location: 1, length: 2))

        XCTAssertEqual(observed.count, 3)
        XCTAssertEqual(observed[0].selectedUTF8Range, 1..<5)
        XCTAssertEqual(observed[1].selectedUTF8Range, 0..<snapshot.utf8Count)
        XCTAssertEqual(observed[2].selectedUTF8Range, 1..<5)
        XCTAssertEqual(viewport.accessibilitySelectedText(), "😀")
    }

    func testRepeatingTheSameSelectionDoesNotPublishDuplicateState() throws {
        let viewport = CodeViewport(snapshot: SourceSnapshot(text: "hello"))
        var observed: [CodeViewportSelectionState] = []
        viewport.onSelectionStateChange = { observed.append($0) }

        try viewport.selectUTF8Range(0..<2)
        try viewport.selectUTF8Range(0..<2)

        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(viewport.selectionState.selectedUTF8Range, 0..<2)
    }
}
