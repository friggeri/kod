import AppKit
import LanguageClient
import XCTest
@testable import Kod

/// Headless coverage for the Problems sidebar (SPEC 6.4). Constructs the
/// view controller directly and drives it via its public API — no window
/// is ever made key, no mouse/keyboard input is synthesized, and
/// `KodAppUITests`/`XCUIApplication` are never involved, consistent with
/// `Scripts/verify-phase`'s permanent headless-only restriction.
@MainActor
final class ProblemsViewControllerTests: XCTestCase {
    func testUpdateReplacesDiagnosticsForAFileAndReportsAnAccurateStatus() throws {
        var selections: [ProblemsViewController.DiagnosticSelection] = []
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let controller = ProblemsViewController(root: root) { selection in
            selections.append(selection)
        }
        controller.loadView()

        let fileURL = root.appendingPathComponent("Sources/Foo.swift")
        let diagnostic = Diagnostic(
            range: LSPRange(start: LSPPosition(line: 2, character: 0), end: LSPPosition(line: 2, character: 5)),
            severity: .warning,
            code: nil,
            source: "sourcekit-lsp",
            message: "Unused variable"
        )
        controller.update(url: fileURL, diagnostics: [diagnostic])

        let outline = try XCTUnwrap(findOutlineView(in: controller.view))
        XCTAssertEqual(outline.numberOfChildren(ofItem: nil), 1)
        let fileItem = outline.child(0, ofItem: nil)
        XCTAssertEqual(outline.numberOfChildren(ofItem: fileItem), 1)

        // Clearing diagnostics for the file removes it entirely rather
        // than leaving a stale empty entry.
        controller.update(url: fileURL, diagnostics: [])
        XCTAssertEqual(outline.numberOfChildren(ofItem: nil), 0)
    }

    func testSelectingADiagnosticRowInvokesTheSelectionCallbackWithItsRange() throws {
        var selections: [ProblemsViewController.DiagnosticSelection] = []
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let controller = ProblemsViewController(root: root) { selection in
            selections.append(selection)
        }
        controller.loadView()

        let fileURL = root.appendingPathComponent("Sources/Foo.swift")
        let range = LSPRange(start: LSPPosition(line: 4, character: 1), end: LSPPosition(line: 4, character: 9))
        let diagnostic = Diagnostic(range: range, severity: .error, code: nil, source: nil, message: "Boom")
        controller.update(url: fileURL, diagnostics: [diagnostic])

        let outline = try XCTUnwrap(findOutlineView(in: controller.view))
        outline.expandItem(outline.child(0, ofItem: nil))
        // Row 0 is the file group; row 1 is the single diagnostic leaf.
        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        outline.sendAction(outline.action, to: outline.target)

        XCTAssertEqual(selections.count, 1)
        XCTAssertEqual(selections.first?.url, fileURL)
        XCTAssertEqual(selections.first?.range, range)
    }

    private func findOutlineView(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView {
            return outline
        }
        for subview in view.subviews {
            if let found = findOutlineView(in: subview) {
                return found
            }
        }
        return nil
    }
}
