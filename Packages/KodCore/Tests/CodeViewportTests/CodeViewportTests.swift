import AppKit
import CodeViewport
import SourceModel
import XCTest

final class CodeViewportTests: XCTestCase {
    func testVisibleLineRangeIncludesBoundedOverscan() {
        let metrics = ViewportMetrics(
            lineCount: 100,
            lineHeight: 20,
            contentWidth: 500
        )

        XCTAssertEqual(
            metrics.visibleLineRange(in: CGRect(x: 0, y: 200, width: 400, height: 100)),
            7..<18
        )
    }

    @MainActor
    func testViewportIsReadOnlySelectableAccessibleText() throws {
        let snapshot = SourceSnapshot(text: "let value = 42\n")
        let viewport = CodeViewport(snapshot: snapshot)

        try viewport.selectUTF8Range(4..<9)

        XCTAssertTrue(viewport.isFlipped)
        XCTAssertTrue(viewport.acceptsFirstResponder)
        XCTAssertEqual(viewport.accessibilityRole(), .textArea)
        XCTAssertEqual(viewport.accessibilityValue() as? String, snapshot.text)
        XCTAssertEqual(viewport.accessibilitySelectedText(), "value")
        XCTAssertGreaterThan(viewport.frame.height, 0)
    }

    @MainActor
    func testCopyUsesOnlySelectedSnapshotText() throws {
        let snapshot = SourceSnapshot(text: "alpha beta")
        let viewport = CodeViewport(snapshot: snapshot)
        try viewport.selectUTF8Range(0..<5)

        viewport.copy(nil)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "alpha")
        XCTAssertEqual(snapshot.text, "alpha beta")
    }

    @MainActor
    func testWordWrapIsOffByDefault() {
        let snapshot = SourceSnapshot(text: "short line")
        let viewport = CodeViewport(snapshot: snapshot)
        XCTAssertFalse(viewport.wordWrapEnabled)
    }

    @MainActor
    func testWordWrapIncreasesContentHeightWithoutChangingSourceText() throws {
        let longLine = String(repeating: "word ", count: 60).trimmingCharacters(in: .whitespaces)
        let snapshot = SourceSnapshot(text: longLine)
        let viewport = CodeViewport(snapshot: snapshot)
        viewport.setMinimumViewportWidth(300)
        let unwrappedHeight = viewport.frame.height

        viewport.wordWrapEnabled = true

        XCTAssertGreaterThan(
            viewport.frame.height,
            unwrappedHeight,
            "wrapping a single long line across multiple visual rows increases content height"
        )
        XCTAssertEqual(snapshot.text, longLine, "word wrap must never mutate the underlying snapshot")

        viewport.wordWrapEnabled = false
        XCTAssertEqual(
            viewport.frame.height,
            unwrappedHeight,
            "disabling word wrap restores the single-row layout"
        )
    }

    @MainActor
    func testWordWrapSelectionAndHitTestingStayMappedToSourceOffsets() throws {
        let longLine = (0..<40).map { "token\($0)" }.joined(separator: " ")
        let snapshot = SourceSnapshot(text: longLine)
        let viewport = CodeViewport(snapshot: snapshot)
        viewport.setMinimumViewportWidth(200)
        viewport.wordWrapEnabled = true
        viewport.needsDisplay = true
        _ = viewport.frame // force layout

        // Selecting the full source range must still be valid and round-trip
        // to the exact original text even though rendering wraps it across
        // several visual rows.
        try viewport.selectUTF8Range(0..<snapshot.utf8Count)
        XCTAssertEqual(viewport.accessibilitySelectedText(), longLine)
    }

    @MainActor
    func testWordWrapIsIgnoredForSafetyModeFiles() {
        let oversizedLine = String(repeating: "a", count: 200_001)
        let snapshot = SourceSnapshot(text: oversizedLine)
        XCTAssertNotNil(snapshot.safetyModeReason)

        let viewport = CodeViewport(snapshot: snapshot)
        viewport.setMinimumViewportWidth(200)
        let heightBefore = viewport.frame.height

        viewport.wordWrapEnabled = true

        XCTAssertEqual(
            viewport.frame.height,
            heightBefore,
            "safety-mode files keep the fast, unwrapped rendering path even when word wrap is toggled on"
        )
    }

    @MainActor
    func testCommandClickAndHoverReportSourceOffsetsWithoutChangingText() throws {
        let snapshot = SourceSnapshot(text: "const client = api;\n")
        let viewport = CodeViewport(snapshot: snapshot)
        viewport.frame = NSRect(x: 0, y: 0, width: 500, height: 100)
        let window = NSWindow(
            contentRect: viewport.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = viewport

        var commandClickOffset: Int?
        var linkClickOffset: Int?
        var hoverOffset: Int?
        var hoverExited = false
        viewport.onCommandClick = { commandClickOffset = $0 }
        viewport.onLinkClick = { linkClickOffset = $0 }
        viewport.onHover = { offset, _, _ in hoverOffset = offset }
        viewport.onHoverExit = { hoverExited = true }

        let location = viewport.convert(NSPoint(x: 75, y: 10), to: nil)
        let commandClick = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: location,
                modifierFlags: [.command],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        )
        viewport.mouseDown(with: commandClick)
        let clickOffset = try XCTUnwrap(commandClickOffset)
        viewport.setHoveredLinkUTF8Range(clickOffset..<(clickOffset + 1))

        let linkClick = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: location,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 2,
                clickCount: 1,
                pressure: 1
            )
        )
        viewport.mouseDown(with: linkClick)

        let mouseMoved = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .mouseMoved,
                location: location,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 3,
                clickCount: 0,
                pressure: 0
            )
        )
        viewport.mouseMoved(with: mouseMoved)
        viewport.mouseExited(with: mouseMoved)

        XCTAssertNotNil(commandClickOffset)
        XCTAssertEqual(linkClickOffset, commandClickOffset)
        XCTAssertEqual(hoverOffset, commandClickOffset)
        XCTAssertTrue(hoverExited)
        XCTAssertEqual(viewport.focusedUTF8Offset, commandClickOffset)
        XCTAssertEqual(snapshot.text, "const client = api;\n")
    }
}
