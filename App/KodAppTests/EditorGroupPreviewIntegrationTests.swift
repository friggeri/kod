import AppKit
import CoreGraphics
import ImageIO
import PreviewCore
import SourceModel
import WorkspaceCore
import XCTest
@testable import Kod

/// Headless integration coverage for SPEC 10's "Integrate preview tabs
/// into the existing workspace/editor system without weakening tab/
/// split/history/restoration/read-only behavior": `EditorGroupViewController`
/// dispatches a tab's content to the right built-in preview (or the
/// unchanged `CodeDocumentViewController` source view) based on detected
/// content, and the Source/Preview toggle switches between them without
/// losing or duplicating any tab-model state. No window is made key and
/// no real click/keyboard event is synthesized — matching this project's
/// permanent headless-only App-layer testing style.
@MainActor
final class EditorGroupPreviewIntegrationTests: XCTestCase {
    private var windows: [NSWindow] = []

    private func host(_ controller: EditorGroupViewController) {
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
    }

    private func findView(identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier {
            return view
        }
        return view.subviews.lazy.compactMap {
            self.findView(identifier: identifier, in: $0)
        }.first
    }

    func testMarkdownTabDefaultsToPreviewModeAndCanToggleToSource() async throws {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)

        let snapshot = SourceSnapshot(text: "# Title\n\nSome text.", url: URL(fileURLWithPath: "/workspace/README.md"), version: 1)
        controller.openTab(relativePath: "README.md", pinned: true, snapshot: snapshot)

        let tabID = try XCTUnwrap(controller.state.selectedTabID)
        XCTAssertEqual(controller.previewKind(forTabID: tabID), .markdown)

        // The preview controller builds asynchronously (it goes through
        // the real `SyntaxEngine` actor for fenced-code highlighting);
        // poll briefly for it to become available rather than assuming a
        // fixed delay.
        try await waitUntil { controller.previewController(forTabID: tabID) != nil }

        XCTAssertEqual(controller.displayedContentKind(forTabID: tabID), .preview)
        XCTAssertEqual(controller.previewSourceControlState, .showingPreview)
        XCTAssertNil(
            findView(identifier: "editorGroup.previewSourceToggle", in: controller.view),
            "The source/preview control belongs to the window toolbar, not a pane header"
        )

        controller.togglePreviewSourceForTesting()
        XCTAssertEqual(controller.displayedContentKind(forTabID: tabID), .source)
        XCTAssertEqual(controller.previewSourceControlState, .showingSource)
        // The source `CodeDocumentViewController` must still exist and be
        // fully functional — toggling to Preview never tore it down.
        XCTAssertNotNil(controller.currentDocumentController)

        controller.togglePreviewSourceForTesting()
        XCTAssertEqual(controller.displayedContentKind(forTabID: tabID), .preview)
        XCTAssertEqual(controller.previewSourceControlState, .showingPreview)
    }

    func testJSONTabGetsStructuredDataPreview() async throws {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)

        let snapshot = SourceSnapshot(text: #"{"a": 1}"#, url: URL(fileURLWithPath: "/workspace/data.json"), version: 1)
        controller.openTab(relativePath: "data.json", pinned: true, snapshot: snapshot)
        let tabID = try XCTUnwrap(controller.state.selectedTabID)

        XCTAssertEqual(controller.previewKind(forTabID: tabID), .structuredData)
        try await waitUntil { controller.previewController(forTabID: tabID)?.structuredDataController != nil }
    }

    func testPlainSwiftFileHasNoPreviewToggle() async throws {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)

        let snapshot = SourceSnapshot(text: "let x = 1\n", url: URL(fileURLWithPath: "/workspace/main.swift"), version: 1)
        controller.openTab(relativePath: "main.swift", pinned: true, snapshot: snapshot)
        let tabID = try XCTUnwrap(controller.state.selectedTabID)

        XCTAssertEqual(controller.previewKind(forTabID: tabID), PreviewKind.none)
        XCTAssertEqual(controller.displayedContentKind(forTabID: tabID), .source)
        XCTAssertNil(controller.previewController(forTabID: tabID))
        XCTAssertEqual(controller.previewSourceControlState, .unavailable)
    }

    func testReplacingPreviewTabCannotShowThePreviousFilesAsyncPreview() async throws {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)

        controller.openTab(
            relativePath: "README.md",
            pinned: false,
            snapshot: SourceSnapshot(text: "# Old Markdown")
        )
        let reusedTabID = try XCTUnwrap(controller.state.selectedTabID)

        controller.openTab(
            relativePath: "new.txt",
            pinned: false,
            snapshot: SourceSnapshot(text: "new contents")
        )
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(controller.state.tabs.count, 1)
        XCTAssertEqual(controller.state.selectedTabID, reusedTabID)
        XCTAssertEqual(controller.state.tabs.first?.relativePath, "new.txt")
        XCTAssertEqual(controller.currentDocumentController?.snapshot.text, "new contents")
        XCTAssertNil(controller.previewController(forTabID: reusedTabID))
        XCTAssertEqual(controller.displayedContentKind(forTabID: reusedTabID), .source)
    }

    func testImageFileOpensAsPreviewOnlyTabViaRawDataFallback() async throws {
        var initialState = EditorGroupState()
        let tabID = initialState.openTab(relativePath: "icon.png", pinned: true)
        initialState.selectedTabID = tabID

        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: initialState)
        let imageData = try PreviewTestImageFixture.makePNG(width: 6, height: 6)
        controller.loadSnapshot = { _ in
            // A PNG is not valid UTF-8 text; `SourceSnapshotLoader` would
            // genuinely throw `.unsupportedEncoding` here in production —
            // this test reproduces that exact failure without touching
            // the real filesystem.
            throw SourceSnapshotError.unsupportedEncoding(URL(fileURLWithPath: "/workspace/icon.png"))
        }
        controller.loadRawData = { _ in imageData }
        host(controller) // triggers viewDidLoad -> restoreIfNeeded -> loadAndShow

        try await waitUntil { controller.previewController(forTabID: tabID) != nil }

        XCTAssertEqual(controller.displayedContentKind(forTabID: tabID), .preview)
        XCTAssertEqual(controller.previewKind(forTabID: tabID), .image(.png))
        XCTAssertNil(controller.currentDocumentController, "a binary image tab must never get a CodeDocumentViewController")
    }

    // MARK: - Helpers

    private struct PreviewIntegrationTimeoutError: Error {}

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ predicate: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline {
                throw PreviewIntegrationTimeoutError()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
