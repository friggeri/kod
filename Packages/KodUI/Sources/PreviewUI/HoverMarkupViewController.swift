import AppKit
import FontCore
import KodUIComponents
import PreviewCore
import ThemeCore

private final class HoverTrackingScrollView: NSScrollView {
    var onPointerEntered: (() -> Void)?
    var onPointerExited: (() -> Void)?
    private var pointerTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        pointerTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        onPointerEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        onPointerExited?()
    }
}

public enum HoverMarkupContent: Sendable {
    case markdown(String)
    case plaintext(String)

    fileprivate var value: String {
        switch self {
        case .markdown(let value), .plaintext(let value):
            value
        }
    }
}

/// A compact, native attributed-text surface for language hover content.
/// Parsing, sanitization, and code highlighting reuse PreviewCore's Markdown
/// pipeline; the view itself performs no resource loading.
@MainActor
public final class HoverMarkupViewController: NSViewController {
    private static let horizontalInset: CGFloat = 12
    private static let verticalInset: CGFloat = 9
    private static let minimumWidth: CGFloat = 260
    private static let minimumHeight: CGFloat = 38

    private let scrollView = HoverTrackingScrollView()
    private let textView: NSTextView
    private let renderedAttributedText: NSAttributedString
    private let resourcePolicy: MarkdownResourcePolicy
    private let openExternalURL: @MainActor (URL) -> Void
    private let confirmBeforeOpening: @MainActor (URL) -> Bool

    public var openLocalRelativePath: ((String) -> Void)?
    public var onPointerEntered: (() -> Void)? {
        didSet { scrollView.onPointerEntered = onPointerEntered }
    }
    public var onPointerExited: (() -> Void)? {
        didSet { scrollView.onPointerExited = onPointerExited }
    }
    private(set) var lastOpenedURL: URL?
    private(set) var lastConfirmationPrompted: URL?

    private init(
        renderedAttributedText: NSAttributedString,
        resourcePolicy: MarkdownResourcePolicy,
        openExternalURL: @escaping @MainActor (URL) -> Void,
        confirmBeforeOpening: @escaping @MainActor (URL) -> Bool
    ) {
        let textStorage = NSTextStorage()
        let layoutManager = MarkdownPreviewLayoutManager()
        let textContainer = NSTextContainer(
            size: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude)
        )
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        self.textView = NSTextView(frame: .zero, textContainer: textContainer)
        self.renderedAttributedText = renderedAttributedText
        self.resourcePolicy = resourcePolicy
        self.openExternalURL = openExternalURL
        self.confirmBeforeOpening = confirmBeforeOpening
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public static func make(
        content: HoverMarkupContent,
        theme: KodTheme,
        fontSettings: FontSettings,
        isWorkspaceTrusted: Bool,
        openLocalRelativePath: ((String) -> Void)? = nil,
        openExternalURL: @escaping @MainActor (URL) -> Void = { url in
            _ = NSWorkspace.shared.open(url)
        },
        confirmBeforeOpening: @escaping @MainActor (URL) -> Bool =
            PreviewViewController.confirmWithAlert
    ) async -> HoverMarkupViewController? {
        let value = content.value
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let policy = MarkdownResourcePolicy(isWorkspaceTrusted: isWorkspaceTrusted)
        let attributed: NSAttributedString
        switch content {
        case .markdown:
            let document = MarkdownParser.parse(value)
            let rendered = await MarkdownRenderer.render(document, theme: theme)
            guard !Task.isCancelled else {
                return nil
            }
            attributed = MarkdownAttributedDocumentRenderer(
                document: rendered,
                resourcePolicy: policy,
                theme: theme,
                fontSettings: fontSettings,
                presentationStyle: .compact
            ).render()

        case .plaintext:
            attributed = plainText(
                value,
                theme: theme,
                fontSettings: fontSettings
            )
        }

        guard attributed.length > 0 else {
            return nil
        }
        let controller = HoverMarkupViewController(
            renderedAttributedText: attributed,
            resourcePolicy: policy,
            openExternalURL: openExternalURL,
            confirmBeforeOpening: confirmBeforeOpening
        )
        controller.openLocalRelativePath = openLocalRelativePath
        return controller
    }

    public override func loadView() {
        textView.identifier = NSUserInterfaceItemIdentifier("languageHover.textView")
        textView.delegate = self
        textView.drawsBackground = false
        textView.textStorage?.setAttributedString(renderedAttributedText)

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        configureReadOnlyScrollingTextView(textView, in: scrollView, wrapsLines: true)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(
            width: Self.horizontalInset,
            height: Self.verticalInset
        )
        scrollView.hasVerticalScroller = false
        view = scrollView
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        layoutTextDocument(width: scrollView.contentSize.width)
    }

    /// Measures the rendered document at a readable width, then clamps it to
    /// the editor-provided maximum. The caller uses this as NSPopover content.
    public func fittingContentSize(maximumSize: NSSize) -> NSSize {
        loadViewIfNeeded()
        let maximumWidth = max(1, maximumSize.width)
        let maximumHeight = max(1, maximumSize.height)
        let minimumWidth = min(Self.minimumWidth, maximumWidth)
        let minimumHeight = min(Self.minimumHeight, maximumHeight)

        let measurementWidth = max(
            1,
            maximumWidth - (Self.horizontalInset * 2)
        )
        let naturalRect = renderedAttributedText.boundingRect(
            with: NSSize(
                width: measurementWidth,
                height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let width = min(
            maximumWidth,
            max(
                minimumWidth,
                ceil(naturalRect.width) + (Self.horizontalInset * 2) + 2
            )
        )
        let laidOut = layoutTextDocument(width: width)
        let finalBoundingRect = renderedAttributedText.boundingRect(
            with: NSSize(
                width: max(1, width - (Self.horizontalInset * 2)),
                height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let naturalHeight = ceil(max(laidOut.height, finalBoundingRect.height))
            + (Self.verticalInset * 2)
        let height = min(maximumHeight, max(minimumHeight, naturalHeight))

        scrollView.hasVerticalScroller = naturalHeight > height + 0.5
        scrollView.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        layoutTextDocument(width: scrollView.contentSize.width)
        return NSSize(width: width, height: height)
    }

    @discardableResult
    private func layoutTextDocument(width: CGFloat) -> NSSize {
        let resolvedWidth = max(1, width)
        textView.setFrameSize(NSSize(width: resolvedWidth, height: max(1, textView.frame.height)))
        textView.textContainer?.containerSize = NSSize(
            width: max(1, resolvedWidth - (Self.horizontalInset * 2)),
            height: CGFloat.greatestFiniteMagnitude
        )
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return .zero
        }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        textView.setFrameSize(
            NSSize(
                width: resolvedWidth,
                height: max(scrollView.contentSize.height, ceil(usedRect.height) + (Self.verticalInset * 2))
            )
        )
        return usedRect.size
    }

    private static func plainText(
        _ value: String,
        theme: KodTheme,
        fontSettings: FontSettings
    ) -> NSAttributedString {
        let resolvedFont = FontResolver.resolve(fontSettings)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = CGFloat(fontSettings.lineHeightMultiplier)
        paragraphStyle.lineBreakMode = .byWordWrapping
        var attributes: [NSAttributedString.Key: Any] = [
            .font: resolvedFont.nsFont,
            .foregroundColor: ThemeColorAppKitBridge.nsColor(theme.editor.foreground),
            .ligature: resolvedFont.ligatureAttributeValue,
            .paragraphStyle: paragraphStyle
        ]
        if resolvedFont.letterSpacing != 0 {
            attributes[.kern] = resolvedFont.letterSpacing
        }
        return NSAttributedString(string: value, attributes: attributes)
    }
}

extension HoverMarkupViewController: NSTextViewDelegate {
    public func textView(
        _ textView: NSTextView,
        clickedOnLink link: Any,
        at charIndex: Int
    ) -> Bool {
        guard let rawValue = link as? String else {
            return false
        }
        let destination = MarkdownDestination(rawValue: rawValue)
        if case .unsafeOrUnrecognized = destination.scheme {
            return true
        }
        guard let url = URL(string: rawValue) else {
            return true
        }
        if destination.scheme == .local {
            openLocalRelativePath?(rawValue)
            lastOpenedURL = url
            return true
        }
        if resourcePolicy.requiresConfirmationToOpen(destination) {
            lastConfirmationPrompted = url
            guard confirmBeforeOpening(url) else {
                return true
            }
        }
        lastOpenedURL = url
        openExternalURL(url)
        return true
    }
}

extension HoverMarkupViewController {
    var renderedText: String { textView.string }
    var attributedText: NSAttributedString { textView.attributedString() }
    var hasVerticalScroller: Bool { scrollView.hasVerticalScroller }
    var renderedTextViewFrame: NSRect { textView.frame }
    var textIsEditable: Bool { textView.isEditable }
    var textIsSelectable: Bool { textView.isSelectable }
    var textViewIdentifier: NSUserInterfaceItemIdentifier? { textView.identifier }

    func renderedLineFragmentCount(containing text: String) -> Int {
        let characterRange = (textView.string as NSString).range(of: text)
        guard characterRange.location != NSNotFound,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return 0
        }
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        var count = 0
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            _, _, _, _, _ in count += 1
        }
        return count
    }
}
