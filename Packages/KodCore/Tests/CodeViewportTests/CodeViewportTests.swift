import AppKit
import SourceIO
import SourceModel
import XCTest
@testable import CodeViewport

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
    func testWordWrapIsIgnoredForSafetyModeFiles() throws {
        let oversizedLine = String(repeating: "a", count: 200_001)
        let snapshot = try SourceSnapshotLoader(
            renderingSafetyPolicy: .codeViewportDefault
        ).load(
            data: Data(oversizedLine.utf8),
            url: URL(fileURLWithPath: "/oversized.swift")
        )
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

    @MainActor
    func testGutterChangesHitTestWithoutTakingOverTheFoldLane() throws {
        let snapshot = SourceSnapshot(text: "first\nsecond\nthird\n")
        let viewport = CodeViewport(snapshot: snapshot)
        viewport.frame = NSRect(x: 0, y: 0, width: 500, height: viewport.frame.height)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let scrollView = NSScrollView(frame: window.contentView?.bounds ?? .zero)
        scrollView.documentView = viewport
        window.contentView = scrollView

        XCTAssertTrue(viewport.applyGutterChanges(
            [
                CodeGutterChange(
                    id: "added",
                    kind: .added,
                    location: .lines(1..<2),
                    accessibilityLabel: "Added line 2"
                ),
                CodeGutterChange(
                    id: "deleted",
                    kind: .deleted,
                    location: .deletion(afterLine: -1),
                    accessibilityLabel: "Deleted before line 1"
                )
            ],
            snapshotVersion: snapshot.version,
            layerVersion: 1
        ))

        let lanes = viewport.gutterLaneLayout
        XCTAssertLessThan(lanes.lineNumbers.maxX, lanes.gitStatus.minX)
        XCTAssertLessThan(lanes.gitStatus.maxX, lanes.folding.minX)

        XCTAssertEqual(
            viewport.gutterChange(
                at: NSPoint(x: lanes.gitStatus.midX, y: viewport.lineHeight * 1.5)
            )?.id,
            "added"
        )
        XCTAssertEqual(
            viewport.gutterChange(at: NSPoint(x: lanes.gitStatus.midX, y: 1))?.id,
            "deleted"
        )
        XCTAssertNil(
            viewport.gutterChange(
                at: NSPoint(x: lanes.lineNumbers.midX, y: viewport.lineHeight * 1.5)
            ),
            "the line-number lane is not part of the Git-status hit target"
        )
        XCTAssertNil(
            viewport.gutterChange(
                at: NSPoint(x: lanes.folding.midX, y: viewport.lineHeight * 1.5)
            ),
            "the folding lane is not part of the Git-status hit target"
        )

        XCTAssertEqual(
            GutterModel.markerRect(
                in: lanes.gitStatus,
                layer: .primary,
                y: 0,
                height: viewport.lineHeight
            ).width,
            4
        )
        XCTAssertEqual(
            GutterModel.markerRect(
                in: lanes.gitStatus,
                layer: .secondary,
                y: 0,
                height: viewport.lineHeight
            ).width,
            3
        )
    }

    @MainActor
    func testEmbeddedViewZoneShiftsFollowingSourceRowsWithoutChangingOffsets() throws {
        let snapshot = SourceSnapshot(text: "first\nsecond\nthird\n")
        let viewport = CodeViewport(snapshot: snapshot)
        viewport.setMinimumViewportWidth(400)
        let originalHeight = viewport.frame.height
        let zoneView = NSView()
        let zoneID = CodeViewZoneID("hunk-1")

        XCTAssertTrue(viewport.installViewZone(
            id: zoneID,
            afterLine: 0,
            heightInLines: 4,
            view: zoneView
        ))
        XCTAssertEqual(viewport.activeViewZoneID, zoneID)
        XCTAssertEqual(viewport.frame.height, originalHeight + (4 * viewport.lineHeight), accuracy: 0.01)
        XCTAssertEqual(
            try XCTUnwrap(viewport.embeddedViewZoneFrame).minY,
            viewport.lineHeight,
            accuracy: 0.01
        )
        XCTAssertTrue(viewport.scrollViewZoneToTop(id: zoneID))
        XCTAssertFalse(viewport.scrollViewZoneToTop(id: CodeViewZoneID("other")))

        let secondLinePoint = NSPoint(
            x: 80,
            y: (5 * viewport.lineHeight) + (viewport.lineHeight / 2)
        )
        let offset = viewport.sourceOffset(at: secondLinePoint)
        XCTAssertEqual(
            try snapshot.position(forUTF8Offset: offset, encoding: .utf8).line,
            1,
            "rows after the zone must still map to their original source line"
        )

        viewport.removeViewZone(id: zoneID)
        XCTAssertNil(viewport.activeViewZoneID)
        XCTAssertEqual(viewport.frame.height, originalHeight, accuracy: 0.01)
    }

    @MainActor
    func testGutterChangeApplicationsRejectStaleAndInvalidLocations() {
        let snapshot = SourceSnapshot(text: "one\ntwo\n")
        let viewport = CodeViewport(snapshot: snapshot)
        let valid = CodeGutterChange(
            id: "valid",
            kind: .modified,
            location: .lines(0..<1),
            accessibilityLabel: "Modified line 1"
        )
        XCTAssertTrue(viewport.applyGutterChanges(
            [valid],
            snapshotVersion: snapshot.version,
            layerVersion: 2
        ))
        XCTAssertFalse(viewport.applyGutterChanges(
            [valid],
            snapshotVersion: snapshot.version,
            layerVersion: 1
        ))
        XCTAssertFalse(viewport.applyGutterChanges(
            [
                CodeGutterChange(
                    id: "invalid",
                    kind: .added,
                    location: .lines(3..<4),
                    accessibilityLabel: "Invalid"
                )
            ],
            snapshotVersion: snapshot.version,
            layerVersion: 3
        ))
    }
}
