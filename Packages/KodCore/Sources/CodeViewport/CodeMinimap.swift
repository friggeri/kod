import AppKit
import ThemeCore

public enum CodeMinimapInvalidation: Equatable, Sendable {
    case layout
    case tokens
    case markers
    case appearance
    case selection
}

struct CodeMinimapTokenSpan: Equatable, Sendable {
    let columns: Range<Int>
    let color: ThemeColor
}

struct CodeMinimapVisualRow: Equatable, Sendable {
    let visualRow: Int
    let sourceLine: Int?
    let segmentIndex: Int?
    let utf8Range: Range<Int>?
    let text: String
    let tokenSpans: [CodeMinimapTokenSpan]
    let isViewZone: Bool
}

struct CodeMinimapPresentation: Equatable, Sendable {
    let totalVisualRows: Int
    let rows: [CodeMinimapVisualRow]
    let requestedRows: Range<Int>
}

public enum CodeMinimapDiagnosticSeverity: Equatable, Sendable {
    case information
    case warning
    case error
}

public struct CodeMinimapDiagnosticMarker: Equatable, Sendable {
    public let utf8Range: Range<Int>
    public let severity: CodeMinimapDiagnosticSeverity

    public init(utf8Range: Range<Int>, severity: CodeMinimapDiagnosticSeverity) {
        self.utf8Range = utf8Range
        self.severity = severity
    }
}

public struct CodeMinimapMarkers: Equatable, Sendable {
    public var selection: Range<Int>?
    public var findMatches: [Range<Int>]
    public var diagnostics: [CodeMinimapDiagnosticMarker]
    public var gitChanges: [CodeGutterChange]

    public init(
        selection: Range<Int>? = nil,
        findMatches: [Range<Int>] = [],
        diagnostics: [CodeMinimapDiagnosticMarker] = [],
        gitChanges: [CodeGutterChange] = []
    ) {
        self.selection = selection
        self.findMatches = findMatches
        self.diagnostics = diagnostics
        self.gitChanges = gitChanges
    }
}

enum CodeMinimapGitStyle: CaseIterable, Hashable, Sendable {
    case primaryAdded
    case primaryModified
    case primaryDeleted
    case secondaryAdded
    case secondaryModified
    case secondaryDeleted

    init(_ change: CodeGutterChange) {
        switch (change.layer, change.kind) {
        case (.primary, .added): self = .primaryAdded
        case (.primary, .modified): self = .primaryModified
        case (.primary, .deleted): self = .primaryDeleted
        case (.secondary, .added): self = .secondaryAdded
        case (.secondary, .modified): self = .secondaryModified
        case (.secondary, .deleted): self = .secondaryDeleted
        }
    }
}

struct CodeMinimapGutterMarkerSet: Equatable, Sendable {
    let lineRanges: [Range<Int>]
    let deletionAfterLines: [Int]
}

struct CodeMinimapLayout: Equatable {
    static let maximumColumns = 120
    static let minimumWidth: CGFloat = 48
    static let maximumWidth: CGFloat = 160

    let bounds: CGRect
    let backingScale: CGFloat
    let totalRows: Int
    let visibleSourceRows: CGFloat
    let sourceScrollY: CGFloat
    let maximumSourceScrollY: CGFloat
    let columns: Int
    let rowHeight: CGFloat
    let glyphWidth: CGFloat
    let visibleRowWindow: Range<Int>
    let firstVisibleRow: CGFloat
    let windowHeight: CGFloat
    let trackTravel: CGFloat
    let sliderFrame: CGRect

    init(
        bounds: CGRect,
        backingScale: CGFloat,
        totalRows: Int,
        visibleSourceRows: CGFloat,
        sourceScrollY: CGFloat,
        maximumSourceScrollY: CGFloat,
        requestedColumns: Int
    ) {
        let safeScale = backingScale.isFinite && backingScale > 0 ? backingScale : 1
        let safeWidth = bounds.width.isFinite ? max(0, bounds.width) : 0
        let safeHeight = bounds.height.isFinite ? max(0, bounds.height) : 0
        let safeTotalRows = max(0, totalRows)
        let safeVisibleRows = visibleSourceRows.isFinite ? max(0, visibleSourceRows) : 0
        let safeMaximumScroll = maximumSourceScrollY.isFinite ? max(0, maximumSourceScrollY) : 0
        let safeScroll = sourceScrollY.isFinite ? min(safeMaximumScroll, max(0, sourceScrollY)) : 0

        self.bounds = CGRect(x: bounds.minX, y: bounds.minY, width: safeWidth, height: safeHeight)
        self.backingScale = safeScale
        self.totalRows = safeTotalRows
        self.visibleSourceRows = safeVisibleRows
        self.sourceScrollY = safeScroll
        self.maximumSourceScrollY = safeMaximumScroll
        self.columns = min(Self.maximumColumns, max(1, requestedColumns))
        self.rowHeight = max(1 / safeScale, 2 / safeScale)
        self.glyphWidth = max(1 / safeScale, 1.5 / safeScale)

        let rowsPerWindow = max(1, Int(ceil(safeHeight / self.rowHeight)))
        let windowCount = min(safeTotalRows, rowsPerWindow)
        let maximumWindowStart = max(0, safeTotalRows - windowCount)
        let scrollRatio = safeMaximumScroll > 0 ? safeScroll / safeMaximumScroll : 0
        let windowStart = min(
            maximumWindowStart,
            max(0, Int((scrollRatio * CGFloat(maximumWindowStart)).rounded()))
        )
        self.visibleRowWindow = windowStart..<(windowStart + windowCount)

        let maximumFirstVisibleRow = max(0, CGFloat(safeTotalRows) - safeVisibleRows)
        let firstVisibleRow = scrollRatio * maximumFirstVisibleRow
        self.firstVisibleRow = firstVisibleRow
        let windowHeight = min(safeHeight, CGFloat(windowCount) * self.rowHeight)
        self.windowHeight = windowHeight
        let rawSliderHeight = min(windowHeight, safeVisibleRows * self.rowHeight)
        let sliderHeight: CGFloat
        if safeTotalRows == 0 || safeVisibleRows <= 0 {
            sliderHeight = windowHeight
        } else {
            sliderHeight = min(windowHeight, max(min(12, windowHeight), rawSliderHeight))
        }
        let sliderTravel = max(0, windowHeight - sliderHeight)
        self.trackTravel = sliderTravel
        let rawSliderY = (firstVisibleRow - CGFloat(windowStart)) * self.rowHeight
        let sliderY = min(sliderTravel, max(0, rawSliderY))
        self.sliderFrame = CGRect(x: 0, y: sliderY, width: safeWidth, height: sliderHeight)
    }

    static func recommendedWidth(containerWidth: CGFloat, requestedColumns: Int) -> CGFloat {
        guard containerWidth.isFinite, containerWidth > 0 else {
            return minimumWidth
        }
        let columns = min(maximumColumns, max(24, requestedColumns))
        let desired = CGFloat(columns) * 1.5 + 12
        return min(maximumWidth, max(minimumWidth, min(containerWidth * 0.18, desired)))
    }

    func sourceScrollY(centeredAtMinimapY y: CGFloat) -> CGFloat {
        guard bounds.height > 0, maximumSourceScrollY > 0, totalRows > 1 else {
            return 0
        }
        let targetRow = min(
            CGFloat(totalRows - 1),
            max(
                0,
                CGFloat(visibleRowWindow.lowerBound)
                    + min(bounds.height, max(0, y)) / rowHeight
            )
        )
        let maximumFirstVisibleRow = max(0, CGFloat(totalRows) - visibleSourceRows)
        guard maximumFirstVisibleRow > 0 else {
            return 0
        }
        let targetFirstVisibleRow = min(
            maximumFirstVisibleRow,
            max(0, targetRow - visibleSourceRows / 2)
        )
        let ratio = targetFirstVisibleRow / maximumFirstVisibleRow
        return ratio * maximumSourceScrollY
    }

    func sourceScrollY(draggingSliderFrom initialScrollY: CGFloat, deltaY: CGFloat) -> CGFloat {
        guard trackTravel > 0, maximumSourceScrollY > 0 else {
            return 0
        }
        let result = initialScrollY + (deltaY / trackTravel) * maximumSourceScrollY
        return min(maximumSourceScrollY, max(0, result))
    }

    func y(forVisualRow row: Int) -> CGFloat {
        y(forVisualRow: CGFloat(row))
    }

    func y(forVisualRow row: CGFloat) -> CGFloat {
        (row - CGFloat(visibleRowWindow.lowerBound)) * rowHeight
    }
}

struct CodeMinimapGlyph: Equatable, Sendable {
    let columns: Int
    let mask: UInt8
}

/// Tiny deterministic masks avoid asking Core Text to shape thousands of
/// miniature glyphs per scroll. Printable ASCII is cached; other graphemes
/// use a visible fallback while East Asian full-width characters consume two
/// columns.
final class CodeMinimapGlyphAtlas: @unchecked Sendable {
    static let shared = CodeMinimapGlyphAtlas()

    private let ascii: [CodeMinimapGlyph]
    let unknown = CodeMinimapGlyph(columns: 1, mask: 0b111)

    private init() {
        ascii = (32...126).map { scalar in
            if scalar == 32 {
                return CodeMinimapGlyph(columns: 1, mask: 0)
            }
            let folded = UInt8(truncatingIfNeeded: scalar)
            let mask = (folded ^ (folded >> 3)) & 0b111
            return CodeMinimapGlyph(columns: 1, mask: mask == 0 ? 0b101 : mask)
        }
    }

    func glyph(for character: Character) -> CodeMinimapGlyph {
        guard let scalar = character.unicodeScalars.first else {
            return unknown
        }
        if character.unicodeScalars.count == 1, (32...126).contains(Int(scalar.value)) {
            return ascii[Int(scalar.value) - 32]
        }
        return CodeMinimapGlyph(
            columns: scalar.properties.isEmojiPresentation || Self.isFullWidth(scalar.value) ? 2 : 1,
            mask: unknown.mask
        )
    }

    private static func isFullWidth(_ value: UInt32) -> Bool {
        (0x1100...0x115F).contains(value)
            || (0x2E80...0xA4CF).contains(value)
            || (0xAC00...0xD7A3).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0xFE10...0xFE6F).contains(value)
            || (0xFF00...0xFF60).contains(value)
            || (0x1F300...0x1FAFF).contains(value)
    }
}

@MainActor
final class CodeMinimapRenderer {
    static let maximumBackgroundOpacity: CGFloat = 0.5

    private var buffers: [NSImage?] = [nil, nil]
    private var frontBufferIndex = 0
    private(set) var generation = 0
    private(set) var renderCount = 0
    private(set) var bufferPixelSize = CGSize.zero
    private(set) var renderedBackingScale: CGFloat?
    private var renderedRowWindow: Range<Int>?
    private var renderedColumns: Int?

    var image: NSImage? {
        buffers[frontBufferIndex]
    }

    func invalidate() {
        generation &+= 1
    }

    func isCompatible(with layout: CodeMinimapLayout) -> Bool {
        image?.size == layout.bounds.size
            && renderedBackingScale == layout.backingScale
            && renderedRowWindow == layout.visibleRowWindow
            && renderedColumns == layout.columns
            && bufferPixelSize == CGSize(
                width: ceil(layout.bounds.width * layout.backingScale),
                height: ceil(layout.bounds.height * layout.backingScale)
            )
    }

    func render(
        presentation: CodeMinimapPresentation,
        layout: CodeMinimapLayout,
        theme: KodTheme
    ) {
        generation &+= 1
        renderCount &+= 1
        let renderGeneration = generation
        guard layout.bounds.width > 0, layout.bounds.height > 0 else {
            buffers = [nil, nil]
            bufferPixelSize = .zero
            renderedBackingScale = nil
            renderedRowWindow = nil
            renderedColumns = nil
            return
        }

        guard let surface = Self.makeSurface(for: layout) else {
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = surface.graphicsContext
        defer { NSGraphicsContext.restoreGraphicsState() }

        theme.minimap.background.nsColor.withAlphaComponent(
            min(Self.maximumBackgroundOpacity, CGFloat(theme.minimap.background.alpha))
        ).setFill()
        NSRect(origin: .zero, size: layout.bounds.size).fill()
        let atlas = CodeMinimapGlyphAtlas.shared
        var resolvedColors: [ThemeColor: NSColor] = [:]

        func rasterColor(_ color: ThemeColor) -> NSColor {
            if let cached = resolvedColors[color] {
                return cached
            }
            let resolved = color.nsColor.withAlphaComponent(
                CGFloat(color.alpha * theme.minimap.foregroundOpacity)
            )
            resolvedColors[color] = resolved
            return resolved
        }

        for row in presentation.rows where !row.isViewZone {
            let y = layout.y(forVisualRow: row.visualRow)
            guard y >= -layout.rowHeight, y <= layout.bounds.height else {
                continue
            }
            var column = 0
            var spanIndex = 0
            for character in row.text {
                if character == "\t" {
                    column += 4 - (column % 4)
                    continue
                }
                let glyph = atlas.glyph(for: character)
                guard column < layout.columns else {
                    break
                }
                while spanIndex + 1 < row.tokenSpans.count,
                      row.tokenSpans[spanIndex].columns.upperBound <= column {
                    spanIndex += 1
                }
                let baseColor = row.tokenSpans.indices.contains(spanIndex)
                    && row.tokenSpans[spanIndex].columns.contains(column)
                    ? row.tokenSpans[spanIndex].color
                    : theme.editor.foreground
                rasterColor(baseColor).setFill()
                let x = 4 + CGFloat(column) * layout.glyphWidth
                if glyph.mask & 0b001 != 0 {
                    NSRect(x: x, y: y, width: max(1 / layout.backingScale, layout.glyphWidth), height: 1 / layout.backingScale).fill()
                }
                if glyph.mask & 0b010 != 0 {
                    NSRect(x: x, y: y + layout.rowHeight / 2, width: max(1 / layout.backingScale, layout.glyphWidth), height: 1 / layout.backingScale).fill()
                }
                if glyph.mask & 0b100 != 0 {
                    NSRect(x: x, y: y + layout.rowHeight - 1 / layout.backingScale, width: max(1 / layout.backingScale, layout.glyphWidth), height: 1 / layout.backingScale).fill()
                }
                column += glyph.columns
            }
        }

        guard renderGeneration == generation else {
            return
        }
        guard let cgImage = surface.context.makeImage() else {
            return
        }
        let image = NSImage(cgImage: cgImage, size: layout.bounds.size)
        let backBufferIndex = 1 - frontBufferIndex
        buffers[backBufferIndex] = image
        frontBufferIndex = backBufferIndex
        bufferPixelSize = CGSize(
            width: CGFloat(surface.pixelWidth),
            height: CGFloat(surface.pixelHeight)
        )
        renderedBackingScale = layout.backingScale
        renderedRowWindow = layout.visibleRowWindow
        renderedColumns = layout.columns
    }

    static func makeSurface(
        for layout: CodeMinimapLayout
    ) -> (
        context: CGContext,
        graphicsContext: NSGraphicsContext,
        pixelWidth: Int,
        pixelHeight: Int
    )? {
        let pixelWidth = max(1, Int(ceil(layout.bounds.width * layout.backingScale)))
        let pixelHeight = max(1, Int(ceil(layout.bounds.height * layout.backingScale)))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: pixelWidth * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: layout.backingScale, y: -layout.backingScale)
        return (
            context,
            NSGraphicsContext(cgContext: context, flipped: true),
            pixelWidth,
            pixelHeight
        )
    }
}

@MainActor
public final class CodeMinimapView: NSView {
    public static let maximumColumns = CodeMinimapLayout.maximumColumns

    private weak var viewport: CodeViewport?
    private weak var scrollView: NSScrollView?
    private let renderer = CodeMinimapRenderer()
    private var markers = CodeMinimapMarkers()
    private var mergedFindRanges: [Range<Int>] = []
    private var mergedDiagnosticRanges: [CodeMinimapDiagnosticSeverity: [Range<Int>]] = [:]
    private var gutterMarkerSets: [CodeMinimapGitStyle: CodeMinimapGutterMarkerSet] = [:]
    private(set) var markerCacheRebuildCount = 0
    private var isHovering = false
    private var dragStart: (point: NSPoint, scrollY: CGFloat)?
    private var trackingArea: NSTrackingArea?
    private var baseIsDirty = true

    init(viewport: CodeViewport, scrollView: NSScrollView) {
        self.viewport = viewport
        self.scrollView = scrollView
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("code.minimap")
        setAccessibilityElement(false)
        postsFrameChangedNotifications = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { false }
    public override var acceptsFirstResponder: Bool { false }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        invalidate(.appearance)
    }

    public func updateMarkers(_ markers: CodeMinimapMarkers) {
        guard self.markers != markers else {
            return
        }
        updateSelection(markers.selection)
        updateMarkerCollections(
            findMatches: markers.findMatches,
            diagnostics: markers.diagnostics,
            gitChanges: markers.gitChanges
        )
    }

    func updateSelection(_ selection: Range<Int>?) {
        guard markers.selection != selection else {
            return
        }
        markers.selection = selection
        needsDisplay = true
    }

    func updateMarkerCollections(
        findMatches: [Range<Int>],
        diagnostics: [CodeMinimapDiagnosticMarker],
        gitChanges: [CodeGutterChange]
    ) {
        let findChanged = markers.findMatches != findMatches
        let diagnosticsChanged = markers.diagnostics != diagnostics
        let gitChanged = markers.gitChanges != gitChanges
        guard findChanged || diagnosticsChanged || gitChanged else {
            return
        }
        markerCacheRebuildCount &+= 1
        if findChanged {
            markers.findMatches = findMatches
            mergedFindRanges = Self.merge(
                markerRanges: Self.normalized(markerRanges: findMatches, utf8Count: viewport?.snapshot.utf8Count ?? 0)
            )
        }
        if diagnosticsChanged {
            markers.diagnostics = diagnostics
            let utf8Count = viewport?.snapshot.utf8Count ?? 0
            mergedDiagnosticRanges = Dictionary(
                uniqueKeysWithValues: [
                    CodeMinimapDiagnosticSeverity.information,
                    .warning,
                    .error
                ].map { severity in
                    (
                        severity,
                        Self.merge(markerRanges: Self.normalized(
                            markerRanges: diagnostics.compactMap {
                                $0.severity == severity ? $0.utf8Range : nil
                            },
                            utf8Count: utf8Count
                        ))
                    )
                }
            )
        }
        if gitChanged {
            markers.gitChanges = gitChanges
            gutterMarkerSets = Dictionary(
                uniqueKeysWithValues: CodeMinimapGitStyle.allCases.map { style in
                    let changes = gitChanges.filter { CodeMinimapGitStyle($0) == style }
                    return (
                        style,
                        CodeMinimapGutterMarkerSet(
                            lineRanges: Self.merge(lineRanges: changes.compactMap {
                                if case .lines(let range) = $0.location {
                                    return range
                                }
                                return nil
                            }),
                            deletionAfterLines: changes.compactMap {
                                if case .deletion(let afterLine) = $0.location {
                                    return afterLine
                                }
                                return nil
                            }.sorted()
                        )
                    )
                }
            )
        }
        needsDisplay = true
    }

    var currentMarkers: CodeMinimapMarkers {
        markers
    }

    var baseRenderCount: Int {
        renderer.renderCount
    }

    func cachedDiagnosticRanges(
        for severity: CodeMinimapDiagnosticSeverity
    ) -> [Range<Int>] {
        mergedDiagnosticRanges[severity] ?? []
    }

    func snapshotImage(layout: CodeMinimapLayout) -> NSImage? {
        guard let viewport,
              let surface = CodeMinimapRenderer.makeSurface(for: layout) else {
            return nil
        }
        if !renderer.isCompatible(with: layout) {
            renderer.render(
                presentation: viewport.minimapPresentation(
                    visualRows: layout.visibleRowWindow,
                    maxColumns: layout.columns
                ),
                layout: layout,
                theme: viewport.theme
            )
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = surface.graphicsContext
        surface.graphicsContext.imageInterpolation = .none
        renderer.image?.draw(in: NSRect(origin: .zero, size: layout.bounds.size))
        drawOverlays(layout: layout, viewport: viewport)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = surface.context.makeImage() else {
            return nil
        }
        return NSImage(cgImage: image, size: layout.bounds.size)
    }

    func invalidate(_ invalidation: CodeMinimapInvalidation) {
        switch invalidation {
        case .layout, .tokens, .appearance:
            baseIsDirty = true
            renderer.invalidate()
        case .markers, .selection:
            break
        }
        needsDisplay = true
    }

    func viewportDidScroll() {
        needsDisplay = true
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    public override func mouseExited(with event: NSEvent) {
        guard dragStart == nil else {
            return
        }
        isHovering = false
        needsDisplay = true
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let layout = currentLayout()
        if layout.sliderFrame.contains(point) {
            dragStart = (point, scrollView?.contentView.bounds.minY ?? 0)
            NSCursor.closedHand.push()
        } else {
            scroll(to: layout.sourceScrollY(centeredAtMinimapY: point.y), centerViewport: false)
        }
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let dragStart else {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let target = currentLayout().sourceScrollY(
            draggingSliderFrom: dragStart.scrollY,
            deltaY: point.y - dragStart.point.y
        )
        scroll(to: target, centerViewport: false)
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        if dragStart != nil {
            NSCursor.pop()
        }
        dragStart = nil
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let viewport else {
            return
        }
        let layout = currentLayout()
        if baseIsDirty || !renderer.isCompatible(with: layout) {
            let presentation = viewport.minimapPresentation(
                visualRows: layout.visibleRowWindow,
                maxColumns: layout.columns
            )
            renderer.render(presentation: presentation, layout: layout, theme: viewport.theme)
            baseIsDirty = false
        }
        renderer.image?.draw(in: bounds)
        drawOverlays(layout: layout, viewport: viewport)
    }

    private func currentLayout() -> CodeMinimapLayout {
        guard let viewport, let scrollView else {
            return CodeMinimapLayout(
                bounds: bounds,
                backingScale: window?.backingScaleFactor ?? 1,
                totalRows: 0,
                visibleSourceRows: 0,
                sourceScrollY: 0,
                maximumSourceScrollY: 0,
                requestedColumns: 1
            )
        }
        let visibleHeight = scrollView.contentView.bounds.height
        let maximumScroll = max(0, viewport.frame.height - visibleHeight)
        return CodeMinimapLayout(
            bounds: bounds,
            backingScale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1,
            totalRows: viewport.minimapTotalVisualRows,
            visibleSourceRows: visibleHeight / max(1, viewport.minimapLineHeight),
            sourceScrollY: scrollView.contentView.bounds.minY,
            maximumSourceScrollY: maximumScroll,
            requestedColumns: viewport.minimapMaximumRenderedColumns
        )
    }

    private func scroll(to targetY: CGFloat, centerViewport: Bool) {
        guard let viewport, let clipView = scrollView?.contentView else {
            return
        }
        let centered = centerViewport ? targetY - clipView.bounds.height / 2 : targetY
        let maximum = max(0, viewport.frame.height - clipView.bounds.height)
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: min(maximum, max(0, centered))))
        scrollView?.reflectScrolledClipView(clipView)
    }

    private func drawOverlays(layout: CodeMinimapLayout, viewport: CodeViewport) {
        let colors = viewport.theme.minimap

        if let selection = markers.selection {
            colors.selection.nsColor.setFill()
            for row in viewport.minimapVisualRows(
                forUTF8Ranges: [selection],
                limitedTo: layout.visibleRowWindow
            ) {
                rowRect(row, layout: layout, inset: 0).fill()
            }
        }

        colors.find.nsColor.setFill()
        for row in viewport.minimapVisualRows(
            forUTF8Ranges: mergedFindRanges,
            limitedTo: layout.visibleRowWindow
        ) {
            rowRect(row, layout: layout, inset: 8).fill()
        }

        for severity in [
            CodeMinimapDiagnosticSeverity.information,
            .warning,
            .error
        ] {
            switch severity {
            case .information:
                colors.information.nsColor.setFill()
            case .warning:
                colors.warning.nsColor.setFill()
            case .error:
                colors.error.nsColor.setFill()
            }
            for row in viewport.minimapVisualRows(
                forUTF8Ranges: mergedDiagnosticRanges[severity] ?? [],
                limitedTo: layout.visibleRowWindow
            ) {
                rowRect(row, layout: layout, inset: 3).fill()
            }
        }

        for style in CodeMinimapGitStyle.allCases {
            let color: ThemeColor
            switch style {
            case .primaryAdded: color = colors.gutterAdded
            case .primaryModified: color = colors.gutterModified
            case .primaryDeleted: color = colors.gutterDeleted
            case .secondaryAdded: color = colors.secondaryGutterAdded
            case .secondaryModified: color = colors.secondaryGutterModified
            case .secondaryDeleted: color = colors.secondaryGutterDeleted
            }
            color.nsColor.setFill()
            for row in viewport.minimapVisualRows(
                forGutterMarkers: gutterMarkerSets[style]
                    ?? CodeMinimapGutterMarkerSet(lineRanges: [], deletionAfterLines: []),
                limitedTo: layout.visibleRowWindow
            ) {
                let y = layout.y(forVisualRow: row)
                NSRect(x: max(0, bounds.width - 3), y: y, width: 3, height: max(1, layout.rowHeight)).fill()
            }
        }

        if isHovering || dragStart != nil {
            let sliderColor = dragStart != nil ? colors.sliderActive : colors.sliderHover
            sliderColor.nsColor.setFill()
            layout.sliderFrame.fill()
        }
    }

    private func rowRect(_ row: Int, layout: CodeMinimapLayout, inset: CGFloat) -> NSRect {
        NSRect(
            x: inset,
            y: layout.y(forVisualRow: row),
            width: max(1, bounds.width - inset - 4),
            height: max(1, layout.rowHeight)
        )
    }

    private static func merge(markerRanges: [Range<Int>]) -> [Range<Int>] {
        let sorted = markerRanges.sorted {
            ($0.lowerBound, $0.upperBound) < ($1.lowerBound, $1.upperBound)
        }
        var merged: [Range<Int>] = []
        merged.reserveCapacity(sorted.count)
        for range in sorted {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }
            if range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(
                    last.upperBound,
                    range.upperBound
                )
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private static func normalized(
        markerRanges: [Range<Int>],
        utf8Count: Int
    ) -> [Range<Int>] {
        markerRanges.compactMap { range in
            let lower = min(utf8Count, max(0, range.lowerBound))
            let upper = min(utf8Count, max(lower, range.upperBound))
            if lower < upper {
                return lower..<upper
            }
            guard utf8Count > 0 else {
                return nil
            }
            if lower < utf8Count {
                return lower..<(lower + 1)
            }
            return (utf8Count - 1)..<utf8Count
        }
    }

    private static func merge(lineRanges: [Range<Int>]) -> [Range<Int>] {
        let sorted = lineRanges.sorted {
            ($0.lowerBound, $0.upperBound) < ($1.lowerBound, $1.upperBound)
        }
        var merged: [Range<Int>] = []
        for range in sorted where !range.isEmpty {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }
            if range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(
                    last.upperBound,
                    range.upperBound
                )
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
