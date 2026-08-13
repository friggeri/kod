import AppKit
@testable import CodeViewport
import SourceModel
import SyntaxCore
import XCTest

private extension NSView {
    func firstDescendant(withIdentifier identifier: String) -> NSView? {
        if self.identifier?.rawValue == identifier {
            return self
        }
        for subview in subviews {
            if let found = subview.firstDescendant(withIdentifier: identifier) {
                return found
            }
        }
        return nil
    }

    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        if let match = self as? T {
            return match
        }
        for subview in subviews {
            if let found = subview.firstDescendant(ofType: type) {
                return found
            }
        }
        return nil
    }
}

@MainActor
final class CodeDocumentViewControllerTests: XCTestCase {
    /// Test windows must stay alive for the geometry (scroll offsets,
    /// visible rects) that Back/Forward navigation depends on to be real.
    private var windows: [NSWindow] = []

    private func makeController(text: String) -> CodeDocumentViewController {
        let snapshot = SourceSnapshot(text: text)
        let controller = CodeDocumentViewController(snapshot: snapshot)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 800, height: 600))
        window.layoutIfNeeded()
        windows.append(window)
        return controller
    }

    func testExplicitPlainTextOverridesFilenameDetection() {
        let snapshot = SourceSnapshot(
            text: "{\"value\": true}\n",
            url: URL(fileURLWithPath: "/tmp/example.json")
        )

        let controller = CodeDocumentViewController(
            snapshot: snapshot,
            syntaxLanguage: nil
        )

        XCTAssertNil(controller.viewport.language)
        XCTAssertNil(controller.highlightingTask)
    }

    func testExplicitGrammarAppliesToUnknownExtension() {
        let snapshot = SourceSnapshot(
            text: "{\"value\": true}\n",
            url: URL(fileURLWithPath: "/tmp/example.widget")
        )

        let controller = CodeDocumentViewController(
            snapshot: snapshot,
            syntaxLanguage: .json
        )

        XCTAssertEqual(controller.viewport.language, .json)
        XCTAssertNotNil(controller.highlightingTask)
    }

    func testFindBarStartsHiddenAndTogglesVisibility() {
        let controller = makeController(text: "alpha beta gamma")
        XCTAssertFalse(controller.isFindBarShown)

        controller.toggleFindBar()
        XCTAssertTrue(controller.isFindBarShown)

        controller.toggleFindBar()
        XCTAssertFalse(controller.isFindBarShown)
    }

    func testScrollingRedrawsViewportRelativeStickyHeaders() {
        let controller = makeController(text: String(repeating: "line\n", count: 200))
        XCTAssertTrue(controller.postsScrollBoundsChanges)
        controller.viewport.needsDisplay = false
        guard let scrollView = controller.view.firstDescendant(ofType: NSScrollView.self) else {
            return XCTFail("source scroll view not found")
        }
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: 100))
        XCTAssertTrue(controller.viewport.needsDisplay)
    }

    func testFindHighlightsFirstMatchAndNavigatesToNext() throws {
        let controller = makeController(text: "foo bar foo baz foo")
        controller.toggleFindBar()

        guard let findField = controller.view.firstDescendant(withIdentifier: "find.query") as? NSSearchField else {
            return XCTFail("find.query field not found")
        }
        findField.stringValue = "foo"
        controller.controlTextDidChange(Notification(name: .init("test")))

        XCTAssertEqual(controller.viewport.selectedUTF8Range, 0..<3)
        XCTAssertEqual(controller.activeMinimapMarkers.findMatches, [0..<3, 8..<11, 16..<19])
        XCTAssertEqual(controller.activeMinimapMarkers.selection, 0..<3)

        guard let matchCountLabel = controller.view.firstDescendant(withIdentifier: "find.matchCount") as? NSTextField
        else {
            return XCTFail("find.matchCount label not found")
        }
        XCTAssertEqual(matchCountLabel.stringValue, "1 of 3")

        _ = controller.control(
            NSControl(),
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )
        XCTAssertEqual(controller.viewport.selectedUTF8Range, 8..<11)
        XCTAssertEqual(matchCountLabel.stringValue, "2 of 3")

        _ = controller.control(
            NSControl(),
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.moveUp(_:))
        )
        XCTAssertEqual(controller.viewport.selectedUTF8Range, 0..<3)
        XCTAssertEqual(matchCountLabel.stringValue, "1 of 3")
    }

    func testHidingFindBarClearsProjectedMinimapMatches() throws {
        let controller = makeController(text: "foo bar foo")
        controller.toggleFindBar()
        let findField = try XCTUnwrap(
            controller.view.firstDescendant(withIdentifier: "find.query")
                as? NSSearchField
        )
        findField.stringValue = "foo"
        controller.controlTextDidChange(Notification(name: .init("test")))
        XCTAssertEqual(controller.activeMinimapMarkers.findMatches, [0..<3, 8..<11])

        controller.toggleFindBar()

        XCTAssertFalse(controller.isFindBarShown)
        XCTAssertTrue(controller.activeMinimapMarkers.findMatches.isEmpty)
        XCTAssertEqual(controller.captureFindState().query, "foo")
    }

    func testFindMatchCaseNarrowsResults() throws {
        let controller = makeController(text: "Foo foo FOO")
        controller.toggleFindBar()

        guard let findField = controller.view.firstDescendant(withIdentifier: "find.query") as? NSSearchField,
              let matchCaseButton = controller.view.firstDescendant(withIdentifier: "find.matchCase") as? NSButton,
              let matchCountLabel = controller.view.firstDescendant(withIdentifier: "find.matchCount") as? NSTextField
        else {
            return XCTFail("find bar controls not found")
        }

        findField.stringValue = "foo"
        controller.controlTextDidChange(Notification(name: .init("test")))
        XCTAssertEqual(matchCountLabel.stringValue, "1 of 3")

        matchCaseButton.state = .on
        matchCaseButton.sendAction(matchCaseButton.action, to: matchCaseButton.target)
        XCTAssertEqual(matchCountLabel.stringValue, "1 of 1")
        XCTAssertEqual(controller.viewport.selectedUTF8Range, 4..<7)
    }

    func testFindInvalidRegexReportsNoResultsWithoutCrashing() throws {
        let controller = makeController(text: "foo bar")
        controller.toggleFindBar()

        guard let findField = controller.view.firstDescendant(withIdentifier: "find.query") as? NSSearchField,
              let regexButton = controller.view.firstDescendant(withIdentifier: "find.regex") as? NSButton,
              let matchCountLabel = controller.view.firstDescendant(withIdentifier: "find.matchCount") as? NSTextField
        else {
            return XCTFail("find bar controls not found")
        }

        regexButton.state = .on
        regexButton.sendAction(regexButton.action, to: regexButton.target)
        findField.stringValue = "foo("
        controller.controlTextDidChange(Notification(name: .init("test")))

        XCTAssertEqual(matchCountLabel.stringValue, "No Results")
    }

    func testGoToLineSelectsClampedLineAndScrolls() throws {
        let controller = makeController(text: "one\ntwo\nthree\nfour\nfive")

        controller.goToLine(3)
        XCTAssertEqual(controller.viewport.selectedUTF8Range, 8..<13)

        controller.goToLine(0)
        XCTAssertEqual(controller.viewport.selectedUTF8Range, 0..<3)

        controller.goToLine(999)
        XCTAssertEqual(controller.viewport.selectedUTF8Range, 19..<23)
    }

    func testNavigationAnchorCaptureAndRestoreRoundTrips() throws {
        let controller = makeController(text: String(repeating: "line of text\n", count: 200))
        try controller.viewport.selectUTF8Range(5..<9)
        controller.viewport.scrollSourceLineToTop(42)

        let anchor = controller.captureNavigationAnchor()
        XCTAssertEqual(anchor.selection, 5..<9)
        XCTAssertEqual(anchor.viewportAnchorLine, 42)

        try controller.viewport.selectUTF8Range(100..<110)
        controller.viewport.scrollSourceLineToTop(0)

        controller.restoreNavigationAnchor(selection: anchor.selection, viewportAnchorLine: anchor.viewportAnchorLine)
        XCTAssertEqual(controller.viewport.selectedUTF8Range, 5..<9)
        XCTAssertEqual(controller.viewport.topmostVisibleLine, 42)
    }

    func testNavigationAnchorCaptureBeforeHostingUsesTheFirstLine() {
        let snapshot = SourceSnapshot(text: "first\nsecond\n")
        let controller = CodeDocumentViewController(snapshot: snapshot)

        XCTAssertEqual(controller.captureNavigationAnchor().viewportAnchorLine, 0)
    }

    func testMinimapOverlaysContentAndKeepsVerticalScrollerOnItsRight() throws {
        let controller = makeController(text: String(repeating: "line\n", count: 100))
        let scrollView = try XCTUnwrap(
            controller.view.firstDescendant(ofType: NSScrollView.self)
        )
        let minimap = try XCTUnwrap(
            controller.view.firstDescendant(withIdentifier: "code.minimap")
        )
        let verticalScroller = try XCTUnwrap(scrollView.verticalScroller)
        let verticalScrollerFrame = controller.view.convert(
            verticalScroller.bounds,
            from: verticalScroller
        )

        XCTAssertTrue(controller.isMinimapVisible)
        XCTAssertEqual(controller.reservedMinimapWidth, 0)
        XCTAssertEqual(scrollView.frame.maxX, controller.view.bounds.maxX, accuracy: 0.5)
        XCTAssertEqual(minimap.frame.maxX, verticalScrollerFrame.minX, accuracy: 0.5)
        XCTAssertEqual(
            minimap.frame.intersection(scrollView.frame).width,
            minimap.frame.width,
            accuracy: 0.5
        )

        controller.minimapEnabled = false
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(controller.isMinimapVisible)
        XCTAssertEqual(controller.reservedMinimapWidth, 0)

        controller.minimapEnabled = true
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.isMinimapVisible)
        XCTAssertEqual(controller.reservedMinimapWidth, 0)
    }

    func testDiagnosticMarkersRejectWrongSnapshotAndAcceptCurrentSnapshot() {
        let controller = makeController(text: "alpha\nbeta\n")
        let marker = CodeMinimapDiagnosticMarker(utf8Range: 0..<5, severity: .error)

        XCTAssertFalse(controller.applyDiagnosticMarkers([marker], snapshotVersion: 999))
        XCTAssertTrue(controller.applyDiagnosticMarkers(
            [marker],
            snapshotVersion: controller.snapshot.version
        ))
        XCTAssertEqual(controller.activeMinimapMarkers.diagnostics, [marker])
        controller.clearDiagnosticMarkers()
        XCTAssertTrue(controller.activeMinimapMarkers.diagnostics.isEmpty)
    }

    func testGitMarkersFlowFromViewportIntoMinimapOverlay() {
        let controller = makeController(text: "alpha\nbeta\n")
        let change = CodeGutterChange(
            id: "modified",
            kind: .modified,
            layer: .secondary,
            location: .lines(1..<2),
            accessibilityLabel: "Modified"
        )

        XCTAssertTrue(controller.viewport.applyGutterChanges(
            [change],
            snapshotVersion: controller.snapshot.version,
            layerVersion: 1
        ))
        XCTAssertEqual(controller.activeMinimapMarkers.gitChanges, [change])
    }
}
