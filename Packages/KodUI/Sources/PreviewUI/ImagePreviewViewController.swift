import AppKit
import PreviewCore

/// Keeps an image centered whenever its magnified document bounds are smaller
/// than the visible scroll area, while preserving normal panning when the
/// image is larger than the viewport.
private final class CenteredImageClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)
        guard let documentView else {
            return constrained
        }

        if constrained.width > documentView.frame.width {
            constrained.origin.x = (documentView.frame.width - constrained.width) / 2
        }
        if constrained.height > documentView.frame.height {
            constrained.origin.y = (documentView.frame.height - constrained.height) / 2
        }
        return constrained
    }
}

private final class TransparencyBackgroundView: NSView {
    private static let tileSize: CGFloat = 12
    var showsCheckerboard = true {
        didSet {
            guard oldValue != showsCheckerboard else {
                return
            }
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        solidColor.setFill()
        dirtyRect.fill()

        guard showsCheckerboard else {
            return
        }

        let tileSize = Self.tileSize
        let minimumColumn = Int(floor(dirtyRect.minX / tileSize))
        let maximumColumn = Int(ceil(dirtyRect.maxX / tileSize))
        let minimumRow = Int(floor(dirtyRect.minY / tileSize))
        let maximumRow = Int(ceil(dirtyRect.maxY / tileSize))

        for row in minimumRow..<maximumRow {
            for column in minimumColumn..<maximumColumn where (row + column).isMultiple(of: 2) {
                alternateColor.setFill()
                NSRect(
                    x: CGFloat(column) * tileSize,
                    y: CGFloat(row) * tileSize,
                    width: tileSize,
                    height: tileSize
                ).fill()
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private var solidColor: NSColor {
        guard showsCheckerboard else {
            return .windowBackgroundColor
        }
        return gray(usesDarkAppearance ? 0.16 : 0.94)
    }

    private var alternateColor: NSColor {
        gray(usesDarkAppearance ? 0.24 : 0.78)
    }

    private var usesDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func gray(_ component: CGFloat) -> NSColor {
        NSColor(
            srgbRed: component,
            green: component,
            blue: component,
            alpha: 1
        )
    }

    func backgroundColor(at point: NSPoint) -> NSColor {
        guard showsCheckerboard else {
            return solidColor
        }
        let column = Int(floor(point.x / Self.tileSize))
        let row = Int(floor(point.y / Self.tileSize))
        return (row + column).isMultiple(of: 2) ? alternateColor : solidColor
    }
}

/// How the image is currently scaled inside its scroll view (SPEC 10.2:
/// "Fit, actual size, zoom, pan, transparency background").
enum ImagePreviewZoomMode: Equatable {
    case fit
    case actualSize
    case custom(CGFloat)
}

/// The built-in image preview: fit/actual-size/zoom/pan, an optional
/// transparency checkerboard background, safe (decode-limited, non-
/// animated unless Reduce Motion is enabled) frame display, and a read-only
/// metadata panel.
/// Only ever receives bytes already decoded by `PreviewCore.ImageDecoder`
/// (raster formats) or `SVGDocumentLoader` (SVG) — this type never parses
/// or fetches anything itself.
@MainActor
final class ImagePreviewViewController: NSViewController {
    private enum PlaybackPreference {
        case automatic
        case playing
        case paused
    }

    private let scrollView = NSScrollView()
    private let imageView = NSImageView()
    private let checkerboardView = TransparencyBackgroundView()
    private let metadataLabel = NSTextField(wrappingLabelWithString: "")
    private let footerRow = NSStackView()
    private let footerSpacer = NSView()
    private let controls = NSStackView()
    private let fitButton = NSButton(title: previewUIStrings.string("Fit", comment: "Button title to fit the image preview to the window"), target: nil, action: nil)
    private let actualSizeButton = NSButton(
        title: previewUIStrings.string("Actual Size", comment: "Button title to show the image preview at its actual pixel size"),
        target: nil,
        action: nil
    )
    private let zoomInButton = NSButton(title: "+", target: nil, action: nil) // audit-exempt: symbolic glyph, not prose (accessibility label is localized separately)
    private let zoomOutButton = NSButton(title: "\u{2212}", target: nil, action: nil) // audit-exempt: symbolic glyph, not prose (accessibility label is localized separately)
    private let transparencyButton = NSButton(
        checkboxWithTitle: previewUIStrings.string("Checkerboard", comment: "Checkbox toggling the transparency checkerboard background in image preview"),
        target: nil,
        action: nil
    )
    private let playPauseButton = NSButton(title: previewUIStrings.string("Pause", comment: "Initial title of the animated-image play/pause button"), target: nil, action: nil)
    private let accessibilityDisplayShouldReduceMotion: @MainActor () -> Bool
    private let notificationCenter: NotificationCenter
    private let accessibilityDisplayOptionsDidChangeNotification: Notification.Name

    private(set) var metadata: ImageMetadata?
    private(set) var diagnostic: ImageDecodeDiagnostic?
    private(set) var svgDiagnostic: SVGDiagnostic?
    private(set) var zoomMode: ImagePreviewZoomMode = .actualSize
    private(set) var isAnimating = true
    private(set) var currentFrameIndex = 0

    private var frames: [CGImage] = []
    private var frameDurations: [Double] = []
    private nonisolated(unsafe) var animationTimer: Timer?
    private var playbackPreference: PlaybackPreference = .automatic
    private var isObservingAccessibilityDisplayOptions = false
    private var showsCheckerboardBackground = true {
        didSet { checkerboardView.showsCheckerboard = showsCheckerboardBackground }
    }

    /// Constructs from an already-decoded raster result.
    init(
        decodeResult: ImageDecodeResult,
        accessibilityDisplayShouldReduceMotion: @escaping @MainActor () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        },
        notificationCenter: NotificationCenter =
            NSWorkspace.shared.notificationCenter,
        accessibilityDisplayOptionsDidChangeNotification: Notification.Name =
            NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
    ) {
        self.accessibilityDisplayShouldReduceMotion =
            accessibilityDisplayShouldReduceMotion
        self.notificationCenter = notificationCenter
        self.accessibilityDisplayOptionsDidChangeNotification =
            accessibilityDisplayOptionsDidChangeNotification
        super.init(nibName: nil, bundle: nil)
        switch decodeResult {
        case .decoded(let metadata, let frameList):
            self.metadata = metadata
            self.frames = frameList.map(\.image.value)
            self.frameDurations = frameList.map(\.durationSeconds)
        case .rejected(let diagnostic):
            self.diagnostic = diagnostic
        }
    }

    /// Constructs from a rejected/valid SVG document result (SVG never
    /// goes through `ImageDecoder`; see `SVGDocumentLoader`).
    init(
        svgResult: SVGDocumentResult,
        accessibilityDisplayShouldReduceMotion: @escaping @MainActor () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        },
        notificationCenter: NotificationCenter =
            NSWorkspace.shared.notificationCenter,
        accessibilityDisplayOptionsDidChangeNotification: Notification.Name =
            NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
    ) {
        self.accessibilityDisplayShouldReduceMotion =
            accessibilityDisplayShouldReduceMotion
        self.notificationCenter = notificationCenter
        self.accessibilityDisplayOptionsDidChangeNotification =
            accessibilityDisplayOptionsDidChangeNotification
        super.init(nibName: nil, bundle: nil)
        switch svgResult {
        case .valid:
            break // Rasterization of the sanitized XML happens in `loadView`.
        case .rejected(let diagnostic):
            self.svgDiagnostic = diagnostic
        }
        self.svgDocument = svgResult.document
    }

    private var svgDocument: SVGDocument?

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        animationTimer?.invalidate()
        if isObservingAccessibilityDisplayOptions {
            notificationCenter.removeObserver(
                self,
                name: accessibilityDisplayOptionsDidChangeNotification,
                object: nil
            )
        }
    }

    override func loadView() {
        let container = NSView()

        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        fitButton.target = self
        fitButton.action = #selector(handleFit)
        fitButton.setButtonType(.pushOnPushOff)
        fitButton.setAccessibilityLabel(previewUIStrings.string("Fit to Window", comment: "Accessibility label for the fit-to-window image preview button"))
        actualSizeButton.target = self
        actualSizeButton.action = #selector(handleActualSize)
        actualSizeButton.setButtonType(.pushOnPushOff)
        actualSizeButton.setAccessibilityLabel(previewUIStrings.string("Actual Size", comment: "Accessibility label for the actual-size image preview button"))
        zoomInButton.target = self
        zoomInButton.action = #selector(handleZoomIn)
        zoomInButton.setAccessibilityLabel(previewUIStrings.string("Zoom In", comment: "Accessibility label for the zoom-in image preview button"))
        zoomOutButton.target = self
        zoomOutButton.action = #selector(handleZoomOut)
        zoomOutButton.setAccessibilityLabel(previewUIStrings.string("Zoom Out", comment: "Accessibility label for the zoom-out image preview button"))
        transparencyButton.target = self
        transparencyButton.action = #selector(handleToggleTransparency)
        transparencyButton.state = .on
        // The checkbox's title ("Checkerboard") alone doesn't say what
        // it controls; the explicit label spells that out, and the value
        // (kept in sync in `handleToggleTransparency`) states on/off as
        // text rather than relying on the checkbox glyph alone (SPEC 14).
        transparencyButton.setAccessibilityLabel(
            previewUIStrings.string("Transparency Checkerboard Background", comment: "Accessibility label for the transparency checkerboard background toggle")
        )
        transparencyButton.setAccessibilityValue(previewUIStrings.string("On", comment: "Accessibility value indicating the transparency checkerboard background is enabled"))
        playPauseButton.target = self
        playPauseButton.action = #selector(handleTogglePlayPause)
        playPauseButton.setAccessibilityLabel(previewUIStrings.string("Pause Animation", comment: "Accessibility label for the play/pause button when the animation is playing"))
        playPauseButton.setAccessibilityValue(previewUIStrings.string("Playing", comment: "Accessibility value indicating the animated image is currently playing"))
        controls.addArrangedSubview(transparencyButton)
        if frames.count > 1 {
            controls.addArrangedSubview(playPauseButton)
        }
        controls.addArrangedSubview(fitButton)
        controls.addArrangedSubview(actualSizeButton)
        controls.addArrangedSubview(zoomOutButton)
        controls.addArrangedSubview(zoomInButton)

        checkerboardView.translatesAutoresizingMaskIntoConstraints = false

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter

        let centeredClipView = CenteredImageClipView()
        centeredClipView.drawsBackground = false
        scrollView.contentView = centeredClipView

        scrollView.documentView = imageView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 16

        metadataLabel.font = .systemFont(ofSize: 11)
        metadataLabel.textColor = .secondaryLabelColor
        metadataLabel.translatesAutoresizingMaskIntoConstraints = false
        metadataLabel.stringValue = metadataText()
        metadataLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footerSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        controls.setContentHuggingPriority(.required, for: .horizontal)
        controls.setContentCompressionResistancePriority(.required, for: .horizontal)
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.spacing = 8
        footerRow.addArrangedSubview(metadataLabel)
        footerRow.addArrangedSubview(footerSpacer)
        footerRow.addArrangedSubview(controls)
        footerRow.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(checkerboardView)
        checkerboardView.addSubview(scrollView)
        container.addSubview(footerRow)

        NSLayoutConstraint.activate([
            checkerboardView.topAnchor.constraint(equalTo: container.topAnchor),
            checkerboardView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            checkerboardView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            checkerboardView.bottomAnchor.constraint(equalTo: footerRow.topAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: checkerboardView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: checkerboardView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: checkerboardView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: checkerboardView.bottomAnchor),

            footerRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            footerRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            footerRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])

        view = container
        updateZoomControlState()
        if let svgDocument {
            applySVGDocument(svgDocument)
        } else {
            applyCurrentFrame()
        }
        metadataLabel.stringValue = metadataText()
        observeAccessibilityDisplayOptions()
        applyPlaybackPreference()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if zoomMode == .fit {
            applyZoom()
        } else {
            centerImageIfNeeded()
        }
    }

    private func metadataText() -> String {
        if let diagnostic {
            return diagnostic.message
        }
        if let svgDiagnostic {
            return svgDiagnostic.message
        }
        guard let metadata else {
            if let svgDocument {
                let width = svgDocument.intrinsicWidth.map { String(format: "%.0f", $0) } ?? "?"
                let height = svgDocument.intrinsicHeight.map { String(format: "%.0f", $0) } ?? "?"
                return previewUIStrings.string("SVG \u{2022} \(width)\u{00D7}\(height)", comment: "Metadata line for an SVG image preview showing its intrinsic width and height")
            }
            return previewUIStrings.string("No metadata available", comment: "Metadata line shown when no image metadata could be determined")
        }
        var parts = [
            "\(metadata.format.displayName)",
            previewUIStrings.string("\(metadata.pixelWidth)\u{00D7}\(metadata.pixelHeight)", comment: "Metadata line component showing an image's pixel dimensions")
        ]
        if metadata.frameCount > 1 {
            parts.append(previewUIStrings.string("\(metadata.frameCount) frames", comment: "Metadata line component showing an animated image's frame count"))
        }
        if metadata.hasAlpha {
            parts.append(previewUIStrings.string("alpha", comment: "Metadata line component indicating the image has an alpha channel"))
        }
        parts.append(previewUIStrings.string("\(metadata.fileByteCount) bytes", comment: "Metadata line component showing an image's file size in bytes"))
        return parts.joined(separator: " \u{2022} ")
    }

    private func applyCurrentFrame() {
        guard frames.indices.contains(currentFrameIndex) else {
            return
        }
        let cgImage = frames[currentFrameIndex]
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        display(NSImage(cgImage: cgImage, size: size), size: size)
    }

    private func applySVGDocument(_ document: SVGDocument) {
        guard let data = document.sanitizedXML.data(using: .utf8),
              let image = NSImage(data: data),
              image.isValid else {
            svgDiagnostic = .renderingFailed
            imageView.image = nil
            metadataLabel.stringValue = metadataText()
            return
        }

        let width = document.intrinsicWidth ?? image.size.width
        let height = document.intrinsicHeight ?? image.size.height
        guard width > 0, height > 0 else {
            svgDiagnostic = .renderingFailed
            imageView.image = nil
            metadataLabel.stringValue = metadataText()
            return
        }

        display(image, size: NSSize(width: width, height: height))
    }

    private func display(_ image: NSImage, size: NSSize) {
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: size)
        applyZoom()
    }

    private func applyZoom() {
        guard imageView.image != nil else {
            updateZoomControlState()
            return
        }

        let magnification: CGFloat
        switch zoomMode {
        case .fit:
            let viewportSize = scrollView.contentSize
            let imageSize = imageView.frame.size
            guard viewportSize.width > 0, viewportSize.height > 0,
                  imageSize.width > 0, imageSize.height > 0 else {
                return
            }
            magnification = min(
                viewportSize.width / imageSize.width,
                viewportSize.height / imageSize.height
            )
        case .actualSize:
            magnification = 1
        case .custom(let factor):
            magnification = factor
        }
        scrollView.magnification = min(max(magnification, scrollView.minMagnification), scrollView.maxMagnification)
        centerImageIfNeeded()
        updateZoomControlState()
    }

    private func centerImageIfNeeded() {
        let clipView = scrollView.contentView
        let centeredBounds = clipView.constrainBoundsRect(clipView.bounds)
        clipView.setBoundsOrigin(centeredBounds.origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    private func updateZoomControlState() {
        fitButton.state = zoomMode == .fit ? .on : .off
        actualSizeButton.state = zoomMode == .actualSize ? .on : .off

        let accessibilityValue: String
        switch zoomMode {
        case .fit:
            accessibilityValue = previewUIStrings.string("Fit to Window", comment: "Accessibility value when the image preview is fit to the window")
        case .actualSize:
            accessibilityValue = previewUIStrings.string("Actual Size", comment: "Accessibility value when the image preview is shown at actual size")
        case .custom(let factor):
            accessibilityValue = "\(Int((factor * 100).rounded()))%"
        }
        zoomInButton.setAccessibilityValue(accessibilityValue)
        zoomOutButton.setAccessibilityValue(accessibilityValue)
    }

    private func observeAccessibilityDisplayOptions() {
        guard !isObservingAccessibilityDisplayOptions else {
            return
        }
        notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        isObservingAccessibilityDisplayOptions = true
    }

    @objc
    private func accessibilityDisplayOptionsDidChange(_ notification: Notification) {
        applyPlaybackPreference()
    }

    private func applyPlaybackPreference() {
        let shouldAnimate: Bool
        switch playbackPreference {
        case .automatic:
            shouldAnimate = !accessibilityDisplayShouldReduceMotion()
        case .playing:
            shouldAnimate = true
        case .paused:
            shouldAnimate = false
        }
        isAnimating = shouldAnimate
        updatePlayPauseControl()
        if isAnimating {
            startAnimatingIfNeeded()
        } else {
            animationTimer?.invalidate()
        }
    }

    private func startAnimatingIfNeeded() {
        guard frames.count > 1, isAnimating else {
            return
        }
        scheduleNextFrame()
    }

    private func updatePlayPauseControl() {
        playPauseButton.title = isAnimating
            ? previewUIStrings.string("Pause", comment: "Play/pause button title when the animated image is currently playing")
            : previewUIStrings.string("Play", comment: "Play/pause button title when the animated image is paused")
        playPauseButton.setAccessibilityLabel(
            isAnimating
                ? previewUIStrings.string("Pause Animation", comment: "Accessibility label for the play/pause button when the animation is playing")
                : previewUIStrings.string("Play Animation", comment: "Accessibility label for the play/pause button when the animation is paused")
        )
        playPauseButton.setAccessibilityValue(
            isAnimating
                ? previewUIStrings.string("Playing", comment: "Accessibility value indicating the animated image is currently playing")
                : previewUIStrings.string("Paused", comment: "Accessibility value indicating the animated image is paused")
        )
    }

    private func scheduleNextFrame() {
        let duration = frameDurations.indices.contains(currentFrameIndex) ? max(frameDurations[currentFrameIndex], 0.02) : 0.1
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.advanceFrame()
            }
        }
    }

    private func advanceFrame() {
        guard isAnimating, !frames.isEmpty else {
            return
        }
        currentFrameIndex = (currentFrameIndex + 1) % frames.count
        applyCurrentFrame()
        scheduleNextFrame()
    }

    @objc
    private func handleFit(_ sender: Any?) {
        zoomMode = .fit
        applyZoom()
    }

    @objc
    private func handleActualSize(_ sender: Any?) {
        zoomMode = .actualSize
        applyZoom()
    }

    @objc
    private func handleZoomIn(_ sender: Any?) {
        let current = scrollView.magnification
        zoomMode = .custom(min(current * 1.25, 16))
        applyZoom()
    }

    @objc
    private func handleZoomOut(_ sender: Any?) {
        let current = scrollView.magnification
        zoomMode = .custom(max(current * 0.8, 0.05))
        applyZoom()
    }

    @objc
    private func handleToggleTransparency(_ sender: Any?) {
        showsCheckerboardBackground.toggle()
        transparencyButton.setAccessibilityValue(
            showsCheckerboardBackground
                ? previewUIStrings.string("On", comment: "Accessibility value indicating the transparency checkerboard background is enabled")
                : previewUIStrings.string("Off", comment: "Accessibility value indicating the transparency checkerboard background is disabled")
        )
    }

    @objc
    private func handleTogglePlayPause(_ sender: Any?) {
        playbackPreference = isAnimating ? .paused : .playing
        applyPlaybackPreference()
    }

    // MARK: - Test-facing state

    var frameCount: Int { frames.count }
    var isAnimationPlaying: Bool { isAnimating }

    /// Exposed so headless tests can assert on the *real* AppKit
    /// accessibility API return values (not a parallel string a test
    /// could drift from) — see `ImagePreviewViewControllerTests`.
    var zoomLevelAccessibilityValue: String? { zoomInButton.accessibilityValue() as? String }
    var transparencyAccessibilityLabel: String? { transparencyButton.accessibilityLabel() }
    var transparencyAccessibilityValue: String? { transparencyButton.accessibilityValue() as? String }
    var playPauseAccessibilityLabel: String? { playPauseButton.accessibilityLabel() }
    var playPauseAccessibilityValue: String? { playPauseButton.accessibilityValue() as? String }
    var hasRenderedImage: Bool { imageView.image != nil }
    var checkerboardPatternIsVisible: Bool {
        checkerboardView.backgroundColor(at: NSPoint(x: 6, y: 6))
            != checkerboardView.backgroundColor(at: NSPoint(x: 18, y: 6))
    }
    var checkerboardSampleColors: (NSColor, NSColor) {
        (
            checkerboardView.backgroundColor(at: NSPoint(x: 6, y: 6)),
            checkerboardView.backgroundColor(at: NSPoint(x: 18, y: 6))
        )
    }
    var controlsShareMetadataFooter: Bool {
        metadataLabel.superview === footerRow && controls.superview === footerRow
    }
    var imageCenterOffsetFromViewport: NSPoint? {
        guard imageView.image != nil else {
            return nil
        }
        let clipView = scrollView.contentView
        let imageCenter = clipView.convert(
            NSPoint(x: imageView.bounds.midX, y: imageView.bounds.midY),
            from: imageView
        )
        return NSPoint(
            x: imageCenter.x - clipView.bounds.midX,
            y: imageCenter.y - clipView.bounds.midY
        )
    }

    /// Test-facing wrappers for the footer actions, since this
    /// codebase never synthesizes real button clicks in tests (mirrors
    /// `EditorGroupViewController.togglePreviewSourceForTesting()`).
    func toggleTransparencyForTesting() { handleToggleTransparency(nil) }
    func togglePlayPauseForTesting() { handleTogglePlayPause(nil) }
    func zoomInForTesting() { handleZoomIn(nil) }
    func zoomOutForTesting() { handleZoomOut(nil) }
    func fitForTesting() { handleFit(nil) }
    func actualSizeForTesting() { handleActualSize(nil) }
}
