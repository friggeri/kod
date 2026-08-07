import AppKit
import PreviewCore

/// How the image is currently scaled inside its scroll view (SPEC 10.2:
/// "Fit, actual size, zoom, pan, transparency background").
enum ImagePreviewZoomMode: Equatable {
    case fit
    case actualSize
    case custom(CGFloat)
}

/// The built-in image preview: fit/actual-size/zoom/pan, an optional
/// transparency checkerboard background, safe (decode-limited, non-
/// animated-by-default) frame display, and a read-only metadata panel.
/// Only ever receives bytes already decoded by `PreviewCore.ImageDecoder`
/// (raster formats) or `SVGDocumentLoader` (SVG) — this type never parses
/// or fetches anything itself.
@MainActor
final class ImagePreviewViewController: NSViewController {
    private let scrollView = NSScrollView()
    private let imageView = NSImageView()
    private let checkerboardView = NSView()
    private let metadataLabel = NSTextField(wrappingLabelWithString: "")
    private let toolbar = NSStackView()
    private let fitButton = NSButton(title: Localized.string("Fit", comment: "Button title to fit the image preview to the window"), target: nil, action: nil)
    private let actualSizeButton = NSButton(
        title: Localized.string("Actual Size", comment: "Button title to show the image preview at its actual pixel size"),
        target: nil,
        action: nil
    )
    private let zoomInButton = NSButton(title: "+", target: nil, action: nil) // audit-exempt: symbolic glyph, not prose (accessibility label is localized separately)
    private let zoomOutButton = NSButton(title: "\u{2212}", target: nil, action: nil) // audit-exempt: symbolic glyph, not prose (accessibility label is localized separately)
    private let transparencyButton = NSButton(
        checkboxWithTitle: Localized.string("Checkerboard", comment: "Checkbox toggling the transparency checkerboard background in image preview"),
        target: nil,
        action: nil
    )
    private let playPauseButton = NSButton(title: Localized.string("Pause", comment: "Initial title of the animated-image play/pause button"), target: nil, action: nil)
    /// Textual "Zoom: Fit"/"Zoom: 125%" readout — SPEC 14 needs the
    /// current zoom state exposed as a real value, and there was
    /// previously no visible (or accessible) indication of the actual
    /// zoom level at all beyond the +/- buttons themselves.
    private let zoomModeLabel = NSTextField(labelWithString: "")

    private(set) var metadata: ImageMetadata?
    private(set) var diagnostic: ImageDecodeDiagnostic?
    private(set) var svgDiagnostic: SVGDiagnostic?
    private(set) var zoomMode: ImagePreviewZoomMode = .fit
    private(set) var isAnimating = true
    private(set) var currentFrameIndex = 0

    private var frames: [CGImage] = []
    private var frameDurations: [Double] = []
    private nonisolated(unsafe) var animationTimer: Timer?
    private var showsCheckerboardBackground = true {
        didSet { checkerboardView.needsDisplay = true }
    }

    /// Constructs from an already-decoded raster result.
    init(decodeResult: ImageDecodeResult) {
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
    init(svgResult: SVGDocumentResult) {
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
    }

    override func loadView() {
        let container = NSView()

        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        fitButton.target = self
        fitButton.action = #selector(handleFit)
        fitButton.setAccessibilityLabel(Localized.string("Fit to Window", comment: "Accessibility label for the fit-to-window image preview button"))
        actualSizeButton.target = self
        actualSizeButton.action = #selector(handleActualSize)
        actualSizeButton.setAccessibilityLabel(Localized.string("Actual Size", comment: "Accessibility label for the actual-size image preview button"))
        zoomInButton.target = self
        zoomInButton.action = #selector(handleZoomIn)
        zoomInButton.setAccessibilityLabel(Localized.string("Zoom In", comment: "Accessibility label for the zoom-in image preview button"))
        zoomOutButton.target = self
        zoomOutButton.action = #selector(handleZoomOut)
        zoomOutButton.setAccessibilityLabel(Localized.string("Zoom Out", comment: "Accessibility label for the zoom-out image preview button"))
        transparencyButton.target = self
        transparencyButton.action = #selector(handleToggleTransparency)
        transparencyButton.state = .on
        // The checkbox's title ("Checkerboard") alone doesn't say what
        // it controls; the explicit label spells that out, and the value
        // (kept in sync in `handleToggleTransparency`) states on/off as
        // text rather than relying on the checkbox glyph alone (SPEC 14).
        transparencyButton.setAccessibilityLabel(
            Localized.string("Transparency Checkerboard Background", comment: "Accessibility label for the transparency checkerboard background toggle")
        )
        transparencyButton.setAccessibilityValue(Localized.string("On", comment: "Accessibility value indicating the transparency checkerboard background is enabled"))
        playPauseButton.target = self
        playPauseButton.action = #selector(handleTogglePlayPause)
        playPauseButton.setAccessibilityLabel(Localized.string("Pause Animation", comment: "Accessibility label for the play/pause button when the animation is playing"))
        playPauseButton.setAccessibilityValue(Localized.string("Playing", comment: "Accessibility value indicating the animated image is currently playing"))
        zoomModeLabel.font = .systemFont(ofSize: 11)
        zoomModeLabel.textColor = .secondaryLabelColor
        zoomModeLabel.stringValue = zoomModeText()
        zoomModeLabel.setAccessibilityLabel(Localized.string("Zoom level", comment: "Accessibility label for the zoom-level readout in image preview"))
        toolbar.addArrangedSubview(fitButton)
        toolbar.addArrangedSubview(actualSizeButton)
        toolbar.addArrangedSubview(zoomOutButton)
        toolbar.addArrangedSubview(zoomInButton)
        toolbar.addArrangedSubview(zoomModeLabel)
        toolbar.addArrangedSubview(transparencyButton)
        if frames.count > 1 {
            toolbar.addArrangedSubview(playPauseButton)
        }
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        checkerboardView.wantsLayer = true
        checkerboardView.translatesAutoresizingMaskIntoConstraints = false

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = imageView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.allowsMagnification = true

        metadataLabel.font = .systemFont(ofSize: 11)
        metadataLabel.textColor = .secondaryLabelColor
        metadataLabel.translatesAutoresizingMaskIntoConstraints = false
        metadataLabel.stringValue = metadataText()

        container.addSubview(toolbar)
        container.addSubview(checkerboardView)
        checkerboardView.addSubview(scrollView)
        container.addSubview(metadataLabel)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),

            checkerboardView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            checkerboardView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            checkerboardView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            checkerboardView.bottomAnchor.constraint(equalTo: metadataLabel.topAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: checkerboardView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: checkerboardView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: checkerboardView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: checkerboardView.bottomAnchor),

            metadataLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            metadataLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            metadataLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])

        view = container
        applyCurrentFrame()
        startAnimatingIfNeeded()
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
                return Localized.string("SVG \u{2022} \(width)\u{00D7}\(height)", comment: "Metadata line for an SVG image preview showing its intrinsic width and height")
            }
            return Localized.string("No metadata available", comment: "Metadata line shown when no image metadata could be determined")
        }
        var parts = [
            "\(metadata.format.displayName)",
            Localized.string("\(metadata.pixelWidth)\u{00D7}\(metadata.pixelHeight)", comment: "Metadata line component showing an image's pixel dimensions")
        ]
        if metadata.frameCount > 1 {
            parts.append(Localized.string("\(metadata.frameCount) frames", comment: "Metadata line component showing an animated image's frame count"))
        }
        if metadata.hasAlpha {
            parts.append(Localized.string("alpha", comment: "Metadata line component indicating the image has an alpha channel"))
        }
        parts.append(Localized.string("\(metadata.fileByteCount) bytes", comment: "Metadata line component showing an image's file size in bytes"))
        return parts.joined(separator: " \u{2022} ")
    }

    private func applyCurrentFrame() {
        guard frames.indices.contains(currentFrameIndex) else {
            return
        }
        let cgImage = frames[currentFrameIndex]
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        imageView.image = NSImage(cgImage: cgImage, size: size)
        applyZoom()
    }

    private func applyZoom() {
        switch zoomMode {
        case .fit:
            scrollView.magnification = 1
            imageView.imageScaling = .scaleProportionallyUpOrDown
        case .actualSize:
            scrollView.magnification = 1
            imageView.imageScaling = .scaleNone
        case .custom(let factor):
            scrollView.magnification = factor
        }
        zoomModeLabel.stringValue = zoomModeText()
        zoomModeLabel.setAccessibilityValue(zoomModeText())
    }

    private func zoomModeText() -> String {
        switch zoomMode {
        case .fit:
            return Localized.string("Zoom: Fit to Window", comment: "Zoom-level readout when the image preview is fit to the window")
        case .actualSize:
            return Localized.string("Zoom: Actual Size", comment: "Zoom-level readout when the image preview is shown at actual size")
        case .custom(let factor):
            return Localized.string("Zoom: \(Int((factor * 100).rounded()))%", comment: "Zoom-level readout showing the current zoom percentage")
        }
    }

    private func startAnimatingIfNeeded() {
        guard frames.count > 1, isAnimating else {
            return
        }
        scheduleNextFrame()
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
        let current: CGFloat
        if case .custom(let factor) = zoomMode { current = factor } else { current = 1 }
        zoomMode = .custom(min(current * 1.25, 16))
        applyZoom()
    }

    @objc
    private func handleZoomOut(_ sender: Any?) {
        let current: CGFloat
        if case .custom(let factor) = zoomMode { current = factor } else { current = 1 }
        zoomMode = .custom(max(current * 0.8, 0.05))
        applyZoom()
    }

    @objc
    private func handleToggleTransparency(_ sender: Any?) {
        showsCheckerboardBackground.toggle()
        transparencyButton.setAccessibilityValue(
            showsCheckerboardBackground
                ? Localized.string("On", comment: "Accessibility value indicating the transparency checkerboard background is enabled")
                : Localized.string("Off", comment: "Accessibility value indicating the transparency checkerboard background is disabled")
        )
    }

    @objc
    private func handleTogglePlayPause(_ sender: Any?) {
        isAnimating.toggle()
        playPauseButton.title = isAnimating
            ? Localized.string("Pause", comment: "Play/pause button title when the animated image is currently playing")
            : Localized.string("Play", comment: "Play/pause button title when the animated image is currently paused")
        playPauseButton.setAccessibilityLabel(
            isAnimating
                ? Localized.string("Pause Animation", comment: "Accessibility label for the play/pause button when the animation is playing")
                : Localized.string("Play Animation", comment: "Accessibility label for the play/pause button when the animation is paused")
        )
        playPauseButton.setAccessibilityValue(
            isAnimating
                ? Localized.string("Playing", comment: "Accessibility value indicating the animated image is currently playing")
                : Localized.string("Paused", comment: "Accessibility value indicating the animated image is currently paused")
        )
        if isAnimating {
            scheduleNextFrame()
        } else {
            animationTimer?.invalidate()
        }
    }

    // MARK: - Test-facing state

    var frameCount: Int { frames.count }

    /// Exposed so headless tests can assert on the *real* AppKit
    /// accessibility API return values (not a parallel string a test
    /// could drift from) — see `ImagePreviewViewControllerTests`.
    var zoomLevelAccessibilityValue: String? { zoomModeLabel.accessibilityValue() }
    var transparencyAccessibilityLabel: String? { transparencyButton.accessibilityLabel() }
    var transparencyAccessibilityValue: String? { transparencyButton.accessibilityValue() as? String }
    var playPauseAccessibilityLabel: String? { playPauseButton.accessibilityLabel() }
    var playPauseAccessibilityValue: String? { playPauseButton.accessibilityValue() as? String }

    /// Test-facing wrappers for the toolbar actions, since this
    /// codebase never synthesizes real button clicks in tests (mirrors
    /// `EditorGroupViewController.togglePreviewSourceForTesting()`).
    func toggleTransparencyForTesting() { handleToggleTransparency(nil) }
    func togglePlayPauseForTesting() { handleTogglePlayPause(nil) }
    func zoomInForTesting() { handleZoomIn(nil) }
    func zoomOutForTesting() { handleZoomOut(nil) }
    func actualSizeForTesting() { handleActualSize(nil) }
}
