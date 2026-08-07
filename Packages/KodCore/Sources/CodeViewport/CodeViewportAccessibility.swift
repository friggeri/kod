import AppKit
import SourceModel

// MARK: - Accessibility model, at a glance
//
// `CodeViewport` already speaks the baseline `NSAccessibility` vocabulary
// (role, value, selected text/range — see the overrides near the top of
// `CodeViewport.swift`). This file adds the richer surface VoiceOver users
// need to actually navigate a source file: per-line elements, hit-testing,
// a real syntax-aware attributed string, and custom rotors over the
// document's symbols/diagnostics/references/folds/git changes.
//
// Why annotations are a separate pipeline from decoration
// ---------------------------------------------------------
// `DecorationCompositor` (SyntaxCore/Decoration/DecorationLayer.swift)
// answers "what color/weight should this byte range paint?" — it is a
// pixel pipeline, versioned per `DecorationLayerKind`, and only cares
// about what is visually true right now. `CodeAccessibilityAnnotation`
// answers a different question: "what should VoiceOver say this range
// *means*?" A byte range can be simultaneously a `lexical` decoration run
// (say, a function name colored by the theme) and a `.symbol` annotation
// (its accessible role, spoken as "Function greet"), but these two facts
// are produced by different subsystems on different cadences (decoration
// re-renders on every keystroke/theme change; annotations are pushed by a
// language server or git diff on a much coarser schedule) and consumed by
// different clients (the compositor by `draw(_:)`; annotations only by
// this file). Conflating them into one model would force every visual
// repaint to also revalidate accessibility labels, and vice versa, for no
// benefit — so `applyAccessibilityAnnotations(_:)` only ever triggers
// `needsDisplay` for API consistency with `applyDecorationLayer(_:)`; it
// never changes a single drawn pixel.
//
// Why per-line elements use line-number identity
// -----------------------------------------------
// Per SPEC's virtualized-rendering philosophy (the same reason
// `visibleUTF8Range`/`topmostVisibleLine` exist), `accessibilityChildren()`
// only ever materializes elements for currently *visible* lines — a fresh
// `CodeLineAccessibilityElement` is created every time the method is
// called, exactly like every other on-demand, non-retained view in this
// codebase. That is fine for AppKit's pull model, but VoiceOver also
// tracks "is this the same logical item as last time?" (e.g. to preserve
// its cursor position in a rotor or avoid re-announcing an unchanged
// line). So `CodeLineAccessibilityElement` overrides `isEqual`/`hash` to
// key identity purely on the source line number, not on the transient
// frame/text a particular query happened to compute. This is a documented
// best-effort tradeoff: two elements for the same line are `==`/same
// `hash` even if their captured frame/text differ (e.g. mid-scroll), but
// nothing here promises pointer identity across calls.
//
// The fold/rotor contract
// -------------------------
// Fold state (`foldRangesByHeaderLine`/`foldedHeaderLines`) is not part of
// the caller-supplied `accessibilityAnnotations` array — it is derived
// fresh, on demand, from the viewport's own public `foldableHeaderLines()`/
// `isFolded(atLine:)`, so a fold toggled via the gutter or
// `toggleFold(atLine:)` is instantly reflected without any caller having
// to keep annotations in sync. Every annotation `Kind` case that has at
// least one instance (from `accessibilityAnnotations` or the derived fold
// annotations) gets exactly one `NSAccessibilityCustomRotor`; kinds with
// zero instances are omitted rather than exposing an empty rotor. Item
// search walks the kind's array in ascending document order and returns
// `nil` once a `next`/`previous` search runs past the last/first item —
// `NSAccessibilityCustomRotor.h` only documents that a `nil` `currentItem`
// starts from the first (`.next`) or last (`.previous`) item; it does not
// document wraparound, so none is implemented here.
//
// A note on a real macOS SDK limitation
// ----------------------------------------
// `NSAccessibilityCustomRotor.ItemResult(targetElement:)` requires its
// argument to satisfy the Swift-only `NSAccessibilityElementProtocol`
// (the importer's name for the small, formal `NSAccessibilityElement`
// Objective-C protocol declaring `accessibilityFrame`/`accessibilityParent`
// — distinct from the `NSAccessibilityElement` *class*). As of the
// installed macOS SDK, the `NSAccessibilityElement` class itself does not
// satisfy that protocol (its inherited `accessibilityIdentifier()`
// resolves to a different, incompatible optionality than the protocol
// requires), so a `NSAccessibilityElement` subclass cannot be passed to
// that initializer. `CodeLineAccessibilityElement` (used only via
// `accessibilityChildren()`/`accessibilityHitTest(_:)`, which are
// untyped `Any`/`Any?` returns) still subclasses `NSAccessibilityElement`
// exactly as a natural per-line element should. `CodeAnnotationAccessibilityElement`
// (used as a rotor's `targetElement:`) is instead a plain `NSObject`
// directly conforming to `NSAccessibilityElementProtocol`, implementing
// the same handful of accessibility selectors dynamically — this is a
// deliberate adaptation to the real, verified SDK behavior, not a
// deviation from the intended design.

/// One accessibility-relevant annotation attached to a UTF-8 byte range in
/// the document — a symbol, a diagnostic, a reference, or a git change —
/// used only to drive VoiceOver's custom rotors and is otherwise inert
/// (see the file-level discussion above for why this is not part of the
/// visual decoration pipeline).
public struct CodeAccessibilityAnnotation: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A named program symbol, e.g. `kindName: "function"` or `"class"`.
        case symbol(kindName: String)
        /// A compiler/linter diagnostic, e.g. `severity: "error"`.
        case diagnostic(severity: String)
        /// A reference to a symbol defined elsewhere.
        case reference
        /// A foldable region header, e.g. collapsed/expanded state.
        /// A real, distinct case rather than reusing `.symbol`: folds are
        /// a viewport presentation concept (nothing a language server
        /// reports), not a program symbol, so they deserve their own
        /// rotor and their own spoken vocabulary ("Foldable region…").
        case fold
        /// An inline Git change marker, e.g. `changeType: "added"`.
        case gitChange(changeType: String)
    }

    public let kind: Kind
    public let utf8Range: Range<Int>
    public let label: String

    public init(kind: Kind, utf8Range: Range<Int>, label: String) {
        self.kind = kind
        self.utf8Range = utf8Range
        self.label = label
    }
}

@MainActor
extension CodeViewport {
    /// Replaces the current set of accessibility annotations wholesale.
    /// The caller (a language server bridge, diagnostics engine, or git
    /// diff provider) is solely responsible for only calling this with
    /// annotations that match the viewport's current `snapshot` — there is
    /// no snapshot-version guard here, mirroring `applyDecorationLayer(_:)`'s
    /// contract but without needing the layer/version bookkeeping, since
    /// annotations are simple replace-on-call metadata, not compositor
    /// runs. Triggers `needsDisplay` purely for API symmetry with the
    /// decoration pipeline; annotations never change a drawn pixel.
    public func applyAccessibilityAnnotations(_ annotations: [CodeAccessibilityAnnotation]) {
        accessibilityAnnotations = annotations
        needsDisplay = true
    }

    /// Fold-derived annotations, recomputed fresh from `foldableHeaderLines()`/
    /// `isFolded(atLine:)` on every call so they always reflect the latest
    /// fold state without the caller needing to resupply them.
    private func foldAccessibilityAnnotations() -> [CodeAccessibilityAnnotation] {
        foldableHeaderLines().sorted().compactMap { headerLine in
            guard let lineRange = snapshot.utf8RangeForLine(headerLine) else {
                return nil
            }
            let state = isFolded(atLine: headerLine) ? "collapsed" : "expanded"
            return CodeAccessibilityAnnotation(
                kind: .fold,
                utf8Range: lineRange,
                label: "Foldable region, line \(headerLine + 1), \(state)"
            )
        }
    }

    /// All annotations — caller-supplied plus fold-derived — that custom
    /// rotors search over.
    private func allAccessibilityAnnotations() -> [CodeAccessibilityAnnotation] {
        accessibilityAnnotations + foldAccessibilityAnnotations()
    }

    // MARK: - Read-only semantics

    /// Denies any selector that would let an assistive-technology client
    /// mutate document *content* as an edit (SPEC: "read-only" means
    /// content cannot be changed, not that selection is disallowed —
    /// selecting text to read or copy it is a normal read-only operation,
    /// so selection-range selectors are left to the default/super
    /// behavior rather than denied here).
    public override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(NSAccessibilityElement.setAccessibilityValue(_:)) {
            return false
        }
        return super.isAccessibilitySelectorAllowed(selector)
    }

    public override func accessibilityRoleDescription() -> String? {
        "read-only source code"
    }

    public override func accessibilityHelp() -> String? {
        "Displays source code for reading and copying; its contents cannot be edited."
    }

    // MARK: - Bidirectional selection

    /// Converts an assistive-technology client's document-wide UTF-16
    /// `NSRange` (the unit `accessibilitySelectedTextRange`/VoiceOver
    /// APIs use) to the internal UTF-8 selection via
    /// `SourceSnapshot.globalUTF8Offset(forGlobalUTF16Offset:)`, then
    /// applies it exactly as `selectUTF8Range(_:)` would.
    public func selectUTF16Range(_ range: NSRange) throws {
        guard range.location != NSNotFound else {
            throw SourceSnapshotError.invalidUTF8Offset(range.location)
        }
        let startUTF8 = try snapshot.globalUTF8Offset(forGlobalUTF16Offset: range.location)
        let endUTF8 = try snapshot.globalUTF8Offset(forGlobalUTF16Offset: range.location + range.length)
        try selectUTF8Range(startUTF8..<endUTF8)
    }

    // MARK: - Attributed string exposure

    /// Real AppKit override name for `NSAccessibilityStaticText`/
    /// `NSAccessibility`'s "attributed string for range" parameterized
    /// attribute (`accessibilityAttributedStringForRange:` in
    /// Objective-C; confirmed via the installed SDK's
    /// `NSAccessibilityProtocols.h` and by direct override-signature
    /// type-checking). Converts the UTF-16 range to UTF-8 via the
    /// snapshot and returns a real, themed attributed string (font,
    /// foreground color, ligatures, kerning) by reusing
    /// `baseTextAttributes()` rather than plain black-on-white text.
    public override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard range.location != NSNotFound, range.length >= 0 else {
            return nil
        }
        guard let startUTF8 = try? snapshot.globalUTF8Offset(forGlobalUTF16Offset: range.location),
              let endUTF8 = try? snapshot.globalUTF8Offset(
                forGlobalUTF16Offset: range.location + range.length
              ),
              startUTF8 <= endUTF8,
              let text = try? snapshot.text(inUTF8Range: startUTF8..<endUTF8) else {
            return nil
        }
        return NSAttributedString(string: text, attributes: baseTextAttributes())
    }

    // MARK: - Hit testing

    /// AppKit calls `accessibilityHitTest(_:)` with a point in *screen*
    /// coordinates (the same contract `NSView`'s default implementation
    /// receives — verified against the `NSAccessibility` header's
    /// `accessibilityHitTest:` documentation), so this first converts
    /// screen -> window -> view space before reusing the same
    /// `sourceOffset(at:)` point-to-byte-offset lookup mouse hit-testing
    /// uses, then returns the visible line element at that source line.
    ///
    /// Declared `nonisolated`, unlike this file's other overrides: unlike
    /// `accessibilityLabel()`/`accessibilityChildren()`/etc., the
    /// Swift overlay does not expose `accessibilityHitTest(_:)` as
    /// actor-isolated (it comes from the untyped `NSObject (NSAccessibility)`
    /// category in the Objective-C header), so an override matching its
    /// real signature cannot itself be `@MainActor`. AppKit only ever
    /// calls accessibility hit-testing on the main thread, so hopping in
    /// with `MainActor.assumeIsolated` to reach this MainActor view's
    /// state is safe.
    public nonisolated override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        nonisolated(unsafe) var result: Any?
        MainActor.assumeIsolated {
            result = self.hitTestElement(atScreenPoint: point)
        }
        return result
    }

    private func hitTestElement(atScreenPoint point: NSPoint) -> Any? {
        guard let window else {
            return super.accessibilityHitTest(point)
        }
        let windowPoint = window.convertPoint(fromScreen: point)
        let viewPoint = convert(windowPoint, from: nil)
        guard bounds.contains(viewPoint) else {
            return super.accessibilityHitTest(point)
        }
        let offset = sourceOffset(at: viewPoint)
        guard let position = try? snapshot.position(forUTF8Offset: offset, encoding: .utf8) else {
            return super.accessibilityHitTest(point)
        }
        return lineAccessibilityElement(forLine: position.line)
    }

    // MARK: - Per-visible-line accessibility children

    /// One `CodeLineAccessibilityElement` per currently *visible* source
    /// line (virtualized, matching the rest of this codebase's rendering
    /// philosophy — see the file-level doc comment for the identity
    /// tradeoff this implies).
    public override func accessibilityChildren() -> [Any]? {
        guard snapshot.lineCount > 0 else {
            return []
        }
        let byteRange = visibleUTF8Range
        guard !byteRange.isEmpty,
              let firstLine = try? snapshot.position(
                forUTF8Offset: byteRange.lowerBound,
                encoding: .utf8
              ).line,
              let lastLine = try? snapshot.position(
                forUTF8Offset: max(byteRange.lowerBound, byteRange.upperBound - 1),
                encoding: .utf8
              ).line,
              firstLine <= lastLine else {
            return []
        }
        return (firstLine...lastLine).map { lineAccessibilityElement(forLine: $0) }
    }

    private func lineAccessibilityElement(forLine line: Int) -> CodeLineAccessibilityElement {
        CodeLineAccessibilityElement(
            lineNumber: line,
            text: snapshot.line(at: line) ?? "",
            frame: screenRect(forLine: line),
            owner: self
        )
    }

    /// The line's vertical band (spanning every visual row it occupies,
    /// e.g. more than one for a word-wrapped line), converted from view
    /// space to screen space, matching the line's actual drawn position.
    private func screenRect(forLine line: Int) -> NSRect {
        rebuildVisualMetricsIfNeeded()
        let rowRange = visualRowRange(forLine: line)
        let viewRect = NSRect(
            x: 0,
            y: CGFloat(rowRange.lowerBound) * lineHeight,
            width: bounds.width,
            height: CGFloat(max(1, rowRange.count)) * lineHeight
        )
        return convertRectToScreen(viewRect)
    }

    private func convertRectToScreen(_ rect: NSRect) -> NSRect {
        let windowRect = convert(rect, to: nil)
        guard let window else {
            return windowRect
        }
        return window.convertToScreen(windowRect)
    }

    // MARK: - Custom rotors

    /// One rotor per annotation `Kind` case that has at least one
    /// instance right now (caller-supplied plus fold-derived); kinds with
    /// zero instances are skipped rather than exposing an empty rotor.
    /// See the file-level doc comment for the exact, header-confirmed
    /// search-direction contract each rotor's delegate implements.
    public override func accessibilityCustomRotors() -> [NSAccessibilityCustomRotor] {
        let combined = allAccessibilityAnnotations()
        var rotors: [NSAccessibilityCustomRotor] = []
        var delegates: [AnyObject] = []

        for (label, matches) in Self.rotorKinds {
            let matching = combined
                .filter(matches)
                .sorted { $0.utf8Range.lowerBound < $1.utf8Range.lowerBound }
            let items = matching.compactMap(rotorItem(for:))
            guard !items.isEmpty else {
                continue
            }
            let delegate = CodeAnnotationRotorItemSearchDelegate(items: items, viewport: self)
            delegates.append(delegate)
            rotors.append(NSAccessibilityCustomRotor(label: label, itemSearchDelegate: delegate))
        }

        // Retained here because `NSAccessibilityCustomRotor.itemSearchDelegate`
        // is a `weak` property — see the doc comment on
        // `activeRotorDelegates` in `CodeViewport.swift`.
        activeRotorDelegates = delegates
        return rotors
    }

    private static let rotorKinds: [(label: String, matches: (CodeAccessibilityAnnotation) -> Bool)] = [
        ("Symbols", { if case .symbol = $0.kind { true } else { false } }),
        ("Diagnostics", { if case .diagnostic = $0.kind { true } else { false } }),
        ("References", { if case .reference = $0.kind { true } else { false } }),
        ("Folds", { if case .fold = $0.kind { true } else { false } }),
        ("Git Changes", { if case .gitChange = $0.kind { true } else { false } })
    ]

    private func rotorItem(for annotation: CodeAccessibilityAnnotation) -> RotorItem? {
        guard let start = try? snapshot.globalUTF16Offset(forUTF8Offset: annotation.utf8Range.lowerBound),
              let end = try? snapshot.globalUTF16Offset(forUTF8Offset: annotation.utf8Range.upperBound) else {
            return nil
        }
        return RotorItem(annotation: annotation, utf16Range: NSRange(location: start, length: end - start))
    }

    /// Builds the rotor result an item-search delegate returns for one
    /// matched annotation: a `CodeAnnotationAccessibilityElement` wrapping
    /// its label and a real, screen-space frame derived from the
    /// annotation's starting line. The element is appended to
    /// `activeRotorAnnotationElements` because `ItemResult.targetElement`
    /// is only a `weak` reference (see the doc comment on that property
    /// in `CodeViewport.swift`) — without an external strong owner the
    /// element would be deallocated before an assistive-technology client
    /// could read it back.
    fileprivate func makeRotorItemResult(for item: RotorItem) -> NSAccessibilityCustomRotor.ItemResult? {
        guard let line = try? snapshot.position(
            forUTF8Offset: item.annotation.utf8Range.lowerBound,
            encoding: .utf8
        ).line else {
            return nil
        }
        let element = CodeAnnotationAccessibilityElement(
            label: item.annotation.label,
            frame: screenRect(forLine: line),
            owner: self
        )
        activeRotorAnnotationElements.append(element)
        let result = NSAccessibilityCustomRotor.ItemResult(targetElement: element)
        result.targetRange = item.utf16Range
        return result
    }
}

/// One annotation paired with its precomputed document-wide UTF-16 range,
/// used to answer rotor item-search "before/after `currentItem`" queries
/// without re-deriving the UTF-16 offset on every search.
fileprivate struct RotorItem {
    let annotation: CodeAccessibilityAnnotation
    let utf16Range: NSRange
}

/// A lightweight, per-query accessibility element representing one
/// currently-visible source line. Subclasses `NSAccessibilityElement`
/// directly (unlike `CodeAnnotationAccessibilityElement` below — see the
/// file-level doc comment for why the two differ) since it is only ever
/// returned as an untyped `Any`/`Any?` from `accessibilityChildren()`/
/// `accessibilityHitTest(_:)`, never passed to an API that requires
/// static `NSAccessibilityElementProtocol` conformance.
///
/// Identity/equality is keyed purely on `lineNumber`, not on the
/// transient `text`/`frame` a particular query happened to capture, so
/// VoiceOver's notion of "the same element" survives scrolling back to a
/// previously-seen line even though virtualization means the instance
/// itself is recreated on every `accessibilityChildren()` call.
final class CodeLineAccessibilityElement: NSAccessibilityElement {
    let lineNumber: Int
    private let text: String
    private let frame: NSRect
    private weak var owner: CodeViewport?

    init(lineNumber: Int, text: String, frame: NSRect, owner: CodeViewport) {
        self.lineNumber = lineNumber
        self.text = text
        self.frame = frame
        self.owner = owner
        super.init()
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .staticText
    }

    override func accessibilityLabel() -> String? {
        "Line \(lineNumber + 1)"
    }

    override func accessibilityValue() -> Any? {
        text
    }

    override func accessibilityParent() -> Any? {
        owner
    }

    override func accessibilityFrame() -> NSRect {
        frame
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? CodeLineAccessibilityElement else {
            return false
        }
        return other.lineNumber == lineNumber
    }

    override var hash: Int {
        lineNumber
    }
}

/// A lightweight, per-query accessibility element representing one
/// annotation (a symbol, diagnostic, reference, fold, or git change),
/// returned as a custom rotor's item result.
///
/// This is a plain `NSObject` conforming directly to
/// `NSAccessibilityElementProtocol`, *not* an `NSAccessibilityElement`
/// subclass, because `NSAccessibilityCustomRotor.ItemResult(targetElement:)`
/// requires its argument to statically satisfy that protocol, and the
/// installed macOS SDK's `NSAccessibilityElement` class does not itself
/// satisfy it (see the file-level doc comment for the exact, verified
/// mismatch). Implementing the required `accessibilityFrame()`/
/// `accessibilityParent()` plus the informal `accessibilityRole()`/
/// `accessibilityLabel()` selectors directly on a plain `NSObject`
/// sidesteps that SDK limitation while still responding to every
/// selector a real `NSAccessibilityElement` would.
final class CodeAnnotationAccessibilityElement: NSObject, NSAccessibilityElementProtocol {
    private let label: String
    private let frame: NSRect
    private weak var owner: CodeViewport?

    init(label: String, frame: NSRect, owner: CodeViewport) {
        self.label = label
        self.frame = frame
        self.owner = owner
    }

    func accessibilityFrame() -> NSRect {
        frame
    }

    func accessibilityParent() -> Any? {
        owner
    }

    func accessibilityRole() -> NSAccessibility.Role? {
        .staticText
    }

    func accessibilityLabel() -> String? {
        label
    }
}

/// Walks one annotation kind's sorted-by-document-position items forward
/// or backward from `parameters.currentItem`, per the real, header-
/// documented `NSAccessibilityCustomRotor` search contract: a `nil`
/// `currentItem` starts from the first (`.next`) or last (`.previous`)
/// item; searching past the last/first item returns `nil` rather than
/// wrapping (wraparound is not part of the documented contract, so none
/// is implemented).
///
/// Deliberately not `@MainActor`: `NSAccessibilityCustomRotorItemSearchDelegate`
/// is a plain (non-isolated) Objective-C protocol, so a conforming type's
/// requirement can't itself be MainActor-isolated. AppKit only invokes
/// rotor search on the main thread, so hopping onto `MainActor` inside
/// the method body via `MainActor.assumeIsolated` to reach the
/// MainActor-isolated `viewport` is safe.
private final class CodeAnnotationRotorItemSearchDelegate: NSObject, NSAccessibilityCustomRotorItemSearchDelegate {
    private let items: [RotorItem]
    private weak var viewport: CodeViewport?

    init(items: [RotorItem], viewport: CodeViewport) {
        self.items = items
        self.viewport = viewport
    }

    func rotor(
        _ rotor: NSAccessibilityCustomRotor,
        resultFor searchParameters: NSAccessibilityCustomRotor.SearchParameters
    ) -> NSAccessibilityCustomRotor.ItemResult? {
        // Extract only Sendable primitives from `searchParameters` (a
        // class, and this method's task-isolated parameter) before
        // hopping onto `MainActor`: capturing the class instance itself
        // inside the `assumeIsolated` closure would make the compiler
        // flag it as "sent" across an isolation domain it might still
        // be used from concurrently, even though AppKit only calls this
        // delegate synchronously from the main thread.
        let currentLocation = searchParameters.currentItem?.targetRange.location
        let searchDirection = searchParameters.searchDirection
        let items = self.items
        let viewport = self.viewport

        nonisolated(unsafe) var result: NSAccessibilityCustomRotor.ItemResult?
        MainActor.assumeIsolated {
            guard let viewport, !items.isEmpty else {
                return
            }

            let resolvedCurrentLocation: Int? = (currentLocation != nil && currentLocation != NSNotFound) ? currentLocation : nil

            let index: Int?
            switch searchDirection {
            case .next:
                if let resolvedCurrentLocation {
                    index = items.firstIndex { $0.utf16Range.location > resolvedCurrentLocation }
                } else {
                    index = items.indices.first
                }
            case .previous:
                if let resolvedCurrentLocation {
                    index = items.lastIndex { $0.utf16Range.location < resolvedCurrentLocation }
                } else {
                    index = items.indices.last
                }
            @unknown default:
                index = nil
            }

            guard let index, items.indices.contains(index) else {
                return
            }
            result = viewport.makeRotorItemResult(for: items[index])
        }
        return result
    }
}
