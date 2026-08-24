import AppKit
import CodeViewport
import FontCore
import GitUI
import PreviewCore
import PreviewUI
import ThemeCore
import WorkspaceCore

public struct EditorStatusDocument {
    public enum ContentKind: Equatable, Sendable {
        case loading
        case source
        case preview
        case previewOnly
        case diff
        case quickDiff
        case tombstone
    }

    public let relativePath: String
    public let contentKind: ContentKind
    public let metadataDocument: CodeDocumentViewController?
    public let cursorDocument: CodeDocumentViewController?

    public init(
        relativePath: String,
        contentKind: ContentKind,
        metadataDocument: CodeDocumentViewController?,
        cursorDocument: CodeDocumentViewController?
    ) {
        self.relativePath = relativePath
        self.contentKind = contentKind
        self.metadataDocument = metadataDocument
        self.cursorDocument = cursorDocument
    }
}

/// Everything one open tab currently *is*, as a single value instead of the
/// several parallel per-tab dictionaries and boolean flag sets
/// `EditorGroupViewController` used to keep in sync by hand (a document
/// controller map, a preview map, a full-diff map, two quick-diff maps, a
/// detected-kind map, and "is in preview mode"/"is image-only" ID sets).
/// Every state a tab can be in is one case here, so an impossible
/// combination — a quick diff with no document, a preview-only tab that also
/// claims a source view, a tombstone still holding live content — cannot be
/// represented at all.
@MainActor
enum EditorTabContent {
    /// The source side of a tab: its `CodeDocumentViewController` and, when
    /// the file's bytes matched a built-in preview format (SPEC 10), the
    /// preview built from them. A text-based preview never replaces the
    /// source view, so toggling to "Source" never has to reload anything.
    struct SourceSide {
        let document: CodeDocumentViewController
        let preview: PreviewViewController?

        init(document: CodeDocumentViewController, preview: PreviewViewController? = nil) {
            self.document = document
            self.preview = preview
        }
    }

    /// The tab exists in the model but owns nothing yet: its snapshot is
    /// still being loaded (or was never loaded, e.g. a tab restored from
    /// persisted state that has not been selected yet).
    case loading
    case source(CodeDocumentViewController)
    case sourceWithPreview(document: CodeDocumentViewController, preview: PreviewViewController)
    /// Raw image and binary-plist bytes are not valid UTF-8 text, so there is
    /// no `CodeDocumentViewController` and no meaningful "Source" side.
    case previewOnly(PreviewViewController)
    /// A full-file Git diff layered over the source view it was opened
    /// from. The source is retained rather than discarded so returning to
    /// it neither reloads the file nor makes the language service churn
    /// through didClose/didOpen for a document that never actually closed.
    case diff(GitDiffViewController, retainedSource: SourceSide?)
    /// Source Control Quick Diff: a *virtual* working/index document with
    /// gutter decorations, layered over the real source view the same way
    /// `diff` is. The quick-diff document is never announced ready to the
    /// language service, so it is never announced closed either.
    case quickDiff(
        document: CodeDocumentViewController,
        controller: GitQuickDiffController,
        retainedSource: SourceSide?
    )
    /// SPEC 5.6: the file was deleted or moved externally. The tab stays
    /// open and selectable, but owns no live content.
    case tombstone(reason: TabTombstoneReason?)

    /// The content that shows `side` directly, with no Git overlay.
    static func displaying(_ side: SourceSide) -> EditorTabContent {
        guard let preview = side.preview else {
            return .source(side.document)
        }
        return .sourceWithPreview(document: side.document, preview: preview)
    }
}

extension EditorTabContent {
    /// The live source view this content is built on, including one
    /// retained underneath a Git diff/quick diff.
    var sourceSide: SourceSide? {
        switch self {
        case .source(let document):
            return SourceSide(document: document)
        case .sourceWithPreview(let document, let preview):
            return SourceSide(document: document, preview: preview)
        case .diff(_, let retainedSource), .quickDiff(_, _, let retainedSource):
            return retainedSource
        case .loading, .previewOnly, .tombstone:
            return nil
        }
    }

    /// The source view only when it is the tab's own content — `nil` while a
    /// Git diff/quick diff is layered on top, matching what Find in File,
    /// Go to Line and navigation-anchor capture are allowed to target.
    var focusedSourceDocument: CodeDocumentViewController? {
        switch self {
        case .source(let document):
            return document
        case .sourceWithPreview(let document, _):
            return document
        case .loading, .previewOnly, .diff, .quickDiff, .tombstone:
            return nil
        }
    }

    var preview: PreviewViewController? {
        switch self {
        case .sourceWithPreview(_, let preview), .previewOnly(let preview):
            return preview
        case .diff(_, let retainedSource), .quickDiff(_, _, let retainedSource):
            return retainedSource?.preview
        case .loading, .source, .tombstone:
            return nil
        }
    }

    var diffController: GitDiffViewController? {
        guard case .diff(let controller, _) = self else {
            return nil
        }
        return controller
    }

    var quickDiffController: GitQuickDiffController? {
        guard case .quickDiff(_, let controller, _) = self else {
            return nil
        }
        return controller
    }

    var quickDiffDocument: CodeDocumentViewController? {
        guard case .quickDiff(let document, _, _) = self else {
            return nil
        }
        return document
    }

    /// Every `CodeDocumentViewController` this content keeps alive, visible
    /// or not — what appearance, word wrap, minimap and diagnostic-marker
    /// updates must reach.
    var documentControllers: [CodeDocumentViewController] {
        var controllers: [CodeDocumentViewController] = []
        if let document = quickDiffDocument {
            controllers.append(document)
        }
        if let document = sourceSide?.document {
            controllers.append(document)
        }
        return controllers
    }

    /// This content with its source side replaced, keeping any Git overlay
    /// exactly as it is — a diff/quick diff stays visible while the source
    /// underneath it is reloaded or has its preview attached/dropped.
    func replacingSourceSide(_ side: SourceSide?) -> EditorTabContent {
        switch self {
        case .diff(let controller, _):
            return .diff(controller, retainedSource: side)
        case .quickDiff(let document, let controller, _):
            return .quickDiff(document: document, controller: controller, retainedSource: side)
        case .loading, .source, .sourceWithPreview, .previewOnly, .tombstone:
            guard let side else {
                return .loading
            }
            return .displaying(side)
        }
    }
}

/// The single owner of one open tab's live content: its child view
/// controllers, its detected preview kind and preview/source choice, and the
/// in-flight preview build that may still be producing one. There is exactly
/// one runtime per `EditorTabID` in a group (see `EditorTabRuntimeStore`),
/// every content change goes through one transition path, and the runtime
/// itself is what moves between split groups when a tab is dragged — which
/// is what makes a cross-pane drag a *move* of live controllers rather than
/// a close followed by a reopen.
@MainActor
final class EditorTabRuntime {
    /// The workspace-relative path this runtime's content belongs to. A tab
    /// re-pointed at a different file (the unpinned preview tab being
    /// reused) does not rename its runtime: the old runtime is torn down and
    /// a new one takes its place, so a document close is always reported
    /// under the path that document was actually showing.
    let relativePath: String
    private(set) var content: EditorTabContent
    /// The `PreviewKind` detected for this tab's content, cached at open/
    /// reload time so repeated display decisions never re-sniff bytes.
    private(set) var previewKind: PreviewKind?
    /// Whether the preview side is preferred whenever both a preview and a
    /// source view exist. A newly detected previewable tab defaults to
    /// `true` (SPEC 10: previewing is the point), with an explicit toggle
    /// back to Source. Transient UI state by design — SPEC 11.7 persists
    /// tabs/selection/scroll, not a once-toggled preview choice.
    private(set) var prefersPreview = false
    private var previewBuildTask: Task<Void, Never>?
    private var previewBuildGeneration = 0

    init(relativePath: String, content: EditorTabContent = .loading) {
        self.relativePath = relativePath
        self.content = content
    }

    deinit {
        // Nonisolated: cancelling a `Task` is the only main-actor-independent
        // work available here. Document closes are reported by the owning
        // group's explicit teardown paths, never from a deinit.
        previewBuildTask?.cancel()
    }

    // MARK: - Derived content

    /// The controller that should currently occupy the group's content
    /// host, or `nil` when this tab has nothing to show yet (loading) or
    /// nothing left to show (tombstoned).
    var displayedController: NSViewController? {
        switch content {
        case .loading, .tombstone:
            return nil
        case .source(let document):
            return document
        case .sourceWithPreview(let document, let preview):
            return prefersPreview ? preview : document
        case .previewOnly(let preview):
            return preview
        case .diff(let controller, _):
            return controller
        case .quickDiff(let document, _, _):
            return document
        }
    }

    /// The source document this tab owns, including one retained under a
    /// Git diff/quick diff — the document a reload replaces and a
    /// navigation anchor is captured from.
    var sourceDocument: CodeDocumentViewController? {
        content.sourceSide?.document
    }

    /// The source document only when it is this tab's own content (never
    /// under a Git overlay).
    var focusedSourceDocument: CodeDocumentViewController? {
        content.focusedSourceDocument
    }

    /// The source document only when it is what the tab is actually showing
    /// right now — not while its preview is displayed instead.
    var visibleSourceDocument: CodeDocumentViewController? {
        guard let document = content.focusedSourceDocument,
              displayedController === document else {
            return nil
        }
        return document
    }

    var previewController: PreviewViewController? {
        content.preview
    }

    var diffController: GitDiffViewController? {
        content.diffController
    }

    var quickDiffController: GitQuickDiffController? {
        content.quickDiffController
    }

    var documentControllers: [CodeDocumentViewController] {
        content.documentControllers
    }

    var statusDocument: EditorStatusDocument {
        switch content {
        case .loading:
            return EditorStatusDocument(
                relativePath: relativePath,
                contentKind: .loading,
                metadataDocument: nil,
                cursorDocument: nil
            )
        case .source(let document):
            return EditorStatusDocument(
                relativePath: relativePath,
                contentKind: .source,
                metadataDocument: document,
                cursorDocument: document
            )
        case .sourceWithPreview(let document, _):
            return EditorStatusDocument(
                relativePath: relativePath,
                contentKind: prefersPreview ? .preview : .source,
                metadataDocument: document,
                cursorDocument: prefersPreview ? nil : document
            )
        case .previewOnly:
            return EditorStatusDocument(
                relativePath: relativePath,
                contentKind: .previewOnly,
                metadataDocument: nil,
                cursorDocument: nil
            )
        case .diff(_, let retainedSource):
            return EditorStatusDocument(
                relativePath: relativePath,
                contentKind: .diff,
                metadataDocument: retainedSource?.document,
                cursorDocument: nil
            )
        case .quickDiff(let document, _, let retainedSource):
            return EditorStatusDocument(
                relativePath: relativePath,
                contentKind: .quickDiff,
                metadataDocument: retainedSource?.document ?? document,
                cursorDocument: document
            )
        case .tombstone:
            return EditorStatusDocument(
                relativePath: relativePath,
                contentKind: .tombstone,
                metadataDocument: nil,
                cursorDocument: nil
            )
        }
    }

    var showsQuickDiff: Bool {
        content.quickDiffController != nil
    }

    /// Whether this tab has no source side at all and can only show a preview.
    var isPreviewOnly: Bool {
        guard case .previewOnly = content else {
            return false
        }
        return true
    }

    var isTombstoned: Bool {
        guard case .tombstone = content else {
            return false
        }
        return true
    }

    /// What the window toolbar's Source/Preview control should offer for
    /// this tab (SPEC 5.7): nothing for non-previewable content or while a
    /// Git diff is layered on top, a disabled "Preview" indication for an
    /// image, and the live toggle state otherwise.
    var previewSourceControlState: EditorPreviewSourceControlState {
        guard let previewKind, previewKind != .none else {
            return .unavailable
        }
        switch content {
        case .diff, .quickDiff:
            return .unavailable
        case .previewOnly:
            return .previewOnly
        case .loading, .tombstone, .source, .sourceWithPreview:
            guard content.preview != nil else {
                return .unavailable
            }
            return prefersPreview ? .showingPreview : .showingSource
        }
    }

    // MARK: - Content transitions

    /// The one place content is ever replaced, and therefore the one place a
    /// controller is ever released. Cancels any in-flight preview build,
    /// clears a quick diff's gutter decorations when that quick diff is not
    /// carried into `newContent`, and returns the source documents that are
    /// genuinely gone — the only ones the owning group may report closed.
    /// A source view carried into `newContent` (retained under a Git
    /// overlay, or still shown after a preview is attached) is *not*
    /// discarded and produces no close.
    @discardableResult
    private func transition(to newContent: EditorTabContent) -> [CodeDocumentViewController] {
        cancelPreviewBuild()
        let previousContent = content
        if let quickDiff = previousContent.quickDiffController,
           quickDiff !== newContent.quickDiffController {
            quickDiff.clear()
        }
        content = newContent
        // A quick diff's virtual working/index document is never announced
        // ready to the language service, so it is never announced closed
        // either: only a real source document is ever reported here.
        guard let previousSource = previousContent.sourceSide?.document,
              !newContent.documentControllers.contains(where: { $0 === previousSource }) else {
            return []
        }
        return [previousSource]
    }

    /// Shows `document` as this tab's source view, dropping any Git overlay
    /// and keeping the preview already built for it (reopening the same file
    /// must not rebuild a preview that is still valid).
    @discardableResult
    func showSource(_ document: CodeDocumentViewController) -> [CodeDocumentViewController] {
        let side = content.sourceSide
        let preview = side?.document === document ? side?.preview : nil
        return transition(
            to: .displaying(EditorTabContent.SourceSide(document: document, preview: preview))
        )
    }

    /// Swaps in a freshly loaded `document` for the same file (SPEC 5.6
    /// external reload), keeping a Git diff/quick diff layered on top of it
    /// exactly as it was. Returns the superseded document so the group can
    /// report it closed *after* announcing the replacement ready — the
    /// language service must never see the file drop to zero live panes.
    @discardableResult
    func replaceSourceDocument(with document: CodeDocumentViewController) -> CodeDocumentViewController? {
        let previous = content.sourceSide
        let replaced = transition(
            to: content.replacingSourceSide(
                EditorTabContent.SourceSide(document: document, preview: previous?.preview)
            )
        )
        return replaced.first
    }

    /// Layers a full-file Git diff over this tab, retaining the source view
    /// it was opened from.
    func showDiff(_ controller: GitDiffViewController) {
        transition(to: .diff(controller, retainedSource: content.sourceSide))
    }

    /// Drops a full-file Git diff, falling back to the source view it was
    /// layered over (which was never closed, so nothing has to reload).
    func dismissDiff() {
        guard case .diff(_, let retainedSource) = content else {
            return
        }
        guard let retainedSource else {
            transition(to: .loading)
            return
        }
        transition(to: .displaying(retainedSource))
    }

    /// Layers Source Control Quick Diff's virtual working/index document
    /// over this tab, retaining the real source view underneath it.
    func showQuickDiff(document: CodeDocumentViewController, controller: GitQuickDiffController) {
        transition(
            to: .quickDiff(
                document: document,
                controller: controller,
                retainedSource: content.sourceSide
            )
        )
    }

    /// Replaces this tab's content with a preview built directly from raw
    /// bytes (an image or binary property list).
    /// Any source view is genuinely discarded here — a file whose bytes are
    /// no longer text has no source side — so it is returned for closing.
    @discardableResult
    func showPreviewOnly(_ preview: PreviewViewController, kind: PreviewKind) -> [CodeDocumentViewController] {
        let discarded = transition(to: .previewOnly(preview))
        previewKind = kind
        prefersPreview = true
        return discarded
    }

    /// Permanently discards everything this tab owns — the single teardown
    /// path behind closing a tab, reusing the preview tab for another file,
    /// tombstoning, and removing the whole group from the split tree.
    /// Returns the source documents whose content is actually gone.
    @discardableResult
    func discardContent() -> [CodeDocumentViewController] {
        let discarded = transition(to: .loading)
        previewKind = nil
        prefersPreview = false
        return discarded
    }

    /// Discards this tab's content and marks it a tombstone (SPEC 5.6).
    @discardableResult
    func markTombstoned(reason: TabTombstoneReason?) -> [CodeDocumentViewController] {
        let discarded = transition(to: .tombstone(reason: reason))
        previewKind = nil
        prefersPreview = false
        return discarded
    }

    /// Clears a tombstone so the tab loads its file again (the file
    /// reappeared at the same path). A no-op for a tab that is not
    /// tombstoned, so live content is never dropped by accident.
    func prepareForReload() {
        guard isTombstoned else {
            return
        }
        transition(to: .loading)
    }

    // MARK: - Preview building

    /// Records `kind` as this tab's detected preview format and, when it is
    /// previewable, builds the preview asynchronously. The runtime owns both
    /// the task and its generation counter: any content transition (or a
    /// transfer to another group) cancels and invalidates the build, so a
    /// slow preview can never land on a tab that has since been closed,
    /// reused for a different file, or replaced by a Git diff.
    func buildPreview(
        kind: PreviewKind,
        data: Data,
        theme: KodTheme,
        fontSettings: FontSettings,
        isWorkspaceTrusted: @escaping () -> Bool,
        documentRelativePath: String? = nil,
        loadLocalResource: (@MainActor (String) async throws -> Data)? = nil,
        openLocalRelativePath: ((String) -> Void)?,
        onReady: @escaping (EditorTabRuntime) -> Void
    ) {
        cancelPreviewBuild()
        previewKind = kind
        guard kind != .none else {
            dropPreview()
            return
        }
        prefersPreview = true

        let generation = previewBuildGeneration
        previewBuildTask = Task { [weak self] in
            guard let preview = await PreviewViewController.make(
                kind: kind,
                data: data,
                theme: theme,
                fontSettings: fontSettings,
                isWorkspaceTrusted: isWorkspaceTrusted,
                documentRelativePath: documentRelativePath,
                loadLocalResource: loadLocalResource,
                openLocalRelativePath: openLocalRelativePath
            ) else {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.previewBuildGeneration == generation else {
                return
            }
            self.previewBuildTask = nil
            guard self.attach(preview) else {
                return
            }
            onReady(self)
        }
    }

    /// Cancels any in-flight preview build and invalidates its result, so a
    /// build already past its `await` cannot attach afterwards.
    func cancelPreviewBuild() {
        previewBuildTask?.cancel()
        previewBuildTask = nil
        previewBuildGeneration += 1
    }

    /// Attaches a freshly built preview to this tab's source side. Returns
    /// `false` when the tab no longer has a source side to attach it to
    /// (it was torn down or converted while the build was running).
    private func attach(_ preview: PreviewViewController) -> Bool {
        guard let side = content.sourceSide else {
            return false
        }
        transition(
            to: content.replacingSourceSide(
                EditorTabContent.SourceSide(document: side.document, preview: preview)
            )
        )
        return true
    }

    /// Drops a preview this tab no longer has any use for (its content is
    /// not a recognized preview format), leaving the source view showing.
    private func dropPreview() {
        prefersPreview = false
        guard let side = content.sourceSide, side.preview != nil else {
            return
        }
        transition(
            to: content.replacingSourceSide(
                EditorTabContent.SourceSide(document: side.document, preview: nil)
            )
        )
    }

    // MARK: - Preview / source toggle

    /// Flips between the preview and source sides (SPEC 5.7). A no-op for a
    /// tab that can only ever show a preview.
    func togglePrefersPreview() {
        guard !isPreviewOnly else {
            return
        }
        prefersPreview.toggle()
    }

    // MARK: - Settings

    func applyWordWrap(_ enabled: Bool) {
        content.documentControllers.forEach { $0.wordWrapEnabled = enabled }
    }

    func applyMinimap(_ enabled: Bool) {
        content.documentControllers.forEach { $0.minimapEnabled = enabled }
    }

    func applyAppearance(theme: KodTheme, fontSettings: FontSettings) {
        for document in content.documentControllers {
            document.theme = theme
            document.fontSettings = fontSettings
        }
        content.quickDiffController?.refreshTheme()
    }
}

/// Enforces the one invariant the old parallel dictionaries could not: at
/// most one `EditorTabRuntime` exists per `EditorTabID`, and a runtime only
/// ever leaves a group by being removed from here — either torn down (a
/// close) or handed to another group intact (a drag between split panes).
@MainActor
struct EditorTabRuntimeStore {
    private var runtimesByTabID: [EditorTabID: EditorTabRuntime] = [:]

    init() {}

    /// Every live runtime, in no particular order — what appearance, word
    /// wrap, minimap and diagnostic updates have to reach.
    var all: [EditorTabRuntime] {
        Array(runtimesByTabID.values)
    }

    subscript(tabID: EditorTabID) -> EditorTabRuntime? {
        runtimesByTabID[tabID]
    }

    /// Whether `runtime` is still this store's runtime for `tabID` — the
    /// check an `async` continuation must make before touching anything it
    /// captured, since the tab may have been closed, reused or transferred
    /// while it was suspended.
    func owns(_ runtime: EditorTabRuntime, for tabID: EditorTabID) -> Bool {
        runtimesByTabID[tabID] === runtime
    }

    /// The runtime for `tabID`, created empty if this is the first time the
    /// group has needed one.
    mutating func runtime(for tabID: EditorTabID, relativePath: String) -> EditorTabRuntime {
        if let existing = runtimesByTabID[tabID] {
            return existing
        }
        let runtime = EditorTabRuntime(relativePath: relativePath)
        runtimesByTabID[tabID] = runtime
        return runtime
    }

    /// Takes ownership of a runtime built elsewhere (a tab dragged in from
    /// another split group). Returns any runtime it displaced, which the
    /// caller must tear down rather than leak.
    @discardableResult
    mutating func adopt(_ runtime: EditorTabRuntime, for tabID: EditorTabID) -> EditorTabRuntime? {
        let displaced = runtimesByTabID[tabID]
        runtimesByTabID[tabID] = runtime
        return displaced
    }

    @discardableResult
    mutating func remove(_ tabID: EditorTabID) -> EditorTabRuntime? {
        runtimesByTabID.removeValue(forKey: tabID)
    }

    mutating func removeAll() -> [EditorTabRuntime] {
        let removed = Array(runtimesByTabID.values)
        runtimesByTabID.removeAll()
        return removed
    }
}

/// A tab in flight between two split groups: its model plus the *same* live
/// runtime, so the destination shows the identical controllers the source
/// was showing. Nothing is closed and nothing is reopened, which is exactly
/// why a cross-pane drag must never make the language service churn through
/// didClose/didOpen for a document that never stopped being open.
@MainActor
public struct EditorTabTransferPayload {
    let tab: EditorTab
    let runtime: EditorTabRuntime
}
