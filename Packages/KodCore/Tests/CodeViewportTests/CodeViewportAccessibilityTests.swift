import AppKit
import SourceModel
import SyntaxCore
import XCTest
@testable import CodeViewport

/// Covers the richer `NSAccessibility` surface added in
/// `CodeViewportAccessibility.swift`: annotation storage/rotors, fold
/// annotations tracking live fold state, bidirectional UTF-16/UTF-8
/// selection, the syntax-aware attributed-string override, hit-testing,
/// per-visible-line children, and the read-only selector guard. Geometry-
/// dependent tests (hit-testing, children, rotor frames) host the
/// viewport in a real (never-shown) window + scroll view, exactly like
/// `TenMegabyteRepaintBenchmarkTests`/`CodeDocumentViewControllerTests`,
/// since a superview-less `NSView` reports `visibleRect` as infinite.
@MainActor
final class CodeViewportAccessibilityTests: XCTestCase {
    private var windows: [NSWindow] = []

    private func hostedViewport(snapshot: SourceSnapshot, size: NSSize = NSSize(width: 400, height: 400)) -> CodeViewport {
        let viewport = CodeViewport(snapshot: snapshot)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scrollView.documentView = viewport
        window.contentView = scrollView
        window.setContentSize(size)
        window.layoutIfNeeded()
        windows.append(window)
        viewport.setMinimumViewportWidth(size.width)
        return viewport
    }

    // MARK: - Annotations + rotors

    func testApplyAccessibilityAnnotationsPopulatesOnlyMatchingRotors() {
        let snapshot = SourceSnapshot(text: "func greet() {\n    print(\"hi\")\n}\n")
        let viewport = CodeViewport(snapshot: snapshot)

        viewport.applyAccessibilityAnnotations([
            CodeAccessibilityAnnotation(kind: .symbol(kindName: "function"), utf8Range: 0..<4, label: "Function greet"),
            CodeAccessibilityAnnotation(kind: .diagnostic(severity: "error"), utf8Range: 5..<9, label: "Error: Unexpected token")
        ])

        let rotors = viewport.accessibilityCustomRotors()
        let labels = Set(rotors.map(\.label))

        XCTAssertTrue(labels.contains("Symbols"))
        XCTAssertTrue(labels.contains("Diagnostics"))
        XCTAssertFalse(labels.contains("References"), "no reference annotations were supplied")
        XCTAssertFalse(labels.contains("Git Changes"), "no git-change annotations were supplied")
    }

    func testNoRotorsWhenNoAnnotationsAndNoFoldableLines() {
        let snapshot = SourceSnapshot(text: "let value = 42\n")
        let viewport = CodeViewport(snapshot: snapshot)

        XCTAssertEqual(viewport.accessibilityCustomRotors(), [])
    }

    // MARK: - Fold annotations

    func testFoldAnnotationLabelTracksLiveFoldState() async throws {
        let snapshot = SourceSnapshot(
            text: "func f() {\n    let x = 1\n    let y = 2\n}\nlet z = 3\n",
            url: URL(fileURLWithPath: "/tmp/sample.swift")
        )
        let viewport = CodeViewport(snapshot: snapshot)
        let engine = SyntaxEngine()
        let tree = try await engine.parse(snapshot: snapshot, language: .swift)
        viewport.applySyntaxTree(tree)

        XCTAssertTrue(viewport.isFoldable(atLine: 0))

        let rotorsBeforeFold = viewport.accessibilityCustomRotors()
        XCTAssertTrue(rotorsBeforeFold.contains { $0.label == "Folds" })

        let expandedLabel = try foldAnnotationLabel(for: viewport)
        XCTAssertEqual(expandedLabel, "Foldable region, line 1, expanded")

        viewport.toggleFold(atLine: 0)
        XCTAssertTrue(viewport.isFolded(atLine: 0))

        let collapsedLabel = try foldAnnotationLabel(for: viewport)
        XCTAssertEqual(collapsedLabel, "Foldable region, line 1, collapsed")
        XCTAssertNotEqual(collapsedLabel, expandedLabel)

        viewport.toggleFold(atLine: 0)
        let reExpandedLabel = try foldAnnotationLabel(for: viewport)
        XCTAssertEqual(reExpandedLabel, expandedLabel)
    }

    /// Extracts the label of the sole "Folds" rotor's first item by
    /// walking the rotor's item-search delegate forward from `nil`,
    /// mirroring how VoiceOver itself would query it.
    private func foldAnnotationLabel(for viewport: CodeViewport) throws -> String {
        let rotors = viewport.accessibilityCustomRotors()
        guard let foldRotor = rotors.first(where: { $0.label == "Folds" }) else {
            XCTFail("expected a Folds rotor")
            throw XCTSkip("missing Folds rotor")
        }
        let result = try firstForwardResult(of: foldRotor)
        guard let targetElement = result?.targetElement as? CodeAnnotationAccessibilityElement,
              let label = targetElement.accessibilityLabel() else {
            XCTFail("expected a labeled target element")
            throw XCTSkip("missing label")
        }
        return label
    }

    // MARK: - Bidirectional selection

    func testSelectUTF16RangeMatchesEquivalentUTF8Selection() throws {
        // "a😀b\né": a(1 byte/1 u16) 😀(4 bytes/2 u16) b(1/1) \n(1/1) é(2 bytes/1 u16).
        // UTF-8 offsets 5..<6 ("b") correspond to UTF-16 offsets 3..<4.
        let snapshot = SourceSnapshot(text: "a😀b\né")
        let viaUTF16 = CodeViewport(snapshot: snapshot)
        let viaUTF8 = CodeViewport(snapshot: snapshot)

        try viaUTF16.selectUTF16Range(NSRange(location: 3, length: 1))
        try viaUTF8.selectUTF8Range(5..<6)

        XCTAssertEqual(viaUTF16.accessibilitySelectedText(), "b")
        XCTAssertEqual(viaUTF16.accessibilitySelectedText(), viaUTF8.accessibilitySelectedText())
        XCTAssertEqual(viaUTF16.accessibilitySelectedTextRange(), viaUTF8.accessibilitySelectedTextRange())
    }

    func testSelectUTF16RangeAcrossEmojiSelectsWholeCharacter() throws {
        let snapshot = SourceSnapshot(text: "a😀b\né")
        let viewport = CodeViewport(snapshot: snapshot)

        // UTF-16 offsets 1..<3 span the full surrogate pair for the emoji.
        try viewport.selectUTF16Range(NSRange(location: 1, length: 2))

        XCTAssertEqual(viewport.accessibilitySelectedText(), "😀")
    }

    // MARK: - Attributed string exposure

    func testAccessibilityAttributedStringReturnsThemedTextForValidRange() throws {
        let snapshot = SourceSnapshot(text: "let value = 42\n")
        let viewport = CodeViewport(snapshot: snapshot)

        let range = NSRange(location: 0, length: 3)
        let attributed = viewport.accessibilityAttributedString(for: range)

        let attributedString = try XCTUnwrap(attributed)
        XCTAssertEqual(attributedString.string, "let")
        XCTAssertTrue(attributedString.length > 0)
        let font = attributedString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font, "expected a real font attribute, not plain unstyled text")
    }

    func testAccessibilityAttributedStringReturnsNilForOutOfBoundsRange() {
        let snapshot = SourceSnapshot(text: "abc")
        let viewport = CodeViewport(snapshot: snapshot)

        let outOfBounds = NSRange(location: 1_000, length: 5)
        XCTAssertNil(viewport.accessibilityAttributedString(for: outOfBounds))

        let notFound = NSRange(location: NSNotFound, length: 0)
        XCTAssertNil(viewport.accessibilityAttributedString(for: notFound))
    }

    // MARK: - Hit testing

    func testAccessibilityHitTestReturnsElementForVisibleLine() {
        let snapshot = SourceSnapshot(text: "line one\nline two\nline three\n")
        let viewport = hostedViewport(snapshot: snapshot)

        // A point near the top of the view, well inside line 0's row.
        let viewPoint = NSPoint(x: 5, y: 5)
        let windowPoint = viewport.convert(viewPoint, to: nil)
        guard let window = viewport.window else {
            XCTFail("expected the hosted viewport to have a window")
            return
        }
        let screenPoint = window.convertPoint(toScreen: windowPoint)

        let hit = viewport.accessibilityHitTest(screenPoint)
        guard let element = hit as? CodeLineAccessibilityElement else {
            XCTFail("expected accessibilityHitTest to return a CodeLineAccessibilityElement")
            return
        }
        XCTAssertEqual(element.accessibilityLabel(), "Line 1")
    }

    // MARK: - Per-visible-line children

    func testAccessibilityChildrenReturnsOneElementPerVisibleLineInOrder() {
        let lines = (0..<50).map { "line \($0)" }.joined(separator: "\n")
        let snapshot = SourceSnapshot(text: lines)
        let viewport = hostedViewport(snapshot: snapshot, size: NSSize(width: 400, height: 200))

        let children = try? XCTUnwrap(viewport.accessibilityChildren())
        guard let children, !children.isEmpty else {
            XCTFail("expected at least one visible line element")
            return
        }
        let lineElements = children.compactMap { $0 as? CodeLineAccessibilityElement }
        XCTAssertEqual(lineElements.count, children.count, "every child must be a CodeLineAccessibilityElement")

        let values = lineElements.map { $0.accessibilityValue() as? String }
        XCTAssertEqual(values.first, "line 0")

        // Ordering must be top-to-bottom, i.e. ascending source line number.
        let lineNumbers = lineElements.map(\.lineNumber)
        XCTAssertEqual(lineNumbers, lineNumbers.sorted(), "children must be ordered top-to-bottom")
        XCTAssertFalse(lineNumbers.isEmpty)
    }

    // MARK: - Custom rotor navigation

    func testRotorForwardNavigationWalksAnnotationsInDocumentOrderThenStops() throws {
        let snapshot = SourceSnapshot(text: "func a() {}\nfunc b() {}\nfunc c() {}\n")
        let viewport = CodeViewport(snapshot: snapshot)
        viewport.applyAccessibilityAnnotations([
            CodeAccessibilityAnnotation(kind: .symbol(kindName: "function"), utf8Range: 5..<6, label: "Function a"),
            CodeAccessibilityAnnotation(kind: .symbol(kindName: "function"), utf8Range: 18..<19, label: "Function b"),
            CodeAccessibilityAnnotation(kind: .symbol(kindName: "function"), utf8Range: 31..<32, label: "Function c")
        ])

        let rotors = viewport.accessibilityCustomRotors()
        let symbolRotor = try XCTUnwrap(rotors.first { $0.label == "Symbols" })

        let first = try firstForwardResult(of: symbolRotor)
        let firstElement = try XCTUnwrap(first?.targetElement as? CodeAnnotationAccessibilityElement)
        XCTAssertEqual(firstElement.accessibilityLabel(), "Function a")

        let second = try forwardResult(of: symbolRotor, from: first)
        let secondElement = try XCTUnwrap(second?.targetElement as? CodeAnnotationAccessibilityElement)
        XCTAssertEqual(secondElement.accessibilityLabel(), "Function b")

        let third = try forwardResult(of: symbolRotor, from: second)
        let thirdElement = try XCTUnwrap(third?.targetElement as? CodeAnnotationAccessibilityElement)
        XCTAssertEqual(thirdElement.accessibilityLabel(), "Function c")

        // Past the last item there is no documented wraparound: further
        // forward search must return nil, not restart from the first item.
        let fourth = try forwardResult(of: symbolRotor, from: third)
        XCTAssertNil(fourth)
    }

    private func firstForwardResult(
        of rotor: NSAccessibilityCustomRotor
    ) throws -> NSAccessibilityCustomRotor.ItemResult? {
        try forwardResult(of: rotor, from: nil)
    }

    private func forwardResult(
        of rotor: NSAccessibilityCustomRotor,
        from currentItem: NSAccessibilityCustomRotor.ItemResult?
    ) throws -> NSAccessibilityCustomRotor.ItemResult? {
        let delegate = try XCTUnwrap(rotor.itemSearchDelegate)
        let params = NSAccessibilityCustomRotor.SearchParameters()
        params.currentItem = currentItem
        params.searchDirection = .next
        params.filterString = ""
        return delegate.rotor(rotor, resultFor: params)
    }

    // MARK: - Read-only selector guard

    func testIsAccessibilitySelectorAllowedDeniesValueMutationButKeepsSelectionAndCopy() throws {
        let snapshot = SourceSnapshot(text: "alpha beta")
        let viewport = CodeViewport(snapshot: snapshot)

        XCTAssertFalse(
            viewport.isAccessibilitySelectorAllowed(#selector(NSAccessibilityElement.setAccessibilityValue(_:)))
        )

        // Selection-related selectors (reading/selecting, not editing) and
        // the existing copy/selectAll behavior must be unaffected.
        try viewport.selectUTF8Range(0..<5)
        viewport.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "alpha")

        viewport.selectAll(nil)
        XCTAssertEqual(viewport.accessibilitySelectedText(), "alpha beta")
    }
}
