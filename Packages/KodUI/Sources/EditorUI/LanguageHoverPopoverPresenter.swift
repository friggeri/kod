import AppKit
import CodeViewport
import FontCore
import LanguageClient
import PreviewUI
import ThemeCore

/// Builds and presents compact language-server hover content while leaving
/// source-token geometry and interaction timing to the app's hover coordinator.
@MainActor
public final class LanguageHoverPopoverPresenter {
    public typealias ContentBuilder = @MainActor (
        MarkupContent,
        KodTheme,
        FontSettings
    ) async -> HoverMarkupViewController?
    public typealias LocalLinkHandler = @MainActor (
        String,
        CodeDocumentViewController
    ) -> Void

    private let isWorkspaceTrusted: () -> Bool
    private let openLocalRelativePath: LocalLinkHandler?
    private let openExternalURL: @MainActor (URL) -> Void
    private let confirmBeforeOpening: @MainActor (URL) -> Bool
    private let contentBuilder: ContentBuilder?
    private var popover: NSPopover?
    private weak var presentedDocumentController: CodeDocumentViewController?

    public var onPointerEntered: (() -> Void)?
    public var onPointerExited: (() -> Void)?

    public init(
        isWorkspaceTrusted: @escaping () -> Bool = { false },
        openLocalRelativePath: LocalLinkHandler? = nil,
        openExternalURL: @escaping @MainActor (URL) -> Void = { url in
            _ = NSWorkspace.shared.open(url)
        },
        confirmBeforeOpening: @escaping @MainActor (URL) -> Bool =
            PreviewViewController.confirmWithAlert,
        contentBuilder: ContentBuilder? = nil
    ) {
        self.isWorkspaceTrusted = isWorkspaceTrusted
        self.openLocalRelativePath = openLocalRelativePath
        self.openExternalURL = openExternalURL
        self.confirmBeforeOpening = confirmBeforeOpening
        self.contentBuilder = contentBuilder
    }

    public func makeContent(
        for markup: MarkupContent,
        theme: KodTheme,
        fontSettings: FontSettings
    ) async -> HoverMarkupViewController? {
        if let contentBuilder {
            return await contentBuilder(markup, theme, fontSettings)
        }
        let content: HoverMarkupContent = markup.kind.lowercased() == "markdown"
            ? .markdown(markup.value)
            : .plaintext(markup.value)
        return await HoverMarkupViewController.make(
            content: content,
            theme: theme,
            fontSettings: fontSettings,
            isWorkspaceTrusted: isWorkspaceTrusted(),
            openLocalRelativePath: { [weak self] relativePath in
                guard let self,
                      let documentController = self.presentedDocumentController else {
                    return
                }
                self.openLocalRelativePath?(relativePath, documentController)
            },
            openExternalURL: openExternalURL,
            confirmBeforeOpening: confirmBeforeOpening
        )
    }

    public func present(
        _ contentController: HoverMarkupViewController,
        atViewportRect anchorRect: NSRect,
        in documentController: CodeDocumentViewController
    ) {
        guard documentController.viewport.window != nil else {
            dismiss()
            return
        }

        let maximumSize = Self.maximumContentSize(
            forViewportSize: documentController.viewport.visibleRect.size
        )
        let contentSize = contentController.fittingContentSize(maximumSize: maximumSize)
        contentController.view.frame = NSRect(origin: .zero, size: contentSize)
        contentController.onPointerEntered = { [weak self] in
            self?.onPointerEntered?()
        }
        contentController.onPointerExited = { [weak self] in
            self?.onPointerExited?()
        }

        dismiss()
        presentedDocumentController = documentController
        let newPopover = NSPopover()
        newPopover.behavior = .semitransient
        newPopover.animates = false
        newPopover.contentSize = contentSize
        newPopover.contentViewController = contentController
        popover = newPopover
        newPopover.show(
            relativeTo: anchorRect,
            of: documentController.viewport,
            preferredEdge: .maxY
        )
    }

    public func dismiss() {
        popover?.close()
        popover = nil
        presentedDocumentController = nil
    }

    static func maximumContentSize(forViewportSize viewportSize: NSSize) -> NSSize {
        NSSize(
            width: min(760, max(1, viewportSize.width - 32)),
            height: min(320, max(1, viewportSize.height * 0.55))
        )
    }

    var isPresenting: Bool { popover != nil }
}
