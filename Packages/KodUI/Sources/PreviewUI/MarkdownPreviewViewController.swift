import AppKit
import DiagnosticsCore
import FontCore
import KodUIComponents
import PreviewCore
import ThemeCore

struct RemoteMarkdownImageLoad: Sendable {
    let image: CGImageBox
    let sourceByteCount: Int
    let decodedByteCount: Int
}

enum RemoteMarkdownImageLoader {
    static func load(_ url: URL) async -> RemoteMarkdownImageLoad? {
        let fetchLimits = BoundedRemoteFetchLimits(
            maximumByteCount: 5 * 1_024 * 1_024,
            timeoutSeconds: 10,
            requireHTTPS: true
        )
        let decodeLimits = ImageDecodeLimits(
            maximumSourceByteCount: fetchLimits.maximumByteCount,
            maximumDimension: 8_192,
            maximumPixelCount: 8_000_000,
            maximumFrameCount: 32,
            maximumTotalDecodedByteBudget: 32 * 1_024 * 1_024
        )
        guard !Task.isCancelled,
              let data = try? await BoundedRemoteFetcher.fetch(url, limits: fetchLimits),
              !Task.isCancelled else {
            return nil
        }
        let decoded = ImageDecoder.decode(data, limits: decodeLimits)
        guard !Task.isCancelled,
              case .decoded(let metadata, let frames) = decoded,
              let frame = frames.first else {
            return nil
        }
        return RemoteMarkdownImageLoad(
            image: frame.image,
            sourceByteCount: data.count,
            decodedByteCount: metadata.pixelWidth * metadata.pixelHeight * 4 * metadata.frameCount
        )
    }
}

/// The built-in Markdown preview: a native `NSTextView`-based rendered
/// view (SPEC 10.1: "Prefer a native attributed/document model"; Kod
/// never uses WebKit for this — see `MarkdownRenderer`'s doc comment).
/// Renders `MarkdownRenderDocument` into an `NSAttributedString`, shows
/// link destinations, requires confirmation before opening a non-local
/// link from an untrusted workspace, and never loads a remote image
/// unless the user explicitly opts in for *this* document via
/// `remoteImagesButton`.
@MainActor
final class MarkdownPreviewViewController: NSViewController {
    private let scrollView = NSScrollView()
    private let textView: NSTextView = {
        let textStorage = NSTextStorage()
        let layoutManager = MarkdownPreviewLayoutManager()
        let textContainer = NSTextContainer(
            size: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude)
        )
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        return NSTextView(frame: .zero, textContainer: textContainer)
    }()
    private let statusBanner = NSVisualEffectView()
    private let statusStack = NSStackView()
    private let statusSpacer = NSView()
    private let remoteImagesButton = NSButton(
        title: previewUIStrings.string(
            "Load Remote Images (\(NetworkAttribution.remoteMarkdownResource.userFacingDescription))",
            comment: "Button title inviting the user to opt into loading remote images for this Markdown document"
        ),
        target: nil,
        action: nil
    )
    private let diagnosticsLabel = NSTextField(wrappingLabelWithString: "")
    private var scrollerTopToBannerConstraint: NSLayoutConstraint?
    private var scrollerTopDirectConstraint: NSLayoutConstraint?

    private(set) var renderDocument: MarkdownRenderDocument
    private(set) var resourcePolicy: MarkdownResourcePolicy
    private let theme: KodTheme
    private let fontSettings: FontSettings
    private let remoteImageLoader: @Sendable (URL) async -> RemoteMarkdownImageLoad?
    /// Injected so tests can substitute a confirmation outcome without a
    /// real alert sheet; production uses a real `NSAlert`.
    var confirmBeforeOpening: @MainActor (URL) -> Bool
    private let openExternalURL: @MainActor (URL) -> Void
    var openLocalRelativePath: ((String) -> Void)?
    private(set) var lastOpenedURL: URL?
    private(set) var lastConfirmationPrompted: URL?
    private var loadedImages: [String: NSImage] = [:]
    private var failedImageDestinations: Set<String> = []
    private var remoteImageLoadTask: Task<Void, Never>?
    private var documentGeneration = 0

    /// Set of remote image destinations actually referenced by the
    /// current document — used to enable/disable `remoteImagesButton`
    /// without guessing.
    private(set) var remoteImageDestinations: [MarkdownDestination] = []

    init(
        renderDocument: MarkdownRenderDocument,
        resourcePolicy: MarkdownResourcePolicy,
        theme: KodTheme,
        fontSettings: FontSettings,
        remoteImageLoader: @escaping @Sendable (URL) async -> RemoteMarkdownImageLoad? = RemoteMarkdownImageLoader.load,
        openExternalURL: @escaping @MainActor (URL) -> Void = { url in
            _ = NSWorkspace.shared.open(url)
        },
        confirmBeforeOpening: @escaping @MainActor (URL) -> Bool = { _ in false }
    ) {
        self.renderDocument = renderDocument
        self.resourcePolicy = resourcePolicy
        self.theme = theme
        self.fontSettings = fontSettings
        self.remoteImageLoader = remoteImageLoader
        self.openExternalURL = openExternalURL
        self.confirmBeforeOpening = confirmBeforeOpening
        super.init(nibName: nil, bundle: nil)
        self.remoteImageDestinations = Self.collectRemoteImageDestinations(renderDocument, policy: resourcePolicy)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let container = NSView()

        textView.isEditable = false
        textView.isSelectable = true
        textView.identifier = NSUserInterfaceItemIdentifier("markdownPreview.textView")
        textView.drawsBackground = false
        textView.delegate = self
        textView.textContainerInset = NSSize(width: 24, height: 24)

        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        configureReadOnlyScrollingTextView(textView, in: scrollView, wrapsLines: true)

        statusBanner.material = .underWindowBackground
        statusBanner.blendingMode = .withinWindow
        statusBanner.state = .active
        statusBanner.translatesAutoresizingMaskIntoConstraints = false
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 8
        statusStack.translatesAutoresizingMaskIntoConstraints = false

        remoteImagesButton.target = self
        remoteImagesButton.action = #selector(handleLoadRemoteImages)
        remoteImagesButton.isHidden = remoteImageDestinations.isEmpty
        remoteImagesButton.translatesAutoresizingMaskIntoConstraints = false
        // SPEC 13.3: name the actual purpose of this opt-in network
        // access explicitly, rather than a generic "Allow network
        // access?" — this is the one place in PreviewUI where a
        // user opts a document into an outbound fetch.
        remoteImagesButton.toolTip = NetworkAttribution.remoteMarkdownResource.userFacingDescription
        remoteImagesButton.setAccessibilityLabel(
            previewUIStrings.string(
                "Load remote images for this document. \(NetworkAttribution.remoteMarkdownResource.userFacingDescription)",
                comment: "Accessibility label for the load-remote-images button, explaining the opt-in network access"
            )
        )

        diagnosticsLabel.textColor = .secondaryLabelColor
        diagnosticsLabel.font = .systemFont(ofSize: 10)
        diagnosticsLabel.isHidden = renderDocument.sanitizerDiagnostics.isEmpty
        diagnosticsLabel.stringValue = renderDocument.sanitizerDiagnostics.isEmpty
            ? ""
            : previewUIStrings.string(
                "\(renderDocument.sanitizerDiagnostics.count) unsafe construct(s) removed while rendering this document.",
                comment: "Status text reporting how many unsafe Markdown constructs were sanitized out of the rendered document"
            )
        diagnosticsLabel.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsLabel.setAccessibilityLabel(previewUIStrings.string("Sanitizer diagnostics", comment: "Accessibility label for the Markdown sanitizer diagnostics text"))
        diagnosticsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        statusStack.addArrangedSubview(diagnosticsLabel)
        statusStack.addArrangedSubview(statusSpacer)
        statusStack.addArrangedSubview(remoteImagesButton)
        statusBanner.addSubview(statusStack)
        container.addSubview(statusBanner)
        container.addSubview(scrollView)

        let scrollerTopToBanner = scrollView.topAnchor.constraint(equalTo: statusBanner.bottomAnchor)
        let scrollerTopDirect = scrollView.topAnchor.constraint(equalTo: container.topAnchor)
        scrollerTopToBannerConstraint = scrollerTopToBanner
        scrollerTopDirectConstraint = scrollerTopDirect
        NSLayoutConstraint.activate([
            statusBanner.topAnchor.constraint(equalTo: container.topAnchor),
            statusBanner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBanner.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            statusStack.topAnchor.constraint(equalTo: statusBanner.topAnchor, constant: 7),
            statusStack.leadingAnchor.constraint(equalTo: statusBanner.leadingAnchor, constant: 10),
            statusStack.trailingAnchor.constraint(equalTo: statusBanner.trailingAnchor, constant: -10),
            statusStack.bottomAnchor.constraint(equalTo: statusBanner.bottomAnchor, constant: -7),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        view = container
        updateStatusBanner()
        applyAttributedText()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let readableWidth: CGFloat = 780
        let minimumInset: CGFloat = 24
        let availableWidth = scrollView.contentSize.width
        let horizontalInset = max(minimumInset, (availableWidth - readableWidth) / 2)
        if textView.frame.width != availableWidth {
            textView.setFrameSize(NSSize(width: availableWidth, height: textView.frame.height))
            textView.textContainer?.containerSize.width = availableWidth
        }
        textView.textContainerInset = NSSize(width: horizontalInset, height: 24)
    }

    /// Re-renders after `resourcePolicy` changes (e.g. remote images were
    /// just explicitly enabled) or a new render document arrives.
    func update(renderDocument: MarkdownRenderDocument, resourcePolicy: MarkdownResourcePolicy) {
        remoteImageLoadTask?.cancel()
        documentGeneration += 1
        loadedImages.removeAll()
        failedImageDestinations.removeAll()
        self.renderDocument = renderDocument
        self.resourcePolicy = resourcePolicy
        self.remoteImageDestinations = Self.collectRemoteImageDestinations(renderDocument, policy: resourcePolicy)
        remoteImagesButton.title = previewUIStrings.string(
            "Load Remote Images (\(NetworkAttribution.remoteMarkdownResource.userFacingDescription))",
            comment: "Button title inviting the user to opt into loading remote images for this Markdown document"
        )
        remoteImagesButton.isEnabled = true
        remoteImagesButton.isHidden = remoteImageDestinations.isEmpty
        diagnosticsLabel.isHidden = renderDocument.sanitizerDiagnostics.isEmpty
        diagnosticsLabel.stringValue = renderDocument.sanitizerDiagnostics.isEmpty
            ? ""
            : previewUIStrings.string(
                "\(renderDocument.sanitizerDiagnostics.count) unsafe construct(s) removed while rendering this document.",
                comment: "Status text reporting how many unsafe Markdown constructs were sanitized out of the rendered document"
            )
        updateStatusBanner()
        applyAttributedText()
    }

    @objc
    private func handleLoadRemoteImages(_ sender: Any?) {
        let maximumImageCount = 8
        let maximumTransferredBytes = 40 * 1_024 * 1_024
        let maximumDecodedBytes = 128 * 1_024 * 1_024
        let generation = documentGeneration
        let remoteImageLoader = self.remoteImageLoader
        let destinations = Array(remoteImageDestinations.prefix(maximumImageCount))
        for destination in remoteImageDestinations.dropFirst(maximumImageCount) {
            failedImageDestinations.insert(destination.rawValue)
        }
        resourcePolicy.remoteImagesEnabledForThisDocument = true
        remoteImagesButton.isEnabled = false
        remoteImagesButton.title = previewUIStrings.string(
            "Loading Remote Images\u{2026}",
            comment: "Button status while explicitly requested remote Markdown images are fetched"
        )
        remoteImageLoadTask?.cancel()
        remoteImageLoadTask = Task { [weak self] in
            var transferredBytes = 0
            var decodedBytes = 0
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            for destination in destinations {
                guard !Task.isCancelled,
                      ContinuousClock.now < deadline,
                      let url = URL(string: destination.rawValue) else { break }
                let loaded = await remoteImageLoader(url)
                guard !Task.isCancelled,
                      let self,
                      documentGeneration == generation else { return }
                guard let loaded,
                      transferredBytes + loaded.sourceByteCount <= maximumTransferredBytes,
                      decodedBytes + loaded.decodedByteCount <= maximumDecodedBytes else {
                    failedImageDestinations.insert(destination.rawValue)
                    continue
                }
                transferredBytes += loaded.sourceByteCount
                decodedBytes += loaded.decodedByteCount
                loadedImages[destination.rawValue] = NSImage(
                    cgImage: loaded.image.value,
                    size: NSSize(width: loaded.image.value.width, height: loaded.image.value.height)
                )
            }
            guard !Task.isCancelled, let self, documentGeneration == generation else { return }
            for destination in destinations
            where loadedImages[destination.rawValue] == nil
                && !failedImageDestinations.contains(destination.rawValue) {
                failedImageDestinations.insert(destination.rawValue)
            }
            remoteImagesButton.isHidden = true
            remoteImagesButton.isEnabled = true
            updateStatusBanner()
            applyAttributedText()
        }
    }

    private func updateStatusBanner() {
        guard isViewLoaded else { return }
        let isVisible = !remoteImagesButton.isHidden || !diagnosticsLabel.isHidden
        statusBanner.isHidden = !isVisible
        scrollerTopToBannerConstraint?.isActive = isVisible
        scrollerTopDirectConstraint?.isActive = !isVisible
    }

    private static func collectRemoteImageDestinations(
        _ document: MarkdownRenderDocument,
        policy: MarkdownResourcePolicy
    ) -> [MarkdownDestination] {
        var destinations: [MarkdownDestination] = []
        func collectFromRuns(_ runs: [MarkdownRenderRun]) {
            for run in runs where run.isImage {
                guard let destination = run.link, !policy.shouldLoadRemoteImage(destination) else {
                    continue
                }
                destinations.append(destination)
            }
        }
        func walk(_ blocks: [MarkdownRenderBlock]) {
            for block in blocks {
                switch block {
                case .heading(_, let runs), .paragraph(let runs):
                    collectFromRuns(runs)
                case .image(let destination, _, _):
                    if !policy.shouldLoadRemoteImage(destination) {
                        destinations.append(destination)
                    }
                case .blockquote(let inner):
                    walk(inner)
                case .list(_, _, let items):
                    walk(items)
                case .listItem(_, let inner):
                    walk(inner)
                case .table(_, let header, let rows):
                    header.forEach(collectFromRuns)
                    for row in rows {
                        row.forEach(collectFromRuns)
                    }
                default:
                    break
                }
            }
        }
        walk(document.blocks)
        var seen: Set<String> = []
        return destinations.filter { seen.insert($0.rawValue).inserted }
    }

    private func applyAttributedText() {
        let renderer = MarkdownAttributedDocumentRenderer(
            document: renderDocument,
            resourcePolicy: resourcePolicy,
            theme: theme,
            fontSettings: fontSettings,
            loadedImages: loadedImages,
            failedImageDestinations: failedImageDestinations
        )
        textView.textStorage?.setAttributedString(renderer.render())
    }
}

extension MarkdownPreviewViewController {
    // MARK: - Test-facing state

    var remoteImagesButtonAccessibilityLabel: String? { remoteImagesButton.accessibilityLabel() }
    var diagnosticsAccessibilityLabel: String? { diagnosticsLabel.accessibilityLabel() }
    var renderedText: String { textView.string }
    var renderedTextViewFrame: NSRect { textView.frame }
    var renderedAttributedText: NSAttributedString { textView.attributedString() }
    var statusBannerIsVisible: Bool { !statusBanner.isHidden }
    var previewTopGap: CGFloat { view.bounds.maxY - scrollView.frame.maxY }
    var previewScrollViewFrame: NSRect { scrollView.frame }
    var markdownDrawsBackground: Bool { textView.drawsBackground }
    var scrollViewDrawsBackground: Bool { scrollView.drawsBackground }
    var remoteImagesButtonIsEnabled: Bool { remoteImagesButton.isEnabled }
    var remoteImagesButtonIsHidden: Bool { remoteImagesButton.isHidden }
    var usesMarkdownLayoutManager: Bool { textView.layoutManager is MarkdownPreviewLayoutManager }
    func beginRemoteImageLoadForTesting() { handleLoadRemoteImages(nil) }

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
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, _, _ in
            count += 1
        }
        return count
    }
}

extension MarkdownPreviewViewController: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
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
