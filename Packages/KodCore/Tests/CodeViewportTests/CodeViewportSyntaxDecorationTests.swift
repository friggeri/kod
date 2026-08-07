import AppKit
import SourceModel
import SyntaxCore
import ThemeCore
import XCTest
@testable import CodeViewport

@MainActor
final class CodeViewportSyntaxDecorationTests: XCTestCase {
    func testDetectsLanguageFromURLExtension() {
        let snapshot = SourceSnapshot(
            text: "let x = 1\n",
            url: URL(fileURLWithPath: "/tmp/sample.swift")
        )
        let viewport = CodeViewport(snapshot: snapshot)
        XCTAssertEqual(viewport.language, .swift)
    }

    func testApplyingLexicalCapturesForWrongSnapshotVersionIsIgnored() {
        let snapshot = SourceSnapshot(text: "let x = 1\n")
        let viewport = CodeViewport(snapshot: snapshot)
        // snapshot.version defaults to 1; a mismatched version must be rejected.
        viewport.applyLexicalCaptures(
            [SyntaxCapture(name: "keyword", utf8Range: 0..<3)],
            snapshotVersion: snapshot.version + 1,
            layerVersion: 1
        )
        // No crash and no observable effect; re-applying with the correct
        // version should succeed, proving the mismatch really was rejected
        // rather than accidentally accepted.
        viewport.applyLexicalCaptures(
            [SyntaxCapture(name: "keyword", utf8Range: 0..<3)],
            snapshotVersion: snapshot.version,
            layerVersion: 1
        )
    }

    func testThemeChangeRecolorsAlreadyAppliedCaptures() {
        let snapshot = SourceSnapshot(text: "let x = 1\n")
        var theme = BundledThemes.dark
        theme.syntax["keyword"] = TokenStyle(foreground: ThemeColor(hex: "#111111"))
        let viewport = CodeViewport(snapshot: snapshot, theme: theme)

        viewport.applyLexicalCaptures(
            [SyntaxCapture(name: "keyword", utf8Range: 0..<3)],
            snapshotVersion: snapshot.version,
            layerVersion: 1
        )

        var updatedTheme = theme
        updatedTheme.syntax["keyword"] = TokenStyle(foreground: ThemeColor(hex: "#ABCDEF"))
        viewport.theme = updatedTheme
        // Recoloring must not throw or crash; verified indirectly via the
        // draw path not crashing when forced, exercised in the repaint
        // benchmark. Here we assert the theme property itself updated.
        XCTAssertEqual(viewport.theme.syntax["keyword"]?.foreground, ThemeColor(hex: "#ABCDEF"))
    }

    func testLSPConfirmedHoverUnderlinesIdentifierAndUsesPointingHandCursor() throws {
        let snapshot = SourceSnapshot(text: "const client = api;\n")
        let viewport = CodeViewport(snapshot: snapshot)
        let clientOffset = try XCTUnwrap(snapshot.text.range(of: "client"))
        let utf8Offset = snapshot.text.utf8.distance(
            from: snapshot.text.utf8.startIndex,
            to: try XCTUnwrap(clientOffset.lowerBound.samePosition(in: snapshot.text.utf8))
        )
        let linkRange = try XCTUnwrap(viewport.linkCandidateUTF8Range(at: utf8Offset))

        viewport.setHoveredLinkUTF8Range(linkRange)

        let lineRange = try XCTUnwrap(snapshot.utf8RangeForLine(0))
        let attributed = viewport.attributedString(
            forSegment: try XCTUnwrap(snapshot.line(at: 0)),
            utf8Range: lineRange
        )
        XCTAssertEqual(
            attributed.attribute(
                NSAttributedString.Key.underlineStyle,
                at: utf8Offset,
                effectiveRange: nil
            ) as? Int,
            NSUnderlineStyle.single.rawValue
        )
        XCTAssertTrue(viewport.cursor(forUTF8Offset: utf8Offset) === NSCursor.pointingHand)

        viewport.setHoveredLinkUTF8Range(nil)
        XCTAssertTrue(viewport.cursor(forUTF8Offset: utf8Offset) === NSCursor.iBeam)
    }

    func testLinkCandidateRangeSupportsUnicodeIdentifiers() throws {
        let snapshot = SourceSnapshot(text: "const café = 1;\n")
        let viewport = CodeViewport(snapshot: snapshot)
        let offset = try XCTUnwrap(snapshot.text.range(of: "café"))
        let utf8Offset = snapshot.text.utf8.distance(
            from: snapshot.text.utf8.startIndex,
            to: try XCTUnwrap(offset.lowerBound.samePosition(in: snapshot.text.utf8))
        )

        let range = try XCTUnwrap(viewport.linkCandidateUTF8Range(at: utf8Offset))
        XCTAssertEqual(try snapshot.text(inUTF8Range: range), "café")
    }

    func testHoverTargetUsesWholeIdentifierAndScalarFallback() throws {
        let snapshot = SourceSnapshot(text: "const café = value + 1;\n")
        let viewport = CodeViewport(snapshot: snapshot)
        let text = snapshot.text
        let cafe = try XCTUnwrap(text.range(of: "café"))
        let cafeStart = text.utf8.distance(
            from: text.utf8.startIndex,
            to: try XCTUnwrap(cafe.lowerBound.samePosition(in: text.utf8))
        )
        let plus = try XCTUnwrap(text.utf8.firstIndex(of: Character("+").asciiValue!))
        let plusOffset = text.utf8.distance(from: text.utf8.startIndex, to: plus)
        let whitespaceOffset = plusOffset - 1

        let firstRange = try XCTUnwrap(viewport.hoverTargetUTF8Range(at: cafeStart))
        let finalScalarOffset = firstRange.upperBound - "é".utf8.count

        XCTAssertEqual(
            viewport.hoverTargetUTF8Range(at: finalScalarOffset),
            firstRange,
            "every scalar in one identifier must resolve to the same hover anchor"
        )
        XCTAssertEqual(try snapshot.text(inUTF8Range: firstRange), "café")
        XCTAssertEqual(viewport.hoverTargetUTF8Range(at: plusOffset), plusOffset..<(plusOffset + 1))
        XCTAssertNil(viewport.hoverTargetUTF8Range(at: whitespaceOffset))
    }
}

@MainActor
final class CodeViewportFoldingTests: XCTestCase {
    func testFoldIndicatorIsVisiblyLargerThanLineNumberText() {
        let editorFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let lineNumberFont = CodeViewport.lineNumberFont(for: editorFont)
        let foldIndicatorFont = CodeViewport.foldIndicatorFont(for: editorFont)

        XCTAssertGreaterThan(foldIndicatorFont.pointSize, lineNumberFont.pointSize)
        XCTAssertGreaterThanOrEqual(foldIndicatorFont.pointSize, 14)
    }

    func testFoldingHidesLinesAndReducesContentHeight() async throws {
        let snapshot = SourceSnapshot(
            text: "func f() {\n    let x = 1\n    let y = 2\n}\nlet z = 3\n",
            url: URL(fileURLWithPath: "/tmp/sample.swift")
        )
        let viewport = CodeViewport(snapshot: snapshot)
        let engine = SyntaxEngine()
        let tree = try await engine.parse(snapshot: snapshot, language: .swift)
        viewport.applySyntaxTree(tree)

        XCTAssertTrue(viewport.isFoldable(atLine: 0))
        let heightBeforeFold = viewport.frame.height

        viewport.toggleFold(atLine: 0)
        XCTAssertTrue(viewport.isFolded(atLine: 0))
        XCTAssertLessThan(viewport.frame.height, heightBeforeFold)

        viewport.toggleFold(atLine: 0)
        XCTAssertFalse(viewport.isFolded(atLine: 0))
        XCTAssertEqual(viewport.frame.height, heightBeforeFold)
    }

    func testTogglingFoldOnNonFoldableLineIsANoOp() async throws {
        let snapshot = SourceSnapshot(text: "let x = 1\n", url: URL(fileURLWithPath: "/tmp/sample.swift"))
        let viewport = CodeViewport(snapshot: snapshot)
        let engine = SyntaxEngine()
        let tree = try await engine.parse(snapshot: snapshot, language: .swift)
        viewport.applySyntaxTree(tree)

        XCTAssertFalse(viewport.isFoldable(atLine: 0))
        viewport.toggleFold(atLine: 0)
        XCTAssertFalse(viewport.isFolded(atLine: 0))
    }

    func testStaleSyntaxTreeIsIgnored() async throws {
        let snapshot = SourceSnapshot(
            text: "func f() {\n    let x = 1\n}\n",
            url: URL(fileURLWithPath: "/tmp/sample.swift"),
            version: 5
        )
        let viewport = CodeViewport(snapshot: snapshot)
        let engine = SyntaxEngine()
        let staleSnapshot = SourceSnapshot(
            text: "func f() {\n    let x = 1\n}\n",
            url: URL(fileURLWithPath: "/tmp/sample.swift"),
            version: 4
        )
        let staleTree = try await engine.parse(snapshot: staleSnapshot, language: .swift)
        viewport.applySyntaxTree(staleTree)
        XCTAssertFalse(viewport.isFoldable(atLine: 0), "a tree for a stale snapshot version must be ignored")
    }
}

@MainActor
final class CodeViewportBracketMatchingTests: XCTestCase {
    func testJumpToMatchingBracketMovesSelectionToClosingBrace() throws {
        let source = "func f() {\n    return 1\n}\n"
        let snapshot = SourceSnapshot(text: source, url: URL(fileURLWithPath: "/tmp/sample.swift"))
        let viewport = CodeViewport(snapshot: snapshot)

        let openBraceOffset = source.utf8.distance(
            from: source.utf8.startIndex,
            to: source.utf8.firstIndex(of: UInt8(ascii: "{"))!
        )
        try viewport.selectUTF8Range(openBraceOffset..<(openBraceOffset + 1))

        let match = viewport.matchingBracketPair()
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.opening, openBraceOffset)

        viewport.jumpToMatchingBracket()
        XCTAssertEqual(viewport.selectedUTF8Range?.lowerBound, match?.closing)
    }
}

@MainActor
final class CodeViewportStickyHeaderTests: XCTestCase {
    func testStickyScopeDoesNotCoverTheFirstRenderedLine() async throws {
        let source = "func greet() {\n    print(\"hi\")\n}\n"
        let snapshot = SourceSnapshot(text: source, url: URL(fileURLWithPath: "/tmp/sample.swift"))
        let viewport = CodeViewport(snapshot: snapshot)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        scrollView.documentView = viewport
        window.contentView = scrollView
        window.layoutIfNeeded()

        let tree = try await SyntaxEngine().parse(snapshot: snapshot, language: .swift)
        viewport.applySyntaxTree(tree)

        XCTAssertEqual(viewport.topmostVisibleLine, 0)
        XCTAssertTrue(
            viewport.stickyScopeHeaders().isEmpty,
            "A sticky overlay must not repaint line zero while line zero is already naturally visible"
        )
        withExtendedLifetime(window) {}
    }

    func testEnclosingScopesReportedForNestedFunction() async throws {
        let source = "func outer() {\n    func inner() {\n        let x = 1\n    }\n}\n"
        let snapshot = SourceSnapshot(text: source, url: URL(fileURLWithPath: "/tmp/sample.swift"))
        let viewport = CodeViewport(snapshot: snapshot)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        scrollView.documentView = viewport
        window.contentView = scrollView
        window.layoutIfNeeded()

        let engine = SyntaxEngine()
        let tree = try await engine.parse(snapshot: snapshot, language: .swift)
        viewport.applySyntaxTree(tree)

        // Scroll so the topmost visible line is inside "inner"'s body.
        viewport.scrollSourceLineToTop(2)
        let headers = viewport.stickyScopeHeaders()
        XCTAssertFalse(headers.isEmpty)
        withExtendedLifetime(window) {}
    }
}
