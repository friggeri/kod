import AppKit
import CoreText
import FontCore
import SourceModel
import SyntaxCore
import TextDecorationModel
import ThemeCore

public struct CodeViewportSelectionState: Equatable, Sendable {
    public let selectedUTF8Range: Range<Int>?
    public let focusedUTF8Offset: Int

    public init(
        selectedUTF8Range: Range<Int>?,
        focusedUTF8Offset: Int
    ) {
        self.selectedUTF8Range = selectedUTF8Range
        self.focusedUTF8Offset = focusedUTF8Offset
    }
}

@MainActor
public final class CodeViewport: NSView {
    public let snapshot: SourceSnapshot
    public let language: SyntaxLanguage?

    public private(set) var selectedUTF8Range: Range<Int>?
    public private(set) var focusedUTF8Offset = 0
    public private(set) var hoveredLinkUTF8Range: Range<Int>?

    /// Editor-level language intelligence hooks. `CodeViewport` reports
    /// source positions without depending on LanguageClient; the owning app
    /// decides which workspace service handles the request.
    public var onCommandClick: ((Int) -> Void)?
    public var onHover: ((Int, Range<Int>, NSRect) -> Void)?
    public var onHoverExit: (() -> Void)?
    public var onGutterChangeClick: ((String) -> Void)?
    public var onCancelEmbeddedViewZone: (() -> Bool)?
    public var onSelectionStateChange: ((CodeViewportSelectionState) -> Void)?
    var onMinimapInvalidation: ((CodeMinimapInvalidation) -> Void)?

    public var selectionState: CodeViewportSelectionState {
        CodeViewportSelectionState(
            selectedUTF8Range: selectedUTF8Range,
            focusedUTF8Offset: focusedUTF8Offset
        )
    }

    /// Off by default. When enabled for a file under the 10 MB safety-mode
    /// threshold, long lines wrap to the viewport width; safety-mode files
    /// keep unwrapped rendering so the fast path is never weakened.
    public var wordWrapEnabled = false {
        didSet {
            guard oldValue != wordWrapEnabled else {
                return
            }
            invalidateWrapCache()
            updateDocumentSize()
            needsDisplay = true
            onMinimapInvalidation?(.layout)
        }
    }

    /// The active theme. Changing it recolors already-computed syntax
    /// captures immediately (SPEC 7.2: "Theme switching updates the
    /// visible UI immediately") without re-parsing or re-querying.
    public var theme: KodTheme {
        didSet {
            guard theme != oldValue else {
                return
            }
            reapplyLexicalLayerForThemeChange()
            invalidateWrapCache()
            needsDisplay = true
            onMinimapInvalidation?(.appearance)
        }
    }

    /// The active font settings. Changing them re-resolves the concrete
    /// `NSFont` (including its fallback cascade) and re-lays-out affected
    /// lines live, per SPEC 7.3, without mutating `snapshot`.
    public var fontSettings: FontSettings {
        didSet {
            guard fontSettings != oldValue else {
                return
            }
            applyFontSettings()
        }
    }

    public private(set) var fontAlignmentWarning: String?

    private var resolvedFont: ResolvedFont
    private var boldFont = NSFont.systemFont(ofSize: 13)
    private var italicFont = NSFont.systemFont(ofSize: 13)
    private var boldItalicFont = NSFont.systemFont(ofSize: 13)
    /// Not `private`: `CodeViewportAccessibility.swift` reuses this to
    /// compute per-line/per-annotation `accessibilityFrame()` rectangles
    /// without duplicating the line-height math.
    var lineHeight: CGFloat = 20
    private var characterWidth: CGFloat = 8
    private var anchorUTF8Offset: Int?
    private var currentHoverUTF8Offset: Int?
    private var currentModifierFlags: NSEvent.ModifierFlags = []
    private(set) var isFoldIndicatorLaneHovered = false
    private var hoverTrackingArea: NSTrackingArea?
    private var lineCache: [Int: CTLine] = [:]
    private var minimumViewportWidth: CGFloat = 0
    private var gutterModel = GutterModel()
    var gutterChanges: [CodeGutterChange] {
        gutterModel.changes
    }
    var embeddedViewZone: CodeEmbeddedViewZone?

    /// Accessibility-only annotation metadata (symbols, diagnostics,
    /// references, git changes) driving the custom VoiceOver rotors in
    /// `CodeViewportAccessibility.swift`. Deliberately kept separate from
    /// `decorationState`'s visual decoration layers (SPEC 7.1): one
    /// pipeline paints pixels, this one narrates document structure to
    /// assistive technology, and conflating them would force every
    /// visual-only decoration update to also revalidate accessibility
    /// labels (and vice versa) for no benefit.
    var accessibilityAnnotations: [CodeAccessibilityAnnotation] = []

    /// Strong owner for the custom rotors' `itemSearchDelegate`, which
    /// `NSAccessibilityCustomRotor` holds only `weak` (see
    /// `NSAccessibilityCustomRotor.h`). Without this, a delegate created
    /// inside `accessibilityCustomRotors()` would be deallocated the
    /// moment that method returns, silently breaking rotor navigation.
    var activeRotorDelegates: [AnyObject] = []

    /// Strong owner for `CodeAnnotationAccessibilityElement`s vended as
    /// `NSAccessibilityCustomRotor.ItemResult.targetElement`, which is
    /// also only a `weak` reference (see `NSAccessibilityCustomRotor.h`).
    /// Without this, an element built by a rotor's item-search delegate
    /// mid-search would be deallocated before the assistive-technology
    /// client could read it back. Refreshed on every rotor search rather
    /// than every `accessibilityCustomRotors()` call, since items are
    /// only ever materialized lazily on demand.
    var activeRotorAnnotationElements: [AnyObject] = []

    private let decorationState: DecorationState
    private var syntaxTree: SyntaxTree?
    private var foldState = FoldState()

    private static let indentUnitColumns = 4
    private static let indentBlankLineLookaround = 200

    private var textLayoutEngine = TextLayoutEngine()
    private(set) var minimapMappingVisitCount = 0

    /// Wide enough for the line-number, Git-status, and folding lanes at the
    /// current font size without clipping into the code column.
    private var gutterWidth: CGFloat = 64
    private static let foldChevronLineWidth: CGFloat = 1.5
    private let rightPadding: CGFloat = 32
    private let stickyHeaderMaximumDepth = 3

    var gutterLaneLayout: GutterLaneLayout {
        GutterModel.laneLayout(width: gutterWidth, height: bounds.height)
    }

    public convenience init(
        snapshot: SourceSnapshot,
        theme: KodTheme = BundledThemes.dark,
        fontSettings: FontSettings = .default
    ) {
        self.init(
            snapshot: snapshot,
            syntaxLanguage: SyntaxLanguage.detect(for: snapshot),
            theme: theme,
            fontSettings: fontSettings
        )
    }

    public init(
        snapshot: SourceSnapshot,
        syntaxLanguage: SyntaxLanguage?,
        theme: KodTheme = BundledThemes.dark,
        fontSettings: FontSettings = .default
    ) {
        self.snapshot = snapshot
        self.language = syntaxLanguage
        self.theme = theme
        self.fontSettings = fontSettings
        self.resolvedFont = FontResolver.resolve(fontSettings)
        self.decorationState = DecorationState(snapshotVersion: snapshot.version)
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityIdentifier("code.viewport")
        applyFontSettings()
        updateDocumentSize()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    public override var isFlipped: Bool {
        true
    }

    public override var acceptsFirstResponder: Bool {
        true
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    public func setMinimumViewportWidth(_ width: CGFloat) {
        guard width != minimumViewportWidth else {
            return
        }
        minimumViewportWidth = width
        updateDocumentSize()
        if wrapEligible {
            needsDisplay = true
        }
        layoutEmbeddedViewZone()
        onMinimapInvalidation?(.layout)
    }

    /// Replaces the gutter's current change markers. Applications are
    /// rejected as a whole when they target another snapshot, arrive older
    /// than the active layer, or contain an invalid source-line location.
    @discardableResult
    public func applyGutterChanges(
        _ changes: [CodeGutterChange],
        snapshotVersion: Int,
        layerVersion: Int
    ) -> Bool {
        guard gutterModel.apply(
            changes,
            snapshotVersion: snapshotVersion,
            activeSnapshotVersion: snapshot.version,
            layerVersion: layerVersion,
            lineCount: snapshot.lineCount
        ) else {
            return false
        }
        needsDisplay = true
        onMinimapInvalidation?(.markers)
        return true
    }

    public func clearGutterChanges() {
        gutterModel.clear()
        needsDisplay = true
        onMinimapInvalidation?(.markers)
    }

    public var activeGutterChanges: [CodeGutterChange] {
        gutterChanges
    }

    var minimapLineHeight: CGFloat {
        lineHeight
    }

    var minimapTotalVisualRows: Int {
        rebuildVisualMetricsIfNeeded()
        return totalVisualRows
    }

    var minimapMaximumRenderedColumns: Int {
        min(CodeMinimapLayout.maximumColumns, max(24, snapshot.longestLineUTF8Length))
    }

    func minimapPresentation(
        visualRows requestedRows: Range<Int>,
        maxColumns: Int
    ) -> CodeMinimapPresentation {
        rebuildVisualMetricsIfNeeded()
        let safeRows = max(0, requestedRows.lowerBound)..<min(
            totalVisualRows,
            max(requestedRows.lowerBound, requestedRows.upperBound)
        )
        let cappedColumns = min(CodeMinimapLayout.maximumColumns, max(1, maxColumns))
        var rows: [MinimapPresentationSnapshotBuilder.Row] = []
        rows.reserveCapacity(safeRows.count)

        for visualRow in safeRows {
            if isEmbeddedViewZoneRow(visualRow) {
                rows.append(MinimapPresentationSnapshotBuilder.Row(
                    visualRow: visualRow,
                    sourceLine: nil,
                    segmentIndex: nil,
                    utf8Range: nil,
                    text: "",
                    decorationRuns: [],
                    isViewZone: true
                ))
                continue
            }

            let identity = sourceLine(forVisualRow: visualRow)
            let segments = wrapSegments(forLine: identity.line)
            guard segments.indices.contains(identity.segmentIndex),
                  let segmentText = try? snapshot.text(inUTF8Range: segments[identity.segmentIndex]) else {
                continue
            }
            let segmentRange = segments[identity.segmentIndex]
            rows.append(MinimapPresentationSnapshotBuilder.Row(
                visualRow: visualRow,
                sourceLine: identity.line,
                segmentIndex: identity.segmentIndex,
                utf8Range: segmentRange,
                text: segmentText,
                decorationRuns: decorationState.composedRuns(in: segmentRange),
                isViewZone: false
            ))
        }
        return MinimapPresentationSnapshotBuilder(
            maximumColumns: cappedColumns,
            defaultForeground: theme.editor.foreground
        ).build(
            totalVisualRows: totalVisualRows,
            requestedRows: safeRows,
            rows: rows
        )
    }

    func resetMinimapMappingVisitCount() {
        minimapMappingVisitCount = 0
    }

    func minimapVisualRows(forUTF8Range range: Range<Int>) -> [Int] {
        rebuildVisualMetricsIfNeeded()
        return minimapVisualRows(
            forUTF8Ranges: [range],
            limitedTo: 0..<totalVisualRows
        )
    }

    /// Maps marker ranges by visiting only the minimap rows currently being
    /// rasterized. `sortedRanges` must be ordered and non-overlapping; the
    /// minimap view normalizes its marker arrays once when marker data changes.
    func minimapVisualRows(
        forUTF8Ranges sortedRanges: [Range<Int>],
        limitedTo requestedRows: Range<Int>
    ) -> [Int] {
        rebuildVisualMetricsIfNeeded()
        guard !sortedRanges.isEmpty else {
            return []
        }
        let safeRows = max(0, requestedRows.lowerBound)..<min(
            totalVisualRows,
            max(requestedRows.lowerBound, requestedRows.upperBound)
        )
        var result: [Int] = []
        result.reserveCapacity(safeRows.count)
        for visualRow in safeRows {
            minimapMappingVisitCount += 1
            guard !isEmbeddedViewZoneRow(visualRow) else {
                continue
            }
            let identity = sourceLine(forVisualRow: visualRow)
            let segments = wrapSegments(forLine: identity.line)
            guard segments.indices.contains(identity.segmentIndex) else {
                continue
            }
            let segmentRange = segments[identity.segmentIndex]
            var intersects = Self.minimapSortedRanges(
                sortedRanges,
                intersect: segmentRange
            )
            if !intersects,
               identity.segmentIndex == 0,
               let fold = foldState.rangesByHeaderLine[identity.line],
               foldState.isFolded(identity.line),
               fold.headerLine < fold.endLine,
               let hiddenStart = snapshot.utf8RangeForLine(fold.headerLine + 1)?.lowerBound,
               let hiddenEnd = snapshot.utf8RangeForLine(fold.endLine)?.upperBound {
                intersects = Self.minimapSortedRanges(
                    sortedRanges,
                    intersect: hiddenStart..<hiddenEnd
                )
            }
            if intersects {
                result.append(visualRow)
            }
        }
        return result
    }

    func minimapVisualRows(forGutterChange change: CodeGutterChange) -> [Int] {
        rebuildVisualMetricsIfNeeded()
        return minimapVisualRows(
            forGutterChange: change,
            limitedTo: 0..<totalVisualRows
        )
    }

    func minimapVisualRows(
        forGutterChange change: CodeGutterChange,
        limitedTo requestedRows: Range<Int>
    ) -> [Int] {
        rebuildVisualMetricsIfNeeded()
        let safeRows = max(0, requestedRows.lowerBound)..<min(
            totalVisualRows,
            max(requestedRows.lowerBound, requestedRows.upperBound)
        )
        switch change.location {
        case .lines(let lines):
            var result: [Int] = []
            result.reserveCapacity(safeRows.count)
            for visualRow in safeRows {
                minimapMappingVisitCount += 1
                guard !isEmbeddedViewZoneRow(visualRow) else {
                    continue
                }
                let identity = sourceLine(forVisualRow: visualRow)
                var intersects = lines.contains(identity.line)
                if !intersects,
                   identity.segmentIndex == 0,
                   let fold = foldState.rangesByHeaderLine[identity.line],
                   foldState.isFolded(identity.line) {
                    let hiddenLines = (fold.headerLine + 1)..<(fold.endLine + 1)
                    intersects = lines.overlaps(hiddenLines)
                }
                if intersects {
                    result.append(visualRow)
                }
            }

            return result
        case .deletion(let afterLine):
            let row: Int
            if afterLine < 0 {
                row = 0
            } else {
                let rowRange = visualRowRange(forLine: afterLine)
                row = rowRange.isEmpty
                    ? minimapVisibleFoldHeaderRow(containingLine: afterLine)
                    : max(rowRange.lowerBound, rowRange.upperBound - 1)
            }
            minimapMappingVisitCount += 1
            return safeRows.contains(row) ? [row] : []
        }
    }

    func minimapVisualRows(
        forGutterMarkers markers: CodeMinimapGutterMarkerSet,
        limitedTo requestedRows: Range<Int>
    ) -> [Int] {
        rebuildVisualMetricsIfNeeded()
        guard !markers.lineRanges.isEmpty || !markers.deletionAfterLines.isEmpty else {
            return []
        }
        let safeRows = max(0, requestedRows.lowerBound)..<min(
            totalVisualRows,
            max(requestedRows.lowerBound, requestedRows.upperBound)
        )
        var result: [Int] = []
        result.reserveCapacity(safeRows.count)
        for visualRow in safeRows {
            minimapMappingVisitCount += 1
            guard !isEmbeddedViewZoneRow(visualRow) else {
                continue
            }
            let identity = sourceLine(forVisualRow: visualRow)
            let segments = wrapSegments(forLine: identity.line)
            var intersects = Self.minimapSortedLineRanges(
                markers.lineRanges,
                contain: identity.line
            )
            let isLastSegment = identity.segmentIndex == max(0, segments.count - 1)
            if !intersects, isLastSegment {
                intersects = Self.minimapSortedIntegers(
                    markers.deletionAfterLines,
                    contain: identity.line
                )
            }
            if !intersects, visualRow == 0 {
                intersects = Self.minimapSortedIntegers(
                    markers.deletionAfterLines,
                    contain: -1
                )
            }
            if !intersects,
               identity.segmentIndex == 0,
               let fold = foldState.rangesByHeaderLine[identity.line],
               foldState.isFolded(identity.line) {
                let hiddenLines = (fold.headerLine + 1)..<(fold.endLine + 1)
                intersects = Self.minimapSortedLineRanges(
                    markers.lineRanges,
                    overlap: hiddenLines
                ) || Self.minimapSortedIntegers(
                    markers.deletionAfterLines,
                    containAnyIn: hiddenLines
                )
            }
            if intersects {
                result.append(visualRow)
            }
        }
        return result
    }

    private static func minimapSortedRanges(
        _ ranges: [Range<Int>],
        intersect target: Range<Int>
    ) -> Bool {
        var lower = 0
        var upper = ranges.count
        while lower < upper {
            let midpoint = (lower + upper) / 2
            if ranges[midpoint].upperBound <= target.lowerBound {
                lower = midpoint + 1
            } else {
                upper = midpoint
            }
        }
        guard ranges.indices.contains(lower) else {
            return false
        }
        let candidate = ranges[lower]
        if target.isEmpty {
            return candidate.contains(target.lowerBound)
        }
        return candidate.lowerBound < target.upperBound
            && candidate.upperBound > target.lowerBound
    }

    private static func minimapSortedLineRanges(
        _ ranges: [Range<Int>],
        contain line: Int
    ) -> Bool {
        minimapSortedLineRanges(ranges, overlap: line..<(line + 1))
    }

    private static func minimapSortedLineRanges(
        _ ranges: [Range<Int>],
        overlap target: Range<Int>
    ) -> Bool {
        var lower = 0
        var upper = ranges.count
        while lower < upper {
            let midpoint = (lower + upper) / 2
            if ranges[midpoint].upperBound <= target.lowerBound {
                lower = midpoint + 1
            } else {
                upper = midpoint
            }
        }
        guard ranges.indices.contains(lower) else {
            return false
        }
        return ranges[lower].lowerBound < target.upperBound
    }

    private static func minimapSortedIntegers(
        _ values: [Int],
        contain value: Int
    ) -> Bool {
        let index = minimapInsertionIndex(in: values, for: value)
        return values.indices.contains(index) && values[index] == value
    }

    private static func minimapSortedIntegers(
        _ values: [Int],
        containAnyIn range: Range<Int>
    ) -> Bool {
        let index = minimapInsertionIndex(in: values, for: range.lowerBound)
        guard values.indices.contains(index) else {
            return false
        }
        return values[index] < range.upperBound
    }

    private static func minimapInsertionIndex(
        in values: [Int],
        for value: Int
    ) -> Int {
        var lower = 0
        var upper = values.count
        while lower < upper {
            let midpoint = (lower + upper) / 2
            if values[midpoint] < value {
                lower = midpoint + 1
            } else {
                upper = midpoint
            }
        }
        return lower
    }

    private func minimapVisibleFoldHeaderRow(containingLine line: Int) -> Int {
        let header = foldState.visibleHeader(containing: line) ?? line
        return visualRowRange(forLine: header).lowerBound
    }

    /// Installs one embedded view zone after `afterLine`; `-1` places it
    /// before the first source line. Only one zone is active at a time,
    /// matching Quick Diff's single-open-hunk interaction.
    @discardableResult
    public func installViewZone(
        id: CodeViewZoneID,
        afterLine: Int,
        heightInLines: Int,
        view: NSView
    ) -> Bool {
        guard afterLine >= -1,
              afterLine < snapshot.lineCount,
              heightInLines > 0,
              heightInLines <= 1_000 else {
            return false
        }

        revealLineContainingViewZone(afterLine: afterLine)
        embeddedViewZone?.view.removeFromSuperview()
        view.removeFromSuperview()
        embeddedViewZone = CodeEmbeddedViewZone(
            id: id,
            afterLine: afterLine,
            heightInLines: heightInLines,
            view: view
        )
        addSubview(view)
        lineCache.removeAll(keepingCapacity: true)
        updateDocumentSize()
        layoutEmbeddedViewZone()
        needsDisplay = true
        onMinimapInvalidation?(.layout)
        return true
    }

    public func removeViewZone(id: CodeViewZoneID? = nil) {
        guard let embeddedViewZone, id == nil || id == embeddedViewZone.id else {
            return
        }
        embeddedViewZone.view.removeFromSuperview()
        self.embeddedViewZone = nil
        lineCache.removeAll(keepingCapacity: true)
        updateDocumentSize()
        needsDisplay = true
        onMinimapInvalidation?(.layout)
    }

    public var activeViewZoneID: CodeViewZoneID? {
        embeddedViewZone?.id
    }

    @discardableResult
    public func scrollViewZoneToTop(id: CodeViewZoneID) -> Bool {
        rebuildVisualMetricsIfNeeded()
        guard embeddedViewZone?.id == id,
              let rowRange = embeddedViewZoneDisplayRowRange else {
            return false
        }
        scroll(NSPoint(x: 0, y: CGFloat(rowRange.lowerBound) * lineHeight))
        return true
    }

    public override func layout() {
        super.layout()
        layoutEmbeddedViewZone()
    }

    /// The topmost fully or partially visible source line, used to capture a
    /// Back/Forward navigation anchor.
    public var topmostVisibleLine: Int {
        rebuildVisualMetricsIfNeeded()
        guard lineHeight.isFinite, lineHeight > 0 else {
            return 0
        }
        let rawVisualRow = floor(visibleRect.minY / lineHeight)
        guard rawVisualRow.isFinite, rawVisualRow > 0 else {
            return 0
        }
        let maximumVisualRow = max(0, totalVisualRows - 1)
        guard rawVisualRow < CGFloat(Int.max) else {
            return sourceLine(forVisualRow: maximumVisualRow).line
        }
        let visualRow = min(Int(rawVisualRow), maximumVisualRow)
        return sourceLine(forVisualRow: visualRow).line
    }

    /// The UTF-8 byte range spanning the currently visible source lines,
    /// used to prioritize syntax-highlight capture computation for what is
    /// actually on screen before the rest of the file (SPEC 7.1, 11.6).
    public var visibleUTF8Range: Range<Int> {
        rebuildVisualMetricsIfNeeded()
        let rowRange = currentMetrics.visibleLineRange(in: visibleRect)
        guard !rowRange.isEmpty, snapshot.lineCount > 0 else {
            return 0..<0
        }
        let firstLine = sourceLine(forVisualRow: rowRange.lowerBound).line
        let lastLine = sourceLine(forVisualRow: max(rowRange.lowerBound, rowRange.upperBound - 1)).line
        let lowerBound = snapshot.utf8RangeForLine(firstLine)?.lowerBound ?? 0
        let upperBound = snapshot.utf8RangeForLine(lastLine)?.upperBound ?? snapshot.utf8Count
        return lowerBound..<max(lowerBound, upperBound)
    }

    /// Scrolls so that `line` becomes the topmost visible source line.
    public func scrollSourceLineToTop(_ line: Int) {
        rebuildVisualMetricsIfNeeded()
        let clampedLine = max(0, min(line, max(0, snapshot.lineCount - 1)))
        let visualRow = visualRowRange(forLine: clampedLine).lowerBound
        scroll(NSPoint(x: 0, y: CGFloat(visualRow) * lineHeight))
    }

    public func selectUTF8Range(_ range: Range<Int>?) throws {
        if let range {
            guard range.lowerBound >= 0, range.upperBound <= snapshot.utf8Count else {
                throw SourceSnapshotError.invalidUTF8Offset(range.upperBound)
            }
            _ = try snapshot.text(inUTF8Range: range)
        }
        applySelectionState(selectedRange: range)
    }

    /// Scrolls the given UTF-8 offset into view (centering it when it is
    /// currently offscreen), used to keep Find in File matches visible.
    public func revealUTF8Offset(_ offset: Int) {
        rebuildVisualMetricsIfNeeded()
        let row = visualRow(forUTF8Offset: offset)
        let targetY = CGFloat(row) * lineHeight
        guard targetY < visibleRect.minY || targetY + lineHeight > visibleRect.maxY else {
            return
        }
        scroll(NSPoint(x: 0, y: max(0, targetY - (visibleRect.height / 2))))
    }

    public override func draw(_ dirtyRect: NSRect) {
        theme.editor.background.nsColor.setFill()
        dirtyRect.fill()

        rebuildVisualMetricsIfNeeded()
        let metrics = currentMetrics
        let bracketMatch = matchingBracketPair()
        for visualRow in metrics.visibleLineRange(in: visibleRect) {
            guard !isEmbeddedViewZoneRow(visualRow) else {
                continue
            }
            let (line, segmentIndex) = sourceLine(forVisualRow: visualRow)
            drawIndentGuides(onVisualRow: visualRow, line: line, segmentIndex: segmentIndex)
            drawSelection(onVisualRow: visualRow, line: line)
            drawBracketHighlight(onVisualRow: visualRow, line: line, segmentIndex: segmentIndex, match: bracketMatch)
            drawLine(atVisualRow: visualRow, line: line, segmentIndex: segmentIndex)
            drawGutterChanges(onVisualRow: visualRow, line: line, segmentIndex: segmentIndex)
        }
        drawStickyHeaders()
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        currentModifierFlags = event.modifierFlags
        let point = convert(event.locationInWindow, from: nil)
        if let change = gutterChange(at: point) {
            onGutterChangeClick?(change.id)
            return
        }
        if let line = foldableLine(atPoint: point) {
            toggleFold(atLine: line)
            return
        }

        let offset = sourceOffset(at: point)
        applySelectionState(
            selectedRange: selectedUTF8Range,
            focusedOffset: offset
        )
        if event.modifierFlags.contains(.command) {
            onCommandClick?(offset)
            return
        }
        anchorUTF8Offset = offset
        applySelectionState(selectedRange: nil)
    }

    public override func mouseMoved(with event: NSEvent) {
        currentModifierFlags = event.modifierFlags
        let point = convert(event.locationInWindow, from: nil)
        updateFoldIndicatorLaneHover(at: point)
        guard point.x >= gutterWidth else {
            currentHoverUTF8Offset = nil
            if gutterChange(at: point) != nil
                || (gutterLaneLayout.folding.contains(point) && foldableLine(atPoint: point) != nil) {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
            onHoverExit?()
            return
        }
        let offset = sourceOffset(at: point)
        currentHoverUTF8Offset = offset
        cursor(
            forUTF8Offset: offset,
            modifierFlags: currentModifierFlags
        ).set()
        let anchorRect = NSRect(
            x: point.x,
            y: floor(point.y / lineHeight) * lineHeight,
            width: 1,
            height: lineHeight
        )
        guard let targetRange = hoverTargetUTF8Range(at: offset) else {
            onHoverExit?()
            return
        }
        onHover?(offset, targetRange, anchorRect)
    }

    public override func mouseExited(with event: NSEvent) {
        currentHoverUTF8Offset = nil
        currentModifierFlags = []
        setFoldIndicatorLaneHovered(false)
        NSCursor.arrow.set()
        onHoverExit?()
    }

    public override func flagsChanged(with event: NSEvent) {
        currentModifierFlags = event.modifierFlags
        if let currentHoverUTF8Offset {
            cursor(
                forUTF8Offset: currentHoverUTF8Offset,
                modifierFlags: currentModifierFlags
            ).set()
        }
        super.flagsChanged(with: event)
    }

    private func updateFoldIndicatorLaneHover(at point: NSPoint) {
        setFoldIndicatorLaneHovered(gutterLaneLayout.folding.contains(point))
    }

    private func setFoldIndicatorLaneHovered(_ hovered: Bool) {
        guard isFoldIndicatorLaneHovered != hovered else {
            return
        }
        isFoldIndicatorLaneHovered = hovered
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let anchorUTF8Offset else {
            return
        }
        let currentOffset = sourceOffset(at: convert(event.locationInWindow, from: nil))
        applySelectionState(
            selectedRange: min(anchorUTF8Offset, currentOffset)..<max(
                anchorUTF8Offset,
                currentOffset
            )
        )
        autoscroll(with: event)
    }

    public override func mouseUp(with event: NSEvent) {
        if selectedUTF8Range?.isEmpty == true {
            applySelectionState(selectedRange: nil)
        }
        anchorUTF8Offset = nil
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            cancelOperation(nil)
        } else if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
        } else {
            NSSound.beep()
        }
    }

    @objc
    public override func cancelOperation(_ sender: Any?) {
        guard onCancelEmbeddedViewZone?() != true else {
            return
        }
        super.cancelOperation(sender)
    }

    @objc
    public func copy(_ sender: Any?) {
        guard let selectedUTF8Range,
              let selectedText = try? snapshot.text(inUTF8Range: selectedUTF8Range) else {
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selectedText, forType: .string)
    }

    @objc
    public override func selectAll(_ sender: Any?) {
        applySelectionState(selectedRange: 0..<snapshot.utf8Count)
    }

    private func applySelectionState(
        selectedRange: Range<Int>?,
        focusedOffset: Int? = nil
    ) {
        let previous = selectionState
        selectedUTF8Range = selectedRange
        if let focusedOffset {
            focusedUTF8Offset = focusedOffset
        }
        let current = selectionState
        guard current != previous else {
            return
        }
        if current.selectedUTF8Range != previous.selectedUTF8Range {
            needsDisplay = true
            onMinimapInvalidation?(.selection)
        }
        onSelectionStateChange?(current)
    }

    @objc
    public func increaseFontSize(_ sender: Any?) {
        var updated = fontSettings
        updated.pointSize = min(FontSettings.sizeRange.upperBound, updated.pointSize + 1)
        fontSettings = updated
    }

    @objc
    public func decreaseFontSize(_ sender: Any?) {
        var updated = fontSettings
        updated.pointSize = max(FontSettings.sizeRange.lowerBound, updated.pointSize - 1)
        fontSettings = updated
    }

    public override func accessibilityRole() -> NSAccessibility.Role? {
        .textArea
    }

    public override func accessibilityLabel() -> String? {
        snapshot.url.lastPathComponent
    }

    public override func accessibilityValue() -> Any? {
        snapshot.text
    }

    public override func accessibilitySelectedText() -> String? {
        guard let selectedUTF8Range else {
            return nil
        }
        return try? snapshot.text(inUTF8Range: selectedUTF8Range)
    }

    public override func accessibilitySelectedTextRange() -> NSRange {
        guard let selectedUTF8Range,
              let location = try? snapshot.globalUTF16Offset(
                forUTF8Offset: selectedUTF8Range.lowerBound
              ),
              let end = try? snapshot.globalUTF16Offset(
                forUTF8Offset: selectedUTF8Range.upperBound
              ) else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: location, length: end - location)
    }

    // MARK: - Syntax decoration

    /// Applies a freshly parsed tree, used for folding, bracket matching,
    /// and sticky scope headers. Discarded silently if it was parsed for a
    /// snapshot other than this viewport's (SPEC 11.3: results are shown
    /// "only when compatible with the active snapshot").
    public func applySyntaxTree(_ tree: SyntaxTree) {
        guard tree.snapshotVersion == snapshot.version else {
            return
        }
        syntaxTree = tree
        foldState.apply(tree)
        needsDisplay = true
        onMinimapInvalidation?(.layout)
    }

    /// Applies a `.lexical` decoration layer built from Tree-sitter
    /// captures. Stale (wrong snapshot version) or superseded (older
    /// layer version) applications are rejected by the compositor and
    /// have no visible effect, per SPEC 7.1's independent layer
    /// versioning.
    public func applyLexicalCaptures(_ captures: [SyntaxCapture], snapshotVersion: Int, layerVersion: Int) {
        guard decorationState.applyLexical(
            captures,
            theme: theme,
            snapshotVersion: snapshotVersion,
            layerVersion: layerVersion
        ) else {
            return
        }
        lineCache.removeAll(keepingCapacity: true)
        needsDisplay = true
        onMinimapInvalidation?(.tokens)
    }

    private func reapplyLexicalLayerForThemeChange() {
        decorationState.reapplyLexical(theme: theme)
    }

    /// Applies a decoration layer built outside `CodeViewport`'s own
    /// lexical pass (e.g. LSP semantic tokens, converted into a
    /// `.semantic` layer by `SemanticTokenDecorationSource`). Generic over
    /// any `DecorationLayerKind` so `CodeViewport` never needs to know
    /// which subsystem produced the layer; stale (wrong snapshot
    /// version) or superseded (older layer version) layers are rejected
    /// by the compositor exactly like `applyLexicalCaptures`.
    @discardableResult
    public func applyDecorationLayer(_ layer: DecorationLayerSnapshot) -> Bool {
        guard decorationState.apply(layer) else {
            return false
        }
        lineCache.removeAll(keepingCapacity: true)
        needsDisplay = true
        onMinimapInvalidation?(.tokens)
        return true
    }

    /// Marks the source token under the pointer as navigable. The app only
    /// calls this after an LSP definition request returns at least one valid
    /// target, so the underline and pointing-hand cursor never promise a
    /// link that cannot actually be followed.
    public func setHoveredLinkUTF8Range(_ range: Range<Int>?) {
        let validatedRange: Range<Int>?
        if let range,
           !range.isEmpty,
           range.lowerBound >= 0,
           range.upperBound <= snapshot.utf8Count {
            validatedRange = range
        } else {
            validatedRange = nil
        }
        guard validatedRange != hoveredLinkUTF8Range else {
            return
        }
        hoveredLinkUTF8Range = validatedRange
        lineCache.removeAll(keepingCapacity: true)
        needsDisplay = true
        if let currentHoverUTF8Offset {
            cursor(
                forUTF8Offset: currentHoverUTF8Offset,
                modifierFlags: currentModifierFlags
            ).set()
        }
    }

    /// Returns the identifier-like source range surrounding a hover offset,
    /// for use as the visual link affordance after LSP confirms that the
    /// position has a definition target.
    public func linkCandidateUTF8Range(at utf8Offset: Int) -> Range<Int>? {
        guard utf8Offset >= 0,
              utf8Offset < snapshot.utf8Count,
              let position = try? snapshot.position(
                forUTF8Offset: utf8Offset,
                encoding: .utf8
              ),
              let lineRange = snapshot.utf8RangeForLine(position.line),
              let line = snapshot.line(at: position.line) else {
            return nil
        }

        var tokenStart: Int?
        var absoluteOffset = lineRange.lowerBound
        for scalar in line.unicodeScalars {
            let scalarLength = String(scalar).utf8.count
            let scalarRange = absoluteOffset..<(absoluteOffset + scalarLength)
            if Self.isIdentifierScalar(scalar) {
                if tokenStart == nil {
                    tokenStart = scalarRange.lowerBound
                }
            } else if let start = tokenStart {
                let tokenRange = start..<scalarRange.lowerBound
                if tokenRange.contains(utf8Offset) {
                    return tokenRange
                }
                tokenStart = nil
            }
            absoluteOffset = scalarRange.upperBound
        }

        if let start = tokenStart {
            let tokenRange = start..<absoluteOffset
            if tokenRange.contains(utf8Offset) {
                return tokenRange
            }
        }
        return nil
    }

    /// Returns a stable source range for hover scheduling. Identifiers use
    /// their complete Unicode-aware range so moving between characters does
    /// not restart language requests; punctuation uses one scalar and
    /// whitespace has no hover target.
    public func hoverTargetUTF8Range(at utf8Offset: Int) -> Range<Int>? {
        if let identifierRange = linkCandidateUTF8Range(at: utf8Offset) {
            return identifierRange
        }
        guard utf8Offset >= 0,
              utf8Offset < snapshot.utf8Count,
              let position = try? snapshot.position(
                forUTF8Offset: utf8Offset,
                encoding: .utf8
              ),
              let lineRange = snapshot.utf8RangeForLine(position.line),
              let line = snapshot.line(at: position.line) else {
            return nil
        }

        var absoluteOffset = lineRange.lowerBound
        for scalar in line.unicodeScalars {
            let scalarRange = absoluteOffset..<(absoluteOffset + UTF8.width(scalar))
            if scalarRange.contains(utf8Offset) {
                return CharacterSet.whitespacesAndNewlines.contains(scalar)
                    ? nil
                    : scalarRange
            }
            absoluteOffset = scalarRange.upperBound
        }
        return nil
    }

    private static func isIdentifierScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || scalar == "$"
            || CharacterSet.alphanumerics.contains(scalar)
            || CharacterSet.nonBaseCharacters.contains(scalar)
    }

    func cursor(
        forUTF8Offset utf8Offset: Int,
        modifierFlags: NSEvent.ModifierFlags
    ) -> NSCursor {
        if modifierFlags.contains(.command),
           hoveredLinkUTF8Range?.contains(utf8Offset) == true {
            return .pointingHand
        }
        return .iBeam
    }

    // MARK: - Folding

    public func isFoldable(atLine line: Int) -> Bool {
        foldState.isFoldable(line)
    }

    public func isFolded(atLine line: Int) -> Bool {
        foldState.isFolded(line)
    }

    public func foldableHeaderLines() -> Set<Int> {
        foldState.foldableHeaderLines
    }

    /// The header lines currently folded, e.g. to preserve across an
    /// external-reload snapshot replacement (SPEC 5.6).
    public func foldedHeaderLinesSnapshot() -> Set<Int> {
        foldState.foldedHeaderLines
    }

    /// Requests that `lines` be folded, applying immediately for any
    /// already-known fold header and deferring the rest until
    /// `applySyntaxTree(_:)` next resolves fold ranges (e.g. right after
    /// constructing a viewport for a freshly reloaded snapshot, before its
    /// first parse completes).
    public func restoreFoldedHeaderLines(_ lines: Set<Int>) {
        guard foldState.restore(lines) else {
            return
        }
        updateDocumentSize()
        needsDisplay = true
        onMinimapInvalidation?(.layout)
    }

    /// Toggles the fold at `line` if it is a fold header. No-op otherwise.
    public func toggleFold(atLine line: Int) {
        guard foldState.toggle(line) else {
            return
        }
        updateDocumentSize()
        needsDisplay = true
        onMinimapInvalidation?(.layout)
    }

    // MARK: - Matching brackets

    /// The bracket pair enclosing/adjacent to the current selection's
    /// anchor, if any, using the last-applied lexical captures to exclude
    /// bracket-like bytes inside strings and comments.
    public func matchingBracketPair() -> BracketMatch? {
        guard let anchor = selectedUTF8Range?.lowerBound ?? anchorUTF8Offset else {
            return nil
        }
        let excluded = decorationState.bracketExclusionRanges
        return BracketMatcher.match(utf8: snapshot.utf8Data, utf8Offset: anchor, excluding: excluded)
    }

    /// Moves the caret to the matching bracket for the current selection
    /// anchor and reveals it, mirroring standard "Go to Matching Bracket"
    /// editor behavior.
    @objc
    public func jumpToMatchingBracket(_ sender: Any? = nil) {
        guard let match = matchingBracketPair() else {
            return
        }
        let anchor = selectedUTF8Range?.lowerBound ?? anchorUTF8Offset ?? 0
        let target = anchor <= match.opening ? match.closing : match.opening
        try? selectUTF8Range(target..<(target + 1))
        revealUTF8Offset(target)
    }

    /// Toggles the fold at the current selection's line (falling back to
    /// the topmost visible line when there is no selection), for menu/
    /// keyboard invocation where there is no gutter click point.
    @objc
    public func toggleFoldAtCurrentLine(_ sender: Any? = nil) {
        let offset = selectedUTF8Range?.lowerBound ?? anchorUTF8Offset
        let line: Int
        if let offset, let position = try? snapshot.position(forUTF8Offset: offset, encoding: .utf8) {
            line = position.line
        } else {
            line = topmostVisibleLine
        }
        toggleFold(atLine: line)
    }

    // MARK: - Sticky scope headers

    /// Enclosing scope headers for the topmost visible source line, used
    /// to render pinned sticky headers while the viewport has scrolled
    /// past a construct's opening line but is still inside its body.
    public func stickyScopeHeaders() -> [ScopeHeader] {
        guard let syntaxTree else {
            return []
        }
        let line = topmostVisibleLine
        guard let lineRange = snapshot.utf8RangeForLine(line) else {
            return []
        }
        return Array(
            syntaxTree
                .enclosingScopes(atByteOffset: lineRange.lowerBound, maximumDepth: stickyHeaderMaximumDepth)
                .filter { $0.startLine < line }
                .prefix(stickyHeaderMaximumDepth)
        )
    }

    private var wrapEligible: Bool {
        wordWrapEnabled && snapshot.safetyModeReason == nil
    }

    private var totalVisualRows: Int {
        coordinateMapper.totalRows
    }

    private var coordinateMapper: ViewportCoordinateMapper {
        ViewportCoordinateMapper(
            visualRowStarts: textLayoutEngine.visualRowStarts,
            lineCount: snapshot.lineCount,
            viewZoneAfterLine: embeddedViewZone?.afterLine,
            viewZoneHeight: embeddedViewZone?.heightInLines ?? 0
        )
    }

    private var currentMetrics: ViewportMetrics {
        rebuildVisualMetricsIfNeeded()
        let contentWidth = TextLayoutEngine.contentWidth(
            viewportWidth: minimumViewportWidth,
            gutterWidth: gutterWidth,
            rightPadding: rightPadding,
            characterWidth: characterWidth,
            longestLineUTF8Length: snapshot.longestLineUTF8Length,
            wraps: wrapEligible && textLayoutEngine.visualRowStarts != nil
        )
        return ViewportMetrics(
            lineCount: totalVisualRows,
            lineHeight: lineHeight,
            contentWidth: contentWidth
        )
    }

    private func applyFontSettings() {
        resolvedFont = FontResolver.resolve(fontSettings)
        fontAlignmentWarning = resolvedFont.alignmentWarning

        let manager = NSFontManager.shared
        boldFont = manager.convert(resolvedFont.nsFont, toHaveTrait: .boldFontMask)
        italicFont = manager.convert(resolvedFont.nsFont, toHaveTrait: .italicFontMask)
        boldItalicFont = manager.convert(boldFont, toHaveTrait: .italicFontMask)
        lineHeight = resolvedFont.lineHeight
        characterWidth = resolvedFont.characterWidth
        gutterWidth = Self.measureGutterWidth(lineCount: snapshot.lineCount, resolvedFont: resolvedFont)

        invalidateWrapCache()
        updateDocumentSize()
        layoutEmbeddedViewZone()
        needsDisplay = true
        onMinimapInvalidation?(.appearance)
    }

    /// Measures enough room for line numbers followed by fixed Git-status
    /// and folding lanes. The original 64pt floor keeps short files spacious.
    static func lineNumberFont(for editorFont: NSFont) -> NSFont {
        NSFont.monospacedDigitSystemFont(
            ofSize: max(9, editorFont.pointSize - 2),
            weight: .regular
        )
    }

    static func measureGutterWidth(lineCount: Int, resolvedFont: ResolvedFont) -> CGFloat {
        let digitCount = max(1, String(max(1, lineCount)).count)
        let sample = NSAttributedString(
            string: String(repeating: "8", count: digitCount),
            attributes: [.font: lineNumberFont(for: resolvedFont.nsFont)]
        )
        let line = CTLineCreateWithAttributedString(sample)
        let lineNumberWidth = ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        return GutterModel.requiredWidth(lineNumberWidth: lineNumberWidth)
    }

    private func updateDocumentSize() {
        setFrameSize(currentMetrics.contentSize)
        layoutEmbeddedViewZone()
    }

    private func invalidateWrapCache() {
        textLayoutEngine.invalidate()
        lineCache.removeAll(keepingCapacity: true)
    }

    /// Recomputes the visual-row prefix-sum table whenever word wrap or
    /// folding needs one: word wrap because a line may span several visual
    /// rows, folding because a collapsed range's lines contribute zero
    /// rows. This is a linear pass over the document's line index (already
    /// built at snapshot load), not a re-parse, and only runs when the user
    /// opts into word wrap, toggles a fold, or resizes the window — never
    /// on the initial plain-text paint path.
    ///
    /// Not `private`: `CodeViewportAccessibility.swift` calls this before
    /// reading `visualRowRange(forLine:)` so accessibility frame geometry
    /// is never stale relative to the last fold/wrap toggle.
    func rebuildVisualMetricsIfNeeded() {
        let maxColumns = wrapEligible
            ? TextLayoutEngine.maximumColumns(
                viewportWidth: minimumViewportWidth,
                gutterWidth: gutterWidth,
                rightPadding: rightPadding,
                characterWidth: characterWidth
            )
            : 0
        if textLayoutEngine.rebuildIfNeeded(
            snapshot: snapshot,
            wrapEnabled: wrapEligible,
            maximumColumns: maxColumns,
            folds: foldState
        ) {
            lineCache.removeAll(keepingCapacity: true)
        }
    }

    /// The UTF-8 sub-ranges of `line` that each render on their own visual
    /// row. A single-element array when wrap is disabled or ineligible.
    private func wrapSegments(forLine line: Int) -> [Range<Int>] {
        textLayoutEngine.segments(
            forLine: line,
            snapshot: snapshot,
            wrapEnabled: wrapEligible
        )
    }

    /// Not `private`: reused by `CodeViewportAccessibility.swift` to derive
    /// on-screen frames for per-line and per-annotation accessibility
    /// elements from the same visual-row bookkeeping the drawing path uses.
    func visualRowRange(forLine line: Int) -> Range<Int> {
        coordinateMapper.displayRowRange(forLine: line)
    }

    /// Maps a visual row back to its source line and the segment index
    /// within that line, via binary search over the prefix-sum table.
    private func sourceLine(forVisualRow row: Int) -> (line: Int, segmentIndex: Int) {
        let identity = coordinateMapper.sourceIdentity(forDisplayRow: row)
        return (identity.line, identity.segmentIndex)
    }

    private var embeddedViewZoneDisplayRowRange: Range<Int>? {
        coordinateMapper.viewZoneDisplayRows
    }

    private func isEmbeddedViewZoneRow(_ displayRow: Int) -> Bool {
        coordinateMapper.isViewZoneRow(displayRow)
    }

    private func visualRow(forUTF8Offset offset: Int) -> Int {
        guard let position = try? snapshot.position(forUTF8Offset: offset, encoding: .utf8) else {
            return 0
        }
        let rowRange = visualRowRange(forLine: position.line)
        guard wrapEligible, textLayoutEngine.visualRowStarts != nil else {
            return rowRange.lowerBound
        }

        let segments = wrapSegments(forLine: position.line)
        for (index, segment) in segments.enumerated()
        where segment.contains(offset) || segment.upperBound == offset {
            return rowRange.lowerBound + index
        }
        return rowRange.lowerBound
    }

    private func lineLayout(
        visualRow: Int,
        line: Int,
        segmentIndex: Int,
        segmentRange: Range<Int>,
        text: String
    ) -> CTLine {
        if let cached = lineCache[visualRow] {
            return cached
        }

        let attributed = NSMutableAttributedString(
            attributedString: attributedString(forSegment: text, utf8Range: segmentRange)
        )
        if isFolded(atLine: line), segmentIndex == wrapSegments(forLine: line).count - 1 {
            attributed.append(NSAttributedString(
                string: " " + Self.foldedRegionIndicatorGlyph,
                attributes: [
                    .font: resolvedFont.nsFont,
                    .foregroundColor: theme.editor.foldedRegionForeground.nsColor
                ]
            ))
        }

        let ctLine = CTLineCreateWithAttributedString(attributed)
        lineCache[visualRow] = ctLine
        return ctLine
    }

    func attributedString(forSegment text: String, utf8Range segmentRange: Range<Int>) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: baseTextAttributes())
        guard !segmentRange.isEmpty,
              let segmentStartPosition = try? snapshot.position(
                forUTF8Offset: segmentRange.lowerBound,
                encoding: .utf16
              ) else {
            return result
        }

        let runs = decorationState.composedRuns(in: segmentRange)
        let textLength = (text as NSString).length

        for run in runs {
            guard let localRange = localUTF16Range(
                for: run.utf8Range,
                in: segmentRange,
                segmentStartPosition: segmentStartPosition,
                textLength: textLength
            ) else {
                continue
            }

            var attributes: [NSAttributedString.Key: Any] = [:]
            if let foreground = run.attributes.foreground {
                attributes[.foregroundColor] = foreground.nsColor
            }
            if let background = run.attributes.background {
                attributes[.backgroundColor] = background.nsColor
            }
            if run.attributes.isBold || run.attributes.isItalic {
                attributes[.font] = fontVariant(bold: run.attributes.isBold, italic: run.attributes.isItalic)
            }
            if run.attributes.isUnderlined {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if run.attributes.isStrikethrough {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            guard !attributes.isEmpty else {
                continue
            }
            result.addAttributes(attributes, range: localRange)
        }

        if let hoveredLinkUTF8Range,
           let localRange = localUTF16Range(
            for: hoveredLinkUTF8Range,
            in: segmentRange,
            segmentStartPosition: segmentStartPosition,
            textLength: textLength
           ) {
            result.addAttribute(
                .underlineStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: localRange
            )
        }
        return result
    }

    private func localUTF16Range(
        for utf8Range: Range<Int>,
        in segmentRange: Range<Int>,
        segmentStartPosition: SourcePosition,
        textLength: Int
    ) -> NSRange? {
        let clampedStart = max(utf8Range.lowerBound, segmentRange.lowerBound)
        let clampedEnd = min(utf8Range.upperBound, segmentRange.upperBound)
        guard clampedStart < clampedEnd,
              let startPosition = try? snapshot.position(
                forUTF8Offset: clampedStart,
                encoding: .utf16
              ),
              let endPosition = try? snapshot.position(
                forUTF8Offset: clampedEnd,
                encoding: .utf16
              ) else {
            return nil
        }
        let localStart = max(0, startPosition.character - segmentStartPosition.character)
        let localEnd = min(textLength, endPosition.character - segmentStartPosition.character)
        guard localStart < localEnd else {
            return nil
        }
        return NSRange(location: localStart, length: localEnd - localStart)
    }

    /// Not `private`: `CodeViewportAccessibility.swift`'s
    /// `accessibilityAttributedString(for:)` reuses this so an AX client
    /// gets real font/foreground attributes instead of plain black-on-white
    /// text, without duplicating the theme/font resolution logic here.
    func baseTextAttributes() -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: resolvedFont.nsFont,
            .foregroundColor: theme.editor.foreground.nsColor,
            .ligature: resolvedFont.ligatureAttributeValue
        ]
        if resolvedFont.letterSpacing != 0 {
            attributes[.kern] = resolvedFont.letterSpacing
        }
        return attributes
    }

    /// Not `private`: exposed for the same reason as `baseTextAttributes()`
    /// above, in case a future accessibility enhancement needs to reflect
    /// bold/italic decoration runs in the attributed string it returns.
    func fontVariant(bold: Bool, italic: Bool) -> NSFont {
        switch (bold, italic) {
        case (true, true): boldItalicFont
        case (true, false): boldFont
        case (false, true): italicFont
        case (false, false): resolvedFont.nsFont
        }
    }

    private func lineNumberLayout(at index: Int) -> CTLine {
        let attributed = NSAttributedString(
            string: String(index + 1),
            attributes: [
                .font: Self.lineNumberFont(for: resolvedFont.nsFont),
                .foregroundColor: theme.editor.gutterForeground.nsColor
            ]
        )
        return CTLineCreateWithAttributedString(attributed)
    }

    private func drawLine(atVisualRow visualRow: Int, line: Int, segmentIndex: Int) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        let segments = wrapSegments(forLine: line)
        guard segments.indices.contains(segmentIndex),
              let text = try? snapshot.text(inUTF8Range: segments[segmentIndex]) else {
            return
        }

        let baselineFromTop = (CGFloat(visualRow) * lineHeight) + resolvedFont.nsFont.ascender + 2
        let ctLine = lineLayout(
            visualRow: visualRow,
            line: line,
            segmentIndex: segmentIndex,
            segmentRange: segments[segmentIndex],
            text: text
        )

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)

        let baseline = bounds.height - baselineFromTop
        context.textPosition = CGPoint(x: gutterWidth, y: baseline)
        CTLineDraw(ctLine, context)

        if segmentIndex == 0 {
            let number = lineNumberLayout(at: line)
            let numberWidth = CGFloat(CTLineGetTypographicBounds(number, nil, nil, nil))
            context.textPosition = CGPoint(
                x: gutterLaneLayout.lineNumbers.maxX - numberWidth,
                y: baseline
            )
            CTLineDraw(number, context)
        }
        context.restoreGState()

        if segmentIndex == 0 {
            drawFoldIndicator(onVisualRow: visualRow, line: line)
        }
    }

    private func drawFoldIndicator(onVisualRow visualRow: Int, line: Int) {
        guard shouldDrawFoldIndicator(atLine: line) else {
            return
        }
        let center = NSPoint(
            x: gutterLaneLayout.folding.midX,
            y: (CGFloat(visualRow) * lineHeight) + (lineHeight / 2)
        )
        let points = Self.foldChevronPoints(isFolded: isFolded(atLine: line), center: center)
        let path = NSBezierPath()
        path.move(to: points[0])
        path.line(to: points[1])
        path.line(to: points[2])
        path.lineWidth = Self.foldChevronLineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        theme.editor.gutterForeground.nsColor.setStroke()
        path.stroke()
    }

    func shouldDrawFoldIndicator(atLine line: Int) -> Bool {
        isFoldIndicatorLaneHovered && isFoldable(atLine: line)
    }

    static func foldChevronPoints(isFolded: Bool, center: NSPoint) -> [NSPoint] {
        if isFolded {
            return [
                NSPoint(x: center.x - 2.5, y: center.y - 4),
                NSPoint(x: center.x + 2.5, y: center.y),
                NSPoint(x: center.x - 2.5, y: center.y + 4)
            ]
        }
        return [
            NSPoint(x: center.x - 4, y: center.y - 2.5),
            NSPoint(x: center.x, y: center.y + 2.5),
            NSPoint(x: center.x + 4, y: center.y - 2.5)
        ]
    }

    private func drawSelection(onVisualRow visualRow: Int, line: Int) {
        guard let selectedUTF8Range else {
            return
        }

        let segments = wrapSegments(forLine: line)
        let segmentIndex = sourceLine(forVisualRow: visualRow).segmentIndex
        guard segments.indices.contains(segmentIndex) else {
            return
        }
        let segmentRange = segments[segmentIndex]

        let lower = max(selectedUTF8Range.lowerBound, segmentRange.lowerBound)
        let upper = min(selectedUTF8Range.upperBound, segmentRange.upperBound)
        guard lower < upper,
              let segmentStart = try? snapshot.position(
                forUTF8Offset: segmentRange.lowerBound,
                encoding: .utf16
              ),
              let lowerPosition = try? snapshot.position(
                forUTF8Offset: lower,
                encoding: .utf16
              ),
              let upperPosition = try? snapshot.position(
                forUTF8Offset: upper,
                encoding: .utf16
              ),
              let text = try? snapshot.text(inUTF8Range: segmentRange) else {
            return
        }

        let ctLine = lineLayout(
            visualRow: visualRow,
            line: line,
            segmentIndex: segmentIndex,
            segmentRange: segmentRange,
            text: text
        )
        let startX = CTLineGetOffsetForStringIndex(
            ctLine,
            max(0, lowerPosition.character - segmentStart.character),
            nil
        )
        let endX = CTLineGetOffsetForStringIndex(
            ctLine,
            max(0, upperPosition.character - segmentStart.character),
            nil
        )
        let rect = NSRect(
            x: gutterWidth + startX,
            y: CGFloat(visualRow) * lineHeight,
            width: max(1, endX - startX),
            height: lineHeight
        )

        theme.editor.selectionBackground.nsColor.setFill()
        rect.fill()
    }

    private func drawBracketHighlight(
        onVisualRow visualRow: Int,
        line: Int,
        segmentIndex: Int,
        match: BracketMatch?
    ) {
        guard let match else {
            return
        }
        let segments = wrapSegments(forLine: line)
        guard segments.indices.contains(segmentIndex) else {
            return
        }
        let segmentRange = segments[segmentIndex]

        for offset in [match.opening, match.closing] where segmentRange.contains(offset) {
            guard let segmentStart = try? snapshot.position(
                forUTF8Offset: segmentRange.lowerBound,
                encoding: .utf16
              ),
              let startPosition = try? snapshot.position(forUTF8Offset: offset, encoding: .utf16),
              let endPosition = try? snapshot.position(forUTF8Offset: offset + 1, encoding: .utf16),
              let text = try? snapshot.text(inUTF8Range: segmentRange) else {
                continue
            }

            let ctLine = lineLayout(
                visualRow: visualRow,
                line: line,
                segmentIndex: segmentIndex,
                segmentRange: segmentRange,
                text: text
            )
            let startX = CTLineGetOffsetForStringIndex(
                ctLine,
                max(0, startPosition.character - segmentStart.character),
                nil
            )
            let endX = CTLineGetOffsetForStringIndex(
                ctLine,
                max(0, endPosition.character - segmentStart.character),
                nil
            )
            let rect = NSRect(
                x: gutterWidth + startX,
                y: CGFloat(visualRow) * lineHeight,
                width: max(1, endX - startX),
                height: lineHeight
            )
            theme.editor.matchingBracketBackground.nsColor.setFill()
            rect.fill()
        }
    }

    private func drawIndentGuides(onVisualRow visualRow: Int, line: Int, segmentIndex: Int) {
        guard segmentIndex == 0 else {
            return
        }
        let guideCount = indentGuideColumnCount(forLine: line)
        guard guideCount > 0 else {
            return
        }

        let color = theme.editor.indentGuideForeground.nsColor
        let y = CGFloat(visualRow) * lineHeight
        color.setFill()
        for stop in 0..<guideCount {
            let x = gutterWidth + CGFloat(stop * Self.indentUnitColumns) * characterWidth
            NSRect(x: x, y: y, width: 1, height: lineHeight).fill()
        }
    }

    private func drawStickyHeaders() {
        let headers = stickyScopeHeaders()
        guard !headers.isEmpty, let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        let top = visibleRect.minY
        for (index, header) in headers.enumerated() {
            guard let text = snapshot.line(at: header.startLine),
                  let lineRange = snapshot.utf8RangeForLine(header.startLine) else {
                continue
            }
            let rowOriginY = top + (CGFloat(index) * lineHeight)

            theme.editor.background.nsColor.setFill()
            NSRect(x: 0, y: rowOriginY, width: max(bounds.width, visibleRect.width), height: lineHeight).fill()

            let ctLine = CTLineCreateWithAttributedString(
                attributedString(forSegment: text, utf8Range: lineRange)
            )
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            let baselineFromTop = rowOriginY + resolvedFont.nsFont.ascender + 2
            context.textPosition = CGPoint(x: gutterWidth, y: bounds.height - baselineFromTop)
            CTLineDraw(ctLine, context)
            context.restoreGState()
        }
    }

    private func indentGuideColumnCount(forLine line: Int) -> Int {
        guard let text = snapshot.line(at: line) else {
            return 0
        }
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            let previous = nearestNonBlankIndentColumns(startingAt: line - 1, step: -1)
            let next = nearestNonBlankIndentColumns(startingAt: line + 1, step: 1)
            return max(previous, next) / Self.indentUnitColumns
        }
        return leadingWhitespaceColumns(text) / Self.indentUnitColumns
    }

    private func leadingWhitespaceColumns(_ text: String) -> Int {
        var columns = 0
        for scalar in text.unicodeScalars {
            if scalar == " " {
                columns += 1
            } else if scalar == "\t" {
                columns = ((columns / Self.indentUnitColumns) + 1) * Self.indentUnitColumns
            } else {
                break
            }
        }
        return columns
    }

    private func nearestNonBlankIndentColumns(startingAt startLine: Int, step: Int) -> Int {
        var currentLine = startLine
        var stepsRemaining = Self.indentBlankLineLookaround
        while currentLine >= 0, currentLine < snapshot.lineCount, stepsRemaining > 0 {
            if let text = snapshot.line(at: currentLine), !text.trimmingCharacters(in: .whitespaces).isEmpty {
                return leadingWhitespaceColumns(text)
            }
            currentLine += step
            stepsRemaining -= 1
        }
        return 0
    }

    private func gutterColor(for change: CodeGutterChange) -> NSColor {
        switch (change.kind, change.layer) {
        case (.added, .primary):
            return theme.git.gutterAdded.nsColor
        case (.modified, .primary):
            return theme.git.gutterModified.nsColor
        case (.deleted, .primary):
            return theme.git.gutterDeleted.nsColor
        case (.added, .secondary), (.modified, .secondary):
            return theme.git.stagedModified.nsColor
        case (.deleted, .secondary):
            return theme.git.stagedDeleted.nsColor
        }
    }

    private func drawGutterChanges(onVisualRow visualRow: Int, line: Int, segmentIndex: Int) {
        guard !gutterChanges.isEmpty else {
            return
        }
        if let change = gutterModel.lineChange(at: line) {
            gutterColor(for: change).setFill()
            GutterModel.markerRect(
                in: gutterLaneLayout.gitStatus,
                layer: change.layer,
                y: CGFloat(visualRow) * lineHeight,
                height: lineHeight
            ).fill()
        }

        if line == 0, segmentIndex == 0, let deletion = gutterModel.deletion(afterLine: -1) {
            drawDeletionTriangle(atY: 0, color: gutterColor(for: deletion))
        }
        let segments = wrapSegments(forLine: line)
        if segmentIndex == max(0, segments.count - 1),
           let deletion = gutterModel.deletion(afterLine: line) {
            drawDeletionTriangle(
                atY: CGFloat(visualRow + 1) * lineHeight,
                color: gutterColor(for: deletion)
            )
        }
    }

    private func drawDeletionTriangle(atY boundaryY: CGFloat, color: NSColor) {
        let halfHeight: CGFloat = 4
        let clampedY = min(max(boundaryY, halfHeight), max(halfHeight, bounds.height - halfHeight))
        let lane = gutterLaneLayout.gitStatus
        let path = NSBezierPath()
        path.move(to: NSPoint(x: lane.minX, y: clampedY - halfHeight))
        path.line(to: NSPoint(x: lane.maxX, y: clampedY))
        path.line(to: NSPoint(x: lane.minX, y: clampedY + halfHeight))
        path.close()
        color.setFill()
        path.fill()
    }

    func gutterChange(at point: NSPoint) -> CodeGutterChange? {
        guard gutterLaneLayout.gitStatus.contains(point),
              point.y >= 0,
              point.y <= bounds.height,
              lineHeight > 0 else {
            return nil
        }

        if let deletion = gutterModel.deletion(afterLine: -1),
           abs(point.y) <= 6 {
            return deletion
        }

        let displayRow = max(0, Int(floor(point.y / lineHeight)))
        guard !isEmbeddedViewZoneRow(displayRow) else {
            return nil
        }
        let (line, _) = sourceLine(forVisualRow: min(displayRow, max(0, totalVisualRows - 1)))

        for anchor in [line - 1, line] where anchor >= 0 {
            guard let deletion = gutterModel.deletion(afterLine: anchor) else {
                continue
            }
            let boundaryY = CGFloat(visualRowRange(forLine: anchor).upperBound) * lineHeight
            if abs(point.y - boundaryY) <= 6 {
                return deletion
            }
        }
        return gutterModel.lineChange(at: line)
    }

    private func revealLineContainingViewZone(afterLine: Int) {
        let targetLine = max(0, min(afterLine, max(0, snapshot.lineCount - 1)))
        guard foldState.reveal(line: targetLine) else {
            return
        }
        rebuildVisualMetricsIfNeeded()
    }

    private func layoutEmbeddedViewZone() {
        guard let embeddedViewZone,
              let rowRange = embeddedViewZoneDisplayRowRange else {
            return
        }
        embeddedViewZone.view.frame = NSRect(
            x: 0,
            y: CGFloat(rowRange.lowerBound) * lineHeight,
            width: max(bounds.width, minimumViewportWidth),
            height: CGFloat(rowRange.count) * lineHeight
        )
    }

    var embeddedViewZoneFrame: NSRect? {
        embeddedViewZone?.view.frame
    }

    private func foldableLine(atPoint point: NSPoint) -> Int? {
        rebuildVisualMetricsIfNeeded()
        guard gutterLaneLayout.folding.contains(point), lineHeight > 0 else {
            return nil
        }
        let visualRow = max(0, Int(floor(point.y / lineHeight)))
        let (line, segmentIndex) = sourceLine(forVisualRow: visualRow)
        guard segmentIndex == 0, isFoldable(atLine: line) else {
            return nil
        }
        return line
    }

    /// Not `private`: `CodeViewportAccessibility.swift`'s
    /// `accessibilityHitTest(_:)` reuses this exact point-to-byte-offset
    /// mapping (the same one mouse hit-testing uses) so a VoiceOver click
    /// or a real mouse click land on the identical source location.
    func sourceOffset(at point: NSPoint) -> Int {
        rebuildVisualMetricsIfNeeded()
        let totalRows = totalVisualRows
        guard totalRows > 0 else {
            return 0
        }
        let visualRow = min(totalRows - 1, max(0, Int(floor(point.y / lineHeight))))
        let (line, segmentIndex) = sourceLine(forVisualRow: visualRow)
        let segments = wrapSegments(forLine: line)
        guard segments.indices.contains(segmentIndex) else {
            return snapshot.utf8Count
        }
        let segmentRange = segments[segmentIndex]
        guard let segmentText = try? snapshot.text(inUTF8Range: segmentRange),
              let segmentStart = try? snapshot.position(
                forUTF8Offset: segmentRange.lowerBound,
                encoding: .utf16
              ) else {
            return segmentRange.lowerBound
        }

        let ctLine = lineLayout(
            visualRow: visualRow,
            line: line,
            segmentIndex: segmentIndex,
            segmentRange: segmentRange,
            text: segmentText
        )
        let localCharacter = CTLineGetStringIndexForPosition(
            ctLine,
            CGPoint(x: max(0, point.x - gutterWidth), y: 0)
        )
        let clampedLocal = localCharacter == kCFNotFound
            ? segmentText.utf16.count
            : localCharacter

        return (try? snapshot.utf8Offset(
            for: SourcePosition(line: line, character: segmentStart.character + clampedLocal),
            encoding: .utf16
        )) ?? segmentRange.upperBound
    }

    private static let foldedRegionIndicatorGlyph = "\u{22EF}"
}
