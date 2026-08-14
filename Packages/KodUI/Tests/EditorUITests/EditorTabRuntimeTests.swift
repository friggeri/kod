import AppKit
import CodeViewport
import FontCore
import GitCore
import GitUI
import KodUIComponents
import PreviewCore
import PreviewUI
import SourceModel
import ThemeCore
import WorkspaceCore
import XCTest
@testable import EditorUI

/// Headless coverage for the one-runtime-per-tab model that replaced
/// `EditorGroupViewController`'s parallel per-tab controller/preview/diff
/// dictionaries and boolean flag sets: every state a tab can be in is one
/// `EditorTabContent` case, every content replacement goes through a single
/// teardown path, a document close is emitted only when source content is
/// actually discarded, and a tab dragged between split panes carries the
/// *same* runtime rather than being closed and reopened. No window is made
/// key and no real mouse/keyboard event is synthesized, matching this
/// project's permanent headless-only AppKit testing style.
@MainActor
final class EditorTabRuntimeTests: XCTestCase {
    // MARK: - Fixtures

    private var testingAppearance: AppearanceCenter.Snapshot {
        AppearanceCenter.Snapshot(
            theme: BundledThemes.dark,
            fontSettings: .default
        )
    }

    private func makeDocument(
        text: String = "hello",
        path: String = "/workspace/a.txt"
    ) -> CodeDocumentViewController {
        CodeDocumentViewController(
            snapshot: SourceSnapshot(text: text, url: URL(fileURLWithPath: path), version: 1)
        )
    }

    /// A real `PreviewViewController`, built through the same factory the
    /// app uses. JSON is chosen deliberately: its build has no syntax-engine
    /// round trip, so a test never has to guess at timing.
    private func makePreview() async throws -> PreviewViewController {
        let appearance = testingAppearance
        let preview = await PreviewViewController.make(
            kind: .structuredData,
            data: Data(#"{"a": 1}"#.utf8),
            theme: appearance.theme,
            fontSettings: appearance.fontSettings,
            isWorkspaceTrusted: { false }
        )
        return try XCTUnwrap(preview)
    }

    private func buildPreview(
        on runtime: EditorTabRuntime,
        kind: PreviewKind = .structuredData,
        data: Data = Data(#"{"a": 1}"#.utf8)
    ) async throws {
        let appearance = testingAppearance
        var readyRuntimes: [ObjectIdentifier] = []
        runtime.buildPreview(
            kind: kind,
            data: data,
            theme: appearance.theme,
            fontSettings: appearance.fontSettings,
            isWorkspaceTrusted: { false },
            openLocalRelativePath: nil
        ) { readyRuntimes.append(ObjectIdentifier($0)) }
        try await waitUntil { runtime.previewController != nil }
        XCTAssertEqual(readyRuntimes, [ObjectIdentifier(runtime)])
    }

    private func caseName(_ content: EditorTabContent) -> String {
        switch content {
        case .loading:
            return "loading"
        case .source:
            return "source"
        case .sourceWithPreview:
            return "sourceWithPreview"
        case .imagePreview:
            return "imagePreview"
        case .diff:
            return "diff"
        case .quickDiff:
            return "quickDiff"
        case .tombstone:
            return "tombstone"
        }
    }

    // MARK: - Every content case

    func testLoadingRuntimeOwnsNothing() {
        let runtime = EditorTabRuntime(relativePath: "a.txt")

        XCTAssertEqual(caseName(runtime.content), "loading")
        XCTAssertNil(runtime.displayedController)
        XCTAssertNil(runtime.sourceDocument)
        XCTAssertNil(runtime.previewController)
        XCTAssertNil(runtime.previewKind)
        XCTAssertEqual(runtime.previewSourceControlState, .unavailable)
        XCTAssertTrue(runtime.discardContent().isEmpty, "nothing was open, so nothing can close")
    }

    func testSourceRuntimeShowsItsDocument() {
        let runtime = EditorTabRuntime(relativePath: "a.txt")
        let document = makeDocument()

        XCTAssertTrue(runtime.showSource(document).isEmpty)

        XCTAssertEqual(caseName(runtime.content), "source")
        XCTAssertTrue(runtime.displayedController === document)
        XCTAssertTrue(runtime.sourceDocument === document)
        XCTAssertTrue(runtime.focusedSourceDocument === document)
        XCTAssertTrue(runtime.visibleSourceDocument === document)
        XCTAssertEqual(runtime.previewSourceControlState, .unavailable)
    }

    func testSourceWithPreviewKeepsBothSidesAliveAcrossTheToggle() async throws {
        let runtime = EditorTabRuntime(relativePath: "data.json")
        let document = makeDocument(text: #"{"a": 1}"#, path: "/workspace/data.json")
        runtime.showSource(document)

        try await buildPreview(on: runtime)

        XCTAssertEqual(caseName(runtime.content), "sourceWithPreview")
        XCTAssertEqual(runtime.previewKind, .structuredData)
        XCTAssertTrue(runtime.prefersPreview, "a previewable tab opens in preview mode")
        XCTAssertTrue(runtime.displayedController === runtime.previewController)
        XCTAssertEqual(runtime.previewSourceControlState, .showingPreview)
        XCTAssertNil(runtime.visibleSourceDocument, "the source view is not what is on screen")

        runtime.togglePrefersPreview()

        XCTAssertTrue(runtime.displayedController === document, "toggling never tears the source view down")
        XCTAssertTrue(runtime.visibleSourceDocument === document)
        XCTAssertEqual(runtime.previewSourceControlState, .showingSource)
        XCTAssertNotNil(runtime.previewController, "the built preview survives a toggle to Source")

        runtime.togglePrefersPreview()
        XCTAssertEqual(runtime.previewSourceControlState, .showingPreview)
    }

    func testImagePreviewRuntimeHasNoSourceSideAndIgnoresTheToggle() async throws {
        let runtime = EditorTabRuntime(relativePath: "icon.png")
        let preview = try await makePreview()

        XCTAssertTrue(runtime.showImagePreview(preview, kind: .image(.png)).isEmpty)

        XCTAssertEqual(caseName(runtime.content), "imagePreview")
        XCTAssertTrue(runtime.isImageOnly)
        XCTAssertTrue(runtime.displayedController === preview)
        XCTAssertNil(runtime.sourceDocument, "binary image bytes have no source view at all")
        XCTAssertEqual(runtime.previewSourceControlState, .previewOnly)

        runtime.togglePrefersPreview()

        XCTAssertTrue(runtime.displayedController === preview)
        XCTAssertEqual(runtime.previewSourceControlState, .previewOnly)
    }

    func testImagePreviewReportsAnyDiscardedSourceDocumentClosed() async throws {
        let runtime = EditorTabRuntime(relativePath: "icon.png")
        let document = makeDocument(path: "/workspace/icon.png")
        runtime.showSource(document)
        let preview = try await makePreview()

        let discarded = runtime.showImagePreview(preview, kind: .image(.png))

        XCTAssertEqual(discarded.count, 1)
        XCTAssertTrue(discarded.first === document)
    }

    func testDiffRetainsTheSourceItWasLayeredOverWithoutDiscardingIt() {
        let runtime = EditorTabRuntime(relativePath: "a.txt")
        let document = makeDocument()
        runtime.showSource(document)
        let diffController = GitDiffViewController()

        runtime.showDiff(diffController)

        XCTAssertEqual(caseName(runtime.content), "diff")
        XCTAssertTrue(runtime.displayedController === diffController)
        XCTAssertTrue(runtime.sourceDocument === document, "the source stays alive underneath the diff")
        XCTAssertNil(runtime.focusedSourceDocument, "Find/Go to Line must not target a diff's hidden source")
        XCTAssertEqual(runtime.previewSourceControlState, .unavailable)

        runtime.dismissDiff()

        XCTAssertEqual(caseName(runtime.content), "source")
        XCTAssertTrue(runtime.displayedController === document, "returning from a diff reuses the same source view")
    }

    func testQuickDiffRetainsSourceAndNeverReportsItsVirtualDocumentClosed() {
        let runtime = EditorTabRuntime(relativePath: "a.txt")
        let document = makeDocument()
        runtime.showSource(document)
        let quickDiffDocument = makeDocument(text: "hello there")
        let quickDiffController = GitQuickDiffController(documentController: quickDiffDocument)

        runtime.showQuickDiff(document: quickDiffDocument, controller: quickDiffController)

        XCTAssertEqual(caseName(runtime.content), "quickDiff")
        XCTAssertTrue(runtime.displayedController === quickDiffDocument)
        XCTAssertTrue(runtime.sourceDocument === document)
        XCTAssertNil(runtime.focusedSourceDocument)
        XCTAssertTrue(runtime.showsQuickDiff)
        XCTAssertEqual(runtime.previewSourceControlState, .unavailable)

        let discarded = runtime.discardContent()

        XCTAssertEqual(discarded.count, 1, "only the real source document is ever reported closed")
        XCTAssertTrue(discarded.first === document)
        XCTAssertEqual(caseName(runtime.content), "loading")
    }

    func testTombstoneDiscardsEverythingExactlyOnce() {
        let runtime = EditorTabRuntime(relativePath: "a.txt")
        let document = makeDocument()
        runtime.showSource(document)

        let discarded = runtime.markTombstoned(reason: .missing)

        XCTAssertEqual(caseName(runtime.content), "tombstone")
        XCTAssertTrue(runtime.isTombstoned)
        XCTAssertEqual(discarded.count, 1)
        XCTAssertTrue(discarded.first === document)
        XCTAssertNil(runtime.displayedController)
        XCTAssertNil(runtime.previewKind)
        XCTAssertTrue(
            runtime.discardContent().isEmpty,
            "a tombstoned tab has nothing left to close a second time"
        )

        runtime.prepareForReload()
        XCTAssertEqual(caseName(runtime.content), "loading")
    }

    // MARK: - Replacement

    func testReplacingTheSourceDocumentReturnsTheSupersededOne() {
        let runtime = EditorTabRuntime(relativePath: "a.txt")
        let original = makeDocument()
        runtime.showSource(original)
        let replacement = makeDocument(text: "hello there")

        let superseded = runtime.replaceSourceDocument(with: replacement)

        XCTAssertTrue(superseded === original)
        XCTAssertTrue(runtime.sourceDocument === replacement)
        XCTAssertEqual(caseName(runtime.content), "source")
    }

    func testReplacingTheSourceDocumentUnderAQuickDiffKeepsTheQuickDiffVisible() {
        let runtime = EditorTabRuntime(relativePath: "a.txt")
        let original = makeDocument()
        runtime.showSource(original)
        let quickDiffDocument = makeDocument(text: "hello there")
        runtime.showQuickDiff(
            document: quickDiffDocument,
            controller: GitQuickDiffController(documentController: quickDiffDocument)
        )
        let replacement = makeDocument(text: "hello again")

        let superseded = runtime.replaceSourceDocument(with: replacement)

        XCTAssertTrue(superseded === original)
        XCTAssertEqual(caseName(runtime.content), "quickDiff")
        XCTAssertTrue(runtime.displayedController === quickDiffDocument)
        XCTAssertTrue(runtime.sourceDocument === replacement)
    }

    func testReopeningTheSameSourceDocumentDiscardsNothing() async throws {
        let runtime = EditorTabRuntime(relativePath: "data.json")
        let document = makeDocument(text: #"{"a": 1}"#, path: "/workspace/data.json")
        runtime.showSource(document)
        try await buildPreview(on: runtime)
        let preview = try XCTUnwrap(runtime.previewController)

        XCTAssertTrue(runtime.showSource(document).isEmpty)

        XCTAssertEqual(caseName(runtime.content), "sourceWithPreview")
        XCTAssertTrue(runtime.previewController === preview, "a still-valid preview is not rebuilt")
    }

    func testNonPreviewableContentDropsAnyPreviewTheTabWasCarrying() async throws {
        let runtime = EditorTabRuntime(relativePath: "data.json")
        runtime.showSource(makeDocument(text: #"{"a": 1}"#, path: "/workspace/data.json"))
        try await buildPreview(on: runtime)

        runtime.buildPreview(
            kind: .none,
            data: Data("let x = 1\n".utf8),
            theme: testingAppearance.theme,
            fontSettings: testingAppearance.fontSettings,
            isWorkspaceTrusted: { false },
            openLocalRelativePath: nil
        ) { _ in XCTFail("`.none` never builds a preview") }

        XCTAssertEqual(caseName(runtime.content), "source")
        XCTAssertNil(runtime.previewController)
        XCTAssertFalse(runtime.prefersPreview)
        XCTAssertEqual(runtime.previewKind, PreviewKind.none)
        XCTAssertEqual(runtime.previewSourceControlState, .unavailable)
    }

    func testDiscardingContentCancelsAnInFlightPreviewBuild() async throws {
        let runtime = EditorTabRuntime(relativePath: "data.json")
        runtime.showSource(makeDocument(text: #"{"a": 1}"#, path: "/workspace/data.json"))

        runtime.buildPreview(
            kind: .structuredData,
            data: Data(#"{"a": 1}"#.utf8),
            theme: testingAppearance.theme,
            fontSettings: testingAppearance.fontSettings,
            isWorkspaceTrusted: { false },
            openLocalRelativePath: nil
        ) { _ in XCTFail("a discarded tab must never receive its preview") }
        runtime.discardContent()

        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(caseName(runtime.content), "loading")
        XCTAssertNil(runtime.previewController)
        XCTAssertNil(runtime.previewKind)
    }

    // MARK: - Store ownership

    func testStoreKeepsExactlyOneRuntimePerTabAndHandsItOverIntact() {
        var source = EditorTabRuntimeStore()
        var destination = EditorTabRuntimeStore()
        let tabID = EditorTabID()

        let runtime = source.runtime(for: tabID, relativePath: "a.txt")
        XCTAssertTrue(source.runtime(for: tabID, relativePath: "a.txt") === runtime, "one runtime per tab ID")
        XCTAssertTrue(source.owns(runtime, for: tabID))
        XCTAssertEqual(source.all.count, 1)

        let detached = source.remove(tabID)

        XCTAssertTrue(detached === runtime)
        XCTAssertFalse(source.owns(runtime, for: tabID))
        XCTAssertNil(source[tabID])

        XCTAssertNil(destination.adopt(runtime, for: tabID))
        XCTAssertTrue(destination[tabID] === runtime)
        XCTAssertTrue(destination.owns(runtime, for: tabID))
        XCTAssertEqual(destination.removeAll().count, 1)
        XCTAssertNil(destination[tabID])
    }

    // MARK: - Helpers

    private struct RuntimeTimeoutError: Error {}

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ predicate: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline {
                throw RuntimeTimeoutError()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// Headless coverage for how `EditorGroupViewController` drives those
/// runtimes: which content case each open path produces, that closing or
/// permanently replacing a tab reports exactly the documents it discarded,
/// and that dragging a tab into another split group moves the same live
/// runtime instead of closing and reopening the file.
@MainActor
final class EditorGroupTabRuntimeTests: XCTestCase {
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

    private func caseName(_ content: EditorTabContent?) -> String {
        guard let content else {
            return "nil"
        }
        switch content {
        case .loading:
            return "loading"
        case .source:
            return "source"
        case .sourceWithPreview:
            return "sourceWithPreview"
        case .imagePreview:
            return "imagePreview"
        case .diff:
            return "diff"
        case .quickDiff:
            return "quickDiff"
        case .tombstone:
            return "tombstone"
        }
    }

    private func makeDiff() -> GitFileDiff {
        GitFileDiff(
            change: GitDiffFileChange(kind: .modified, oldPath: nil, newPath: "a.txt"),
            content: .text(hunks: [
                GitDiffHunk(
                    oldStart: 1, oldCount: 1, newStart: 1, newCount: 1,
                    sectionHeading: nil,
                    lines: [
                        GitDiffLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "hello")
                    ]
                )
            ])
        )
    }

    /// One tab walking through source → full diff → quick diff → tombstone,
    /// with each step asserted as the single content case it should be. The
    /// Git views layer over the source rather than discarding it, so the
    /// only close reported in the whole sequence is the tombstone's.
    func testOneTabMovesThroughItsContentCasesWithASingleClose() throws {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)
        var closedPaths: [String] = []
        controller.onDocumentClosed = { path, _ in closedPaths.append(path) }

        controller.openTab(relativePath: "a.txt", pinned: true, snapshot: SourceSnapshot(text: "hello"))
        let tabID = try XCTUnwrap(controller.state.selectedTabID)
        let document = try XCTUnwrap(controller.currentDocumentController)
        XCTAssertEqual(caseName(controller.content(forTabID: tabID)), "source")
        XCTAssertEqual(controller.displayedContentKind(forTabID: tabID), .source)

        controller.openDiffTab(relativePath: "a.txt", diff: makeDiff())
        XCTAssertEqual(caseName(controller.content(forTabID: tabID)), "diff")
        XCTAssertEqual(controller.displayedContentKind(forTabID: tabID), .diff)
        XCTAssertNil(controller.currentDocumentController, "a diff tab has no focused source view")
        XCTAssertNotNil(controller.diffController(forTabID: tabID))

        controller.openQuickDiffTab(
            relativePath: "a.txt",
            snapshot: SourceSnapshot(text: "hello there"),
            sources: [],
            revealFirstHunk: false
        )
        XCTAssertEqual(caseName(controller.content(forTabID: tabID)), "quickDiff")
        XCTAssertEqual(controller.displayedContentKind(forTabID: tabID), .quickDiff)
        XCTAssertNotNil(controller.currentQuickDiffController)
        XCTAssertTrue(closedPaths.isEmpty, "layering Git views over source discards nothing: \(closedPaths)")

        controller.openTab(relativePath: "a.txt", pinned: true, snapshot: SourceSnapshot(text: "hello"))
        XCTAssertEqual(caseName(controller.content(forTabID: tabID)), "source")
        XCTAssertTrue(
            controller.currentDocumentController === document,
            "returning to source reuses the retained live document"
        )
        XCTAssertTrue(closedPaths.isEmpty, "the source view was never discarded: \(closedPaths)")

        controller.markTombstoned(relativePath: "a.txt", reason: .missing)
        XCTAssertEqual(caseName(controller.content(forTabID: tabID)), "tombstone")
        XCTAssertEqual(
            controller.displayedContentKind(forTabID: tabID),
            EditorGroupViewController.DisplayedContentKind.none
        )
        XCTAssertEqual(closedPaths, ["a.txt"])
    }

    func testClosingATabRemovesItsRuntimeEntirely() throws {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)
        controller.openTab(relativePath: "a.txt", pinned: true, snapshot: SourceSnapshot(text: "hello"))
        let tabID = try XCTUnwrap(controller.state.selectedTabID)

        controller.closeTab(tabID)

        XCTAssertNil(controller.content(forTabID: tabID), "a closed tab keeps no runtime at all")
        XCTAssertEqual(
            controller.displayedContentKind(forTabID: tabID),
            EditorGroupViewController.DisplayedContentKind.none
        )
        XCTAssertNil(controller.previewKind(forTabID: tabID))
        XCTAssertNil(controller.currentDocumentController)
    }

    func testReusingThePreviewTabReplacesTheRuntimeWithOneForTheNewFile() throws {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)
        controller.openTab(relativePath: "a.txt", pinned: false, snapshot: SourceSnapshot(text: "hello"))
        let tabID = try XCTUnwrap(controller.state.selectedTabID)
        let original = try XCTUnwrap(controller.currentDocumentController)
        var closed: [(path: String, id: ObjectIdentifier)] = []
        controller.onDocumentClosed = { path, document in
            closed.append((path: path, id: ObjectIdentifier(document)))
        }

        controller.openTab(relativePath: "b.txt", pinned: false, snapshot: SourceSnapshot(text: "goodbye"))

        XCTAssertEqual(controller.state.selectedTabID, tabID, "the preview tab keeps its identity")
        XCTAssertEqual(caseName(controller.content(forTabID: tabID)), "source")
        XCTAssertFalse(
            controller.currentDocumentController === original,
            "the reused tab shows the new file's document"
        )
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed.first?.path, "a.txt", "closed under the path it was actually showing")
        XCTAssertEqual(closed.first?.id, ObjectIdentifier(original))
    }

    func testTombstoneThenClearReloadsTheSameTab() async throws {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        controller.loadSnapshot = { _ in SourceSnapshot(text: "back again", version: 2) }
        host(controller)
        controller.openTab(relativePath: "a.txt", pinned: true, snapshot: SourceSnapshot(text: "hello"))
        let tabID = try XCTUnwrap(controller.state.selectedTabID)

        controller.markTombstoned(relativePath: "a.txt", reason: .missing)
        XCTAssertEqual(caseName(controller.content(forTabID: tabID)), "tombstone")

        controller.clearTombstone(relativePath: "a.txt")

        try await waitUntil { controller.currentDocumentController != nil }
        XCTAssertEqual(caseName(controller.content(forTabID: tabID)), "source")
        XCTAssertEqual(controller.currentDocumentController?.snapshot.text, "back again")
        XCTAssertFalse(controller.state.tabs.first?.isTombstoned ?? true)
    }

    func testReloadReplacesTheSourceUnderAQuickDiffWithoutLosingIt() throws {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)
        controller.openTab(relativePath: "a.txt", pinned: true, snapshot: SourceSnapshot(text: "hello"))
        let tabID = try XCTUnwrap(controller.state.selectedTabID)
        controller.openQuickDiffTab(
            relativePath: "a.txt",
            snapshot: SourceSnapshot(text: "hello there"),
            sources: [],
            revealFirstHunk: false
        )
        var readyPaths: [String] = []
        var closedPaths: [String] = []
        controller.onDocumentReady = { path, _ in readyPaths.append(path) }
        controller.onDocumentClosed = { path, _ in closedPaths.append(path) }

        controller.reloadTab(relativePath: "a.txt", with: SourceSnapshot(text: "hello again", version: 2))

        XCTAssertEqual(caseName(controller.content(forTabID: tabID)), "quickDiff", "a reload never dismisses Quick Diff")
        XCTAssertEqual(controller.displayedContentKind(forTabID: tabID), .quickDiff)
        XCTAssertEqual(readyPaths, ["a.txt"])
        XCTAssertEqual(closedPaths, ["a.txt"], "the superseded source document is reported after its replacement")
    }

    /// A full-file diff is a comparison snapshot, not a live view of the
    /// file, so an external change converts that tab back to source — the
    /// deliberate opposite of the Quick Diff case above.
    func testReloadDismissesAFullDiffAndShowsTheRefreshedSource() throws {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)
        controller.openTab(relativePath: "a.txt", pinned: true, snapshot: SourceSnapshot(text: "hello"))
        let tabID = try XCTUnwrap(controller.state.selectedTabID)
        controller.openDiffTab(relativePath: "a.txt", diff: makeDiff())
        XCTAssertEqual(caseName(controller.content(forTabID: tabID)), "diff")

        controller.reloadTab(relativePath: "a.txt", with: SourceSnapshot(text: "hello again", version: 2))

        XCTAssertEqual(caseName(controller.content(forTabID: tabID)), "source")
        XCTAssertEqual(controller.displayedContentKind(forTabID: tabID), .source)
        XCTAssertEqual(controller.currentDocumentController?.snapshot.text, "hello again")
    }

    func testPreviewTabDefaultsToPreviewAndTogglesWithoutRebuildingItsSource() async throws {
        let controller = EditorGroupViewController(
            groupID: EditorGroupID(),
            state: EditorGroupState()
        )
        host(controller)
        controller.openTab(
            relativePath: "data.json",
            pinned: true,
            snapshot: SourceSnapshot(
                text: #"{"a": 1}"#,
                url: URL(fileURLWithPath: "/workspace/data.json"),
                version: 1
            )
        )
        let tabID = try XCTUnwrap(controller.state.selectedTabID)
        let document = try XCTUnwrap(controller.currentDocumentController)

        try await waitUntil { controller.previewController(forTabID: tabID) != nil }

        XCTAssertEqual(caseName(controller.content(forTabID: tabID)), "sourceWithPreview")
        XCTAssertEqual(controller.displayedContentKind(forTabID: tabID), .preview)
        XCTAssertEqual(controller.previewSourceControlState, .showingPreview)

        controller.togglePreviewSourceForTesting()

        XCTAssertEqual(caseName(controller.content(forTabID: tabID)), "sourceWithPreview")
        XCTAssertEqual(controller.displayedContentKind(forTabID: tabID), .source)
        XCTAssertTrue(
            controller.currentDocumentController === document,
            "the source view is the same one, never rebuilt by the toggle"
        )
    }

    /// The whole point of the runtime owning a tab's controllers: a drag
    /// between split panes hands the same runtime over, so the destination
    /// shows the identical document with its preview state intact and the
    /// language service never sees a close/open pair.
    func testTransferringATabMovesTheSameRuntimeWithItsPreviewState() async throws {
        let source = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        let destination = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(source)
        host(destination)
        source.openTab(
            relativePath: "data.json",
            pinned: true,
            snapshot: SourceSnapshot(
                text: #"{"a": 1}"#,
                url: URL(fileURLWithPath: "/workspace/data.json"),
                version: 1
            )
        )
        let tabID = try XCTUnwrap(source.state.selectedTabID)
        try await waitUntil { source.previewController(forTabID: tabID) != nil }
        let document = try XCTUnwrap(source.content(forTabID: tabID)?.sourceSide?.document)
        var events: [String] = []
        source.onDocumentClosed = { _, _ in events.append("source.closed") }
        source.onDocumentReady = { _, _ in events.append("source.ready") }
        destination.onDocumentClosed = { _, _ in events.append("destination.closed") }
        destination.onDocumentReady = { _, _ in events.append("destination.ready") }

        let payload = try XCTUnwrap(source.detachTabForTransfer(tabID))
        destination.insertTransferredTab(payload, at: 0)

        XCTAssertTrue(events.isEmpty, "a live transfer is neither a close nor an open: \(events)")
        XCTAssertNil(source.content(forTabID: tabID), "the source group gave up ownership entirely")
        XCTAssertNil(source.currentDocumentController)
        XCTAssertTrue(
            destination.content(forTabID: tabID)?.sourceSide?.document === document,
            "the destination shows the very same live document"
        )
        XCTAssertEqual(destination.previewKind(forTabID: tabID), .structuredData)
        XCTAssertEqual(destination.displayedContentKind(forTabID: tabID), .preview)
        XCTAssertEqual(destination.previewSourceControlState, .showingPreview)
    }

    /// Dropping a tab onto a group that already has the same file cannot
    /// reattach the transferred runtime — the destination re-identifies the
    /// tab — so that runtime's content is discarded and reported rather
    /// than silently leaked.
    func testTransferOntoAGroupThatAlreadyHasTheFileDiscardsTheTransferredRuntime() throws {
        let source = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        let destination = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(source)
        host(destination)
        source.openTab(relativePath: "a.txt", pinned: true, snapshot: SourceSnapshot(text: "hello"))
        destination.openTab(relativePath: "a.txt", pinned: true, snapshot: SourceSnapshot(text: "hello"))
        let sourceTabID = try XCTUnwrap(source.state.selectedTabID)
        let destinationTabID = try XCTUnwrap(destination.state.selectedTabID)
        let destinationDocument = try XCTUnwrap(destination.currentDocumentController)
        var closedPaths: [String] = []
        destination.onDocumentClosed = { path, _ in closedPaths.append(path) }

        let payload = try XCTUnwrap(source.detachTabForTransfer(sourceTabID))
        let insertedID = destination.insertTransferredTab(payload, at: 0)

        XCTAssertEqual(insertedID, destinationTabID)
        XCTAssertEqual(closedPaths, ["a.txt"], "the transferred runtime's document is closed, not leaked")
        XCTAssertTrue(
            destination.currentDocumentController === destinationDocument,
            "the destination's own tab keeps its live document"
        )
        XCTAssertEqual(destination.state.tabs.count, 1)
    }

    func testRemovingTheGroupFromTheWorkspaceTearsDownEveryRuntime() throws {
        let controller = EditorGroupViewController(groupID: EditorGroupID(), state: EditorGroupState())
        host(controller)
        controller.openTab(relativePath: "a.txt", pinned: true, snapshot: SourceSnapshot(text: "hello"))
        controller.openTab(relativePath: "b.txt", pinned: true, snapshot: SourceSnapshot(text: "goodbye"))
        let tabIDs = controller.state.tabs.map(\.id)
        var closedPaths: [String] = []
        controller.onDocumentClosed = { path, _ in closedPaths.append(path) }

        controller.prepareForRemovalFromWorkspace()

        XCTAssertEqual(Set(closedPaths), ["a.txt", "b.txt"])
        for tabID in tabIDs {
            XCTAssertNil(controller.content(forTabID: tabID))
        }
    }

    // MARK: - Helpers

    private struct RuntimeTimeoutError: Error {}

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ predicate: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline {
                throw RuntimeTimeoutError()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
