import AppKit
import FontCore
import PreviewCore
import ThemeCore

/// Wraps whichever built-in preview sub-controller matches a tab's
/// detected `PreviewKind` (SPEC 10): Markdown, static HTML, image (raster
/// or SVG), or JSON/plist. `EditorGroupViewController` swaps this in for a tab's
/// content host in place of (never in addition to — only one is visible
/// at a time) the existing `CodeDocumentViewController`, toggled via a
/// Source/Preview control; the underlying `CodeDocumentViewController`
/// keeps working exactly as it already does for the "Source" side of
/// that toggle, so Find/Go-to-Line/word-wrap/navigation history are
/// unaffected by this type existing at all.
@MainActor
public final class PreviewViewController: NSViewController {
    public let kind: PreviewKind
    private let child: NSViewController

    private init(kind: PreviewKind, child: NSViewController) {
        self.kind = kind
        self.child = child
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func loadView() {
        let container = NSView()
        addChild(child)
        let childView = child.view
        childView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(childView)
        NSLayoutConstraint.activate([
            childView.topAnchor.constraint(equalTo: container.topAnchor),
            childView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            childView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            childView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        view = container
    }

    var markdownController: MarkdownPreviewViewController? { child as? MarkdownPreviewViewController }
    var htmlController: HTMLPreviewViewController? { child as? HTMLPreviewViewController }
    var structuredDataController: StructuredDataPreviewViewController? { child as? StructuredDataPreviewViewController }
    var imageController: ImagePreviewViewController? { child as? ImagePreviewViewController }

    /// Builds the right kind of preview for `data`, having already
    /// detected `kind` from validated content (never from `pathExtension`
    /// alone — see `PreviewContentDetector`). `async` only for the
    /// Markdown path, whose fenced-code highlighting goes through the real
    /// `SyntaxEngine` actor.
    public static func make(
        kind: PreviewKind,
        data: Data,
        theme: KodTheme,
        fontSettings: FontSettings,
        isWorkspaceTrusted: @escaping () -> Bool,
        documentRelativePath: String? = nil,
        loadLocalResource: (@MainActor (String) async throws -> Data)? = nil,
        openLocalRelativePath: ((String) -> Void)? = nil,
        confirmBeforeOpening: @escaping @MainActor (URL) -> Bool = PreviewViewController.confirmWithAlert
    ) async -> PreviewViewController? {
        switch kind {
        case .markdown:
            let text = String(data: data, encoding: .utf8) ?? ""
            let document = MarkdownParser.parse(text)
            let rendered = await MarkdownRenderer.render(document, theme: theme)
            let policy = MarkdownResourcePolicy(isWorkspaceTrusted: isWorkspaceTrusted())
            let controller = MarkdownPreviewViewController(
                renderDocument: rendered,
                resourcePolicy: policy,
                theme: theme,
                fontSettings: fontSettings,
                confirmBeforeOpening: confirmBeforeOpening
            )
            controller.openLocalRelativePath = openLocalRelativePath
            return PreviewViewController(kind: kind, child: controller)

        case .html:
            guard HTMLPreviewDocument.securedHTML(from: data) != nil else {
                return nil
            }
            let controller = HTMLPreviewViewController(
                data: data,
                documentRelativePath: documentRelativePath,
                loadLocalResource: loadLocalResource,
                isWorkspaceTrusted: isWorkspaceTrusted,
                openLocalRelativePath: openLocalRelativePath,
                confirmBeforeOpening: confirmBeforeOpening
            )
            return PreviewViewController(kind: kind, child: controller)

        case .image(let format):
            if format == .svg {
                let result = SVGDocumentLoader.load(data)
                return PreviewViewController(kind: kind, child: ImagePreviewViewController(svgResult: result))
            }
            let result = ImageDecoder.decode(data)
            return PreviewViewController(kind: kind, child: ImagePreviewViewController(decodeResult: result))

        case .structuredData:
            let document = StructuredDocument.parse(data)
            return PreviewViewController(kind: kind, child: StructuredDataPreviewViewController(document: document))

        case .none:
            return nil
        }
    }

    /// The real, production confirmation path for opening a non-local
    /// link from an untrusted workspace (SPEC 10.1) — a modal alert
    /// naming the exact destination before Kod ever calls
    /// `NSWorkspace.open`. Tests substitute a non-interactive closure via
    /// `confirmBeforeOpening` instead of exercising this (no UI
    /// automation is ever launched in this codebase's test suite).
    @MainActor
    public static func confirmWithAlert(_ url: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = previewUIStrings.string("Open Link?", comment: "Alert title asking whether to open an external link from an untrusted workspace")
        alert.informativeText = previewUIStrings.string(
            "This workspace is not trusted. Open \(url.absoluteString) in your default browser?",
            comment: "Alert body explaining the untrusted-workspace external-link confirmation, naming the destination URL"
        )
        alert.addButton(withTitle: previewUIStrings.string("Open", comment: "Button title confirming opening the external link"))
        alert.addButton(withTitle: previewUIStrings.string("Cancel", comment: "Button title canceling the external link open"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
