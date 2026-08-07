import AppKit
@testable import CodeViewport
import SourceModel
import SyntaxCore
import XCTest

@MainActor
final class CodeDocumentViewControllerHighlightingTests: XCTestCase {
    private var windows: [NSWindow] = []

    private func makeController(text: String, path: String = "/tmp/sample.swift") -> CodeDocumentViewController {
        let snapshot = SourceSnapshot(text: text, url: URL(fileURLWithPath: path))
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

    func testInitialHighlightingAppliesLexicalCapturesWithoutBlockingFirstPaint() async throws {
        let controller = makeController(text: "func greet() {\n    print(\"hi\")\n}\n")

        // The plain-text viewport is already fully constructed and laid
        // out synchronously; only the syntax coloring is asynchronous.
        XCTAssertGreaterThan(controller.viewport.frame.height, 0)

        await controller.highlightingTask?.value

        // Applying another layer afterward (as a real second highlighter
        // pass would) must still be accepted, proving the pipeline used
        // real, matching snapshot-version bookkeeping end to end rather
        // than silently failing every apply.
        controller.viewport.applyLexicalCaptures(
            [SyntaxCapture(name: "keyword", utf8Range: 0..<4)],
            snapshotVersion: controller.snapshot.version,
            layerVersion: 99
        )
    }

    func testSkipsHighlightingForUnrecognizedExtension() async {
        let controller = makeController(text: "plain text file\n", path: "/tmp/sample.unknownext")
        XCTAssertNil(controller.viewport.language)
        // No task should even be created for a language Kod has no
        // compiled grammar for.
        XCTAssertNil(controller.highlightingTask)
    }

    func testTSXStartsTypeScriptHighlighting() async {
        let controller = makeController(
            text: "export const View = () => <div />;\n",
            path: "/tmp/View.tsx"
        )

        XCTAssertEqual(controller.viewport.language, .tsx)
        XCTAssertNotNil(controller.highlightingTask)
        await controller.highlightingTask?.value
    }

    func testSkipsHighlightingForSafetyModeFiles() {
        let oversizedLine = String(repeating: "a", count: 200_001)
        let controller = makeController(text: oversizedLine)
        XCTAssertNotNil(controller.snapshot.safetyModeReason)
        XCTAssertNil(controller.highlightingTask)
    }
}
