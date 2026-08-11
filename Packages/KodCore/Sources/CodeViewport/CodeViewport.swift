import AppKit
import CoreText
import FontCore
import SourceModel
import SyntaxCore
import ThemeCore

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
    public var onLinkClick: ((Int) -> Void)?
    public var onHover: ((Int, Range<Int>, NSRect) -> Void)?
    public var onHoverExit: (() -> Void)?

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
    private var hoverTrackingArea: NSTrackingArea?
    private var lineCache: [Int: CTLine] = [:]
    private var minimumViewportWidth: CGFloat = 0

    /// Accessibility-only annotation metadata (symbols, diagnostics,
    /// references, git changes) driving the custom VoiceOver rotors in
    /// `CodeViewportAccessibility.swift`. Deliberately kept separate from
    /// `decorationCompositor`'s visual decoration layers (SPEC 7.1): one
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

    private let decorationCompositor: DecorationCompositor
    private var lastLexicalCaptures: [SyntaxCapture] = []
    private var syntaxTree: SyntaxTree?
    private var foldRangesByHeaderLine: [Int: FoldRange] = [:]
    private var foldedHeaderLines: Set<Int> = []
    /// Header lines an external reload asked to be folded before this
    /// viewport's first syntax tree (and thus its fold ranges) is known.
    /// Re-applied every time `applySyntaxTree(_:)` recomputes fold ranges,
    /// so a reload's requested folds "stick" once parsing catches up.
    private var pendingFoldedHeaderLines: Set<Int> = []
    private var foldStateVersion = 0
    private var visualMetricsFoldVersion = -1
    private var hiddenLines: [Bool] = []

    private static let indentUnitColumns = 4
    private static let indentBlankLineLookaround = 200

    /// Prefix-sum table mapping each source line to its first visual row,
    /// sized `lineCount + 1`. `nil` when word wrap is disabled, no folds
    /// are active, and it has never been needed, in which case visual rows
    /// and source lines are the same thing (the O(1) fast path).
    private var visualRowStarts: [Int]?
    private var wrapColumnsUsed = 0
    private var wrappedSegmentCache: [Int: [Range<Int>]] = [:]

    /// Wide enough to fit this document's largest line number (plus a
    /// fold indicator glyph) at the *current* font size without clipping
    /// into the code column (SPEC 14: "Text zoom must reach at least 300
    /// percent without clipping controls"). A fixed 64pt budget was sized
    /// for a ~13pt default font and a handful of digits; at large zoom
    /// levels — or simply on longer files — that budget runs out well
    /// before 300%, so this is recomputed (in `applyFontSettings()`,
    /// which already runs on init and on every font-size change) from the
    /// resolved gutter font's actual measured width rather than kept as a
    /// constant.
    private var gutterWidth: CGFloat = 64
    private let rightPadding: CGFloat = 32
    private let stickyHeaderMaximumDepth = 3

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
        self.decorationCompositor = DecorationCompositor(activeSnapshotVersion: snapshot.version)
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
        selectedUTF8Range = range
        needsDisplay = true
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
            let (line, segmentIndex) = sourceLine(forVisualRow: visualRow)
            drawIndentGuides(onVisualRow: visualRow, line: line, segmentIndex: segmentIndex)
            drawSelection(onVisualRow: visualRow, line: line)
            drawBracketHighlight(onVisualRow: visualRow, line: line, segmentIndex: segmentIndex, match: bracketMatch)
            drawLine(atVisualRow: visualRow, line: line, segmentIndex: segmentIndex)
        }
        drawStickyHeaders()
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if point.x < gutterWidth, let line = foldableLine(atPoint: point) {
            toggleFold(atLine: line)
            return
        }

        let offset = sourceOffset(at: point)
        focusedUTF8Offset = offset
        if event.modifierFlags.contains(.command) {
            onCommandClick?(offset)
            return
        }
        if hoveredLinkUTF8Range?.contains(offset) == true, let onLinkClick {
            onLinkClick(offset)
            return
        }
        anchorUTF8Offset = offset
        selectedUTF8Range = nil
        needsDisplay = true
    }

    public override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.x >= gutterWidth else {
            currentHoverUTF8Offset = nil
            NSCursor.arrow.set()
            onHoverExit?()
            return
        }
        let offset = sourceOffset(at: point)
        currentHoverUTF8Offset = offset
        cursor(forUTF8Offset: offset).set()
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
        NSCursor.arrow.set()
        onHoverExit?()
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let anchorUTF8Offset else {
            return
        }
        let currentOffset = sourceOffset(at: convert(event.locationInWindow, from: nil))
        selectedUTF8Range = min(anchorUTF8Offset, currentOffset)..<max(
            anchorUTF8Offset,
            currentOffset
        )
        autoscroll(with: event)
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        if selectedUTF8Range?.isEmpty == true {
            selectedUTF8Range = nil
        }
        anchorUTF8Offset = nil
    }

    public override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
        } else {
            NSSound.beep()
        }
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
        selectedUTF8Range = 0..<snapshot.utf8Count
        needsDisplay = true
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
        foldRangesByHeaderLine = Self.computeFoldRanges(from: tree)
        foldedHeaderLines = foldedHeaderLines.union(pendingFoldedHeaderLines)
            .filter { foldRangesByHeaderLine[$0] != nil }
        foldStateVersion += 1
        needsDisplay = true
    }

    /// Applies a `.lexical` decoration layer built from Tree-sitter
    /// captures. Stale (wrong snapshot version) or superseded (older
    /// layer version) applications are rejected by the compositor and
    /// have no visible effect, per SPEC 7.1's independent layer
    /// versioning.
    public func applyLexicalCaptures(_ captures: [SyntaxCapture], snapshotVersion: Int, layerVersion: Int) {
        let layer = LexicalDecorationSource.layer(
            fromCaptures: captures,
            theme: theme,
            snapshotVersion: snapshotVersion,
            layerVersion: layerVersion
        )
        guard decorationCompositor.apply(layer) else {
            return
        }
        lastLexicalCaptures = captures
        lineCache.removeAll(keepingCapacity: true)
        needsDisplay = true
    }

    private func reapplyLexicalLayerForThemeChange() {
        guard !lastLexicalCaptures.isEmpty,
              let currentVersion = decorationCompositor.layerVersion(for: .lexical) else {
            return
        }
        let layer = LexicalDecorationSource.layer(
            fromCaptures: lastLexicalCaptures,
            theme: theme,
            snapshotVersion: decorationCompositor.activeSnapshotVersion,
            layerVersion: currentVersion
        )
        decorationCompositor.apply(layer)
    }

    /// Applies a decoration layer built outside `CodeViewport` (e.g. LSP
    /// semantic tokens, converted into a `.semantic` layer by
    /// `LanguageClient`'s `SemanticTokenDecorationSource`). Generic over
    /// any `DecorationLayerKind` so `CodeViewport` never needs to depend
    /// on the module that produced the layer; stale (wrong snapshot
    /// version) or superseded (older layer version) layers are rejected
    /// by the compositor exactly like `applyLexicalCaptures`.
    @discardableResult
    public func applyDecorationLayer(_ layer: DecorationLayerSnapshot) -> Bool {
        guard decorationCompositor.apply(layer) else {
            return false
        }
        lineCache.removeAll(keepingCapacity: true)
        needsDisplay = true
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
            cursor(forUTF8Offset: currentHoverUTF8Offset).set()
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

    func cursor(forUTF8Offset utf8Offset: Int) -> NSCursor {
        if hoveredLinkUTF8Range?.contains(utf8Offset) == true {
            return .pointingHand
        }
        return .iBeam
    }

    // MARK: - Folding

    public func isFoldable(atLine line: Int) -> Bool {
        foldRangesByHeaderLine[line] != nil
    }

    public func isFolded(atLine line: Int) -> Bool {
        foldedHeaderLines.contains(line)
    }

    public func foldableHeaderLines() -> Set<Int> {
        Set(foldRangesByHeaderLine.keys)
    }

    /// The header lines currently folded, e.g. to preserve across an
    /// external-reload snapshot replacement (SPEC 5.6).
    public func foldedHeaderLinesSnapshot() -> Set<Int> {
        foldedHeaderLines
    }

    /// Requests that `lines` be folded, applying immediately for any
    /// already-known fold header and deferring the rest until
    /// `applySyntaxTree(_:)` next resolves fold ranges (e.g. right after
    /// constructing a viewport for a freshly reloaded snapshot, before its
    /// first parse completes).
    public func restoreFoldedHeaderLines(_ lines: Set<Int>) {
        pendingFoldedHeaderLines = lines
        let applicableNow = lines.filter { foldRangesByHeaderLine[$0] != nil }
        guard !applicableNow.isEmpty else {
            return
        }
        foldedHeaderLines.formUnion(applicableNow)
        foldStateVersion += 1
        updateDocumentSize()
        needsDisplay = true
    }

    /// Toggles the fold at `line` if it is a fold header. No-op otherwise.
    public func toggleFold(atLine line: Int) {
        guard foldRangesByHeaderLine[line] != nil else {
            return
        }
        if foldedHeaderLines.contains(line) {
            foldedHeaderLines.remove(line)
        } else {
            foldedHeaderLines.insert(line)
        }
        foldStateVersion += 1
        updateDocumentSize()
        needsDisplay = true
    }

    private static func computeFoldRanges(from tree: SyntaxTree) -> [Int: FoldRange] {
        var byHeader: [Int: FoldRange] = [:]
        for range in tree.foldRanges() {
            if let existing = byHeader[range.headerLine], existing.endLine >= range.endLine {
                continue
            }
            byHeader[range.headerLine] = range
        }
        return byHeader
    }

    // MARK: - Matching brackets

    /// The bracket pair enclosing/adjacent to the current selection's
    /// anchor, if any, using the last-applied lexical captures to exclude
    /// bracket-like bytes inside strings and comments.
    public func matchingBracketPair() -> BracketMatch? {
        guard let anchor = selectedUTF8Range?.lowerBound ?? anchorUTF8Offset else {
            return nil
        }
        let excluded = lastLexicalCaptures
            .filter { $0.name.hasPrefix("string") || $0.name.hasPrefix("comment") }
            .map(\.utf8Range)
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

    private var foldingActive: Bool {
        !foldedHeaderLines.isEmpty
    }

    private var totalVisualRows: Int {
        visualRowStarts?.last ?? snapshot.lineCount
    }

    private var currentMetrics: ViewportMetrics {
        rebuildVisualMetricsIfNeeded()
        let contentWidth: CGFloat
        if wrapEligible, visualRowStarts != nil {
            contentWidth = max(minimumViewportWidth, gutterWidth + rightPadding + characterWidth)
        } else {
            let estimatedLineWidth = CGFloat(snapshot.longestLineUTF8Length) * characterWidth
            contentWidth = max(
                minimumViewportWidth,
                gutterWidth + estimatedLineWidth + rightPadding
            )
        }
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
        needsDisplay = true
    }

    /// Measures the gutter width needed to fit `lineCount`'s largest line
    /// number plus a fold-indicator glyph, at the two font sizes
    /// `lineNumberLayout(at:)` actually draws with — kept in exact sync
    /// with that drawing code so this measurement can never under- or
    /// over-estimate what gets painted. Never below the original fixed
    /// 64pt budget, so
    /// short files/small fonts keep their existing spacious layout.
    static func lineNumberFont(for editorFont: NSFont) -> NSFont {
        NSFont.monospacedDigitSystemFont(
            ofSize: max(9, editorFont.pointSize - 2),
            weight: .regular
        )
    }

    static func foldIndicatorFont(for editorFont: NSFont) -> NSFont {
        NSFont.systemFont(
            ofSize: max(14, editorFont.pointSize + 1),
            weight: .medium
        )
    }

    static func measureGutterWidth(lineCount: Int, resolvedFont: ResolvedFont) -> CGFloat {
        let digitCount = max(1, String(max(1, lineCount)).count)
        let sample = NSMutableAttributedString(
            string: "\u{25BE} ",
            attributes: [.font: foldIndicatorFont(for: resolvedFont.nsFont)]
        )
        sample.append(NSAttributedString(
            string: String(repeating: "8", count: digitCount),
            attributes: [.font: lineNumberFont(for: resolvedFont.nsFont)]
        ))
        let line = CTLineCreateWithAttributedString(sample)
        let measuredWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        // Matches the 12pt gap `drawLine(atVisualRow:line:segmentIndex:)`
        // already leaves between the number and `gutterWidth`, plus a
        // small margin so the widest digit glyph never touches the
        // code column's first character.
        return max(64, measuredWidth + 12 + 4)
    }

    private func updateDocumentSize() {
        setFrameSize(currentMetrics.contentSize)
    }

    private func invalidateWrapCache() {
        visualRowStarts = nil
        wrapColumnsUsed = 0
        wrappedSegmentCache.removeAll(keepingCapacity: true)
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
        guard wrapEligible || foldingActive else {
            if visualRowStarts != nil {
                visualRowStarts = nil
                hiddenLines = []
                wrappedSegmentCache.removeAll(keepingCapacity: true)
                lineCache.removeAll(keepingCapacity: true)
            }
            return
        }

        let maxColumns = wrapEligible ? wrapMaxColumns() : 0
        guard !wrapEligible || maxColumns > 0 else {
            return
        }

        let needsRebuild = visualRowStarts == nil
            || (wrapEligible && wrapColumnsUsed != maxColumns)
            || foldStateVersion != visualMetricsFoldVersion
        guard needsRebuild else {
            return
        }

        let hidden = computeHiddenLines()
        var starts = [Int](repeating: 0, count: snapshot.lineCount + 1)
        for line in 0..<snapshot.lineCount {
            let rowCount: Int
            if hidden.indices.contains(line), hidden[line] {
                rowCount = 0
            } else if wrapEligible {
                let text = snapshot.line(at: line) ?? ""
                rowCount = wrapUnitRanges(text, maxColumns: maxColumns).count
            } else {
                rowCount = 1
            }
            starts[line + 1] = starts[line] + rowCount
        }
        visualRowStarts = starts
        hiddenLines = hidden
        wrapColumnsUsed = maxColumns
        visualMetricsFoldVersion = foldStateVersion
        wrappedSegmentCache.removeAll(keepingCapacity: true)
        lineCache.removeAll(keepingCapacity: true)
    }

    private func computeHiddenLines() -> [Bool] {
        guard foldingActive, snapshot.lineCount > 0 else {
            return []
        }
        var hidden = [Bool](repeating: false, count: snapshot.lineCount)
        for header in foldedHeaderLines {
            guard let range = foldRangesByHeaderLine[header] else {
                continue
            }
            let start = range.headerLine + 1
            let end = min(range.endLine, snapshot.lineCount - 1)
            guard start <= end else {
                continue
            }
            for line in start...end {
                hidden[line] = true
            }
        }
        return hidden
    }

    private func wrapMaxColumns() -> Int {
        let availableWidth = max(minimumViewportWidth, gutterWidth + rightPadding + characterWidth)
        return max(1, Int(floor((availableWidth - gutterWidth - rightPadding) / characterWidth)))
    }

    /// Splits `text` into word-wrapped UTF-16 code-unit ranges of at most
    /// `maxColumns` units, preferring to break at the nearest preceding
    /// whitespace so words are not split unless a single token exceeds the
    /// available width.
    private func wrapUnitRanges(_ text: String, maxColumns: Int) -> [Range<Int>] {
        let units = Array(text.utf16)
        let unitCount = units.count
        guard unitCount > maxColumns else {
            return [0..<unitCount]
        }

        var ranges: [Range<Int>] = []
        var start = 0
        while start < unitCount {
            let hardEnd = min(start + maxColumns, unitCount)
            var breakUnit = hardEnd
            if hardEnd < unitCount {
                var candidate = hardEnd
                while candidate > start, !isWrapWhitespace(units[candidate - 1]) {
                    candidate -= 1
                }
                if candidate > start {
                    breakUnit = candidate
                }
            }
            ranges.append(start..<breakUnit)
            start = breakUnit
        }
        return ranges.isEmpty ? [0..<unitCount] : ranges
    }

    private func isWrapWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09
    }

    /// The UTF-8 sub-ranges of `line` that each render on their own visual
    /// row. A single-element array when wrap is disabled or ineligible.
    private func wrapSegments(forLine line: Int) -> [Range<Int>] {
        guard let lineRange = snapshot.utf8RangeForLine(line) else {
            return []
        }
        guard wrapEligible, visualRowStarts != nil, wrapColumnsUsed > 0 else {
            return [lineRange]
        }
        if let cached = wrappedSegmentCache[line] {
            return cached
        }

        let text = snapshot.line(at: line) ?? ""
        let unitRanges = wrapUnitRanges(text, maxColumns: wrapColumnsUsed)
        var utf8Segments: [Range<Int>] = []
        utf8Segments.reserveCapacity(unitRanges.count)

        for (index, unitRange) in unitRanges.enumerated() {
            let startOffset: Int
            if unitRange.lowerBound == 0 {
                startOffset = lineRange.lowerBound
            } else {
                startOffset = (try? snapshot.utf8Offset(
                    for: SourcePosition(line: line, character: unitRange.lowerBound),
                    encoding: .utf16
                )) ?? lineRange.lowerBound
            }
            let endOffset: Int
            if index == unitRanges.count - 1 {
                endOffset = lineRange.upperBound
            } else {
                endOffset = (try? snapshot.utf8Offset(
                    for: SourcePosition(line: line, character: unitRange.upperBound),
                    encoding: .utf16
                )) ?? lineRange.upperBound
            }
            utf8Segments.append(startOffset..<max(startOffset, endOffset))
        }

        let segments = utf8Segments.isEmpty ? [lineRange] : utf8Segments
        wrappedSegmentCache[line] = segments
        return segments
    }

    /// Not `private`: reused by `CodeViewportAccessibility.swift` to derive
    /// on-screen frames for per-line and per-annotation accessibility
    /// elements from the same visual-row bookkeeping the drawing path uses.
    func visualRowRange(forLine line: Int) -> Range<Int> {
        guard let starts = visualRowStarts, starts.indices.contains(line + 1) else {
            return line..<(line + 1)
        }
        return starts[line]..<starts[line + 1]
    }

    /// Maps a visual row back to its source line and the segment index
    /// within that line, via binary search over the prefix-sum table.
    private func sourceLine(forVisualRow row: Int) -> (line: Int, segmentIndex: Int) {
        guard let starts = visualRowStarts, snapshot.lineCount > 0 else {
            let line = max(0, min(row, max(0, snapshot.lineCount - 1)))
            return (line, 0)
        }

        var lowerBound = 0
        var upperBound = starts.count - 1
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound + 1) / 2
            if starts[midpoint] <= row {
                lowerBound = midpoint
            } else {
                upperBound = midpoint - 1
            }
        }

        let line = max(0, min(lowerBound, snapshot.lineCount - 1))
        return (line, max(0, row - starts[line]))
    }

    private func visualRow(forUTF8Offset offset: Int) -> Int {
        guard let position = try? snapshot.position(forUTF8Offset: offset, encoding: .utf8) else {
            return 0
        }
        let rowRange = visualRowRange(forLine: position.line)
        guard wrapEligible, visualRowStarts != nil else {
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
                string: " " + Self.foldIndicatorGlyph,
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

        let runs = decorationCompositor.composedRuns(inUTF8Range: segmentRange)
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
        let attributed = NSMutableAttributedString()
        if isFoldable(atLine: index) {
            attributed.append(NSAttributedString(
                string: isFolded(atLine: index) ? "\u{25B8} " : "\u{25BE} ",
                attributes: [
                    .font: Self.foldIndicatorFont(for: resolvedFont.nsFont),
                    .foregroundColor: theme.editor.gutterForeground.nsColor
                ]
            ))
        }
        attributed.append(NSAttributedString(
            string: String(index + 1),
            attributes: [
                .font: Self.lineNumberFont(for: resolvedFont.nsFont),
                .foregroundColor: theme.editor.gutterForeground.nsColor
            ]
        ))
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
            context.textPosition = CGPoint(x: gutterWidth - 12 - numberWidth, y: baseline)
            CTLineDraw(number, context)
        }
        context.restoreGState()
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

            theme.editor.stickyScopeBackground.nsColor.setFill()
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

    private func foldableLine(atPoint point: NSPoint) -> Int? {
        rebuildVisualMetricsIfNeeded()
        guard lineHeight > 0 else {
            return 0
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

    private static let foldIndicatorGlyph = "\u{22EF}"
}
