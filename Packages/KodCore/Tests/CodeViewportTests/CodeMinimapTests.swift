import AppKit
import SourceModel
import SyntaxCore
import ThemeCore
import XCTest
@testable import CodeViewport

private func pixelRGBA(
    in image: NSImage,
    x: Int,
    y: Int
) throws -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
    var proposedRect = NSRect(origin: .zero, size: image.size)
    let cgImage = try XCTUnwrap(
        image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    )
    let width = cgImage.width
    let height = cgImage.height
    guard x >= 0, x < width, y >= 0, y < height else {
        throw CocoaError(.validationMissingMandatoryProperty)
    }
    let data = try XCTUnwrap(cgImage.dataProvider?.data)
    let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
    let offset = y * cgImage.bytesPerRow + x * 4
    return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
}

final class CodeMinimapLayoutTests: XCTestCase {
    func testProportionalLayoutHandlesRetinaAndNonRetinaGeometry() {
        let standard = CodeMinimapLayout(
            bounds: CGRect(x: 0, y: 0, width: 100, height: 400),
            backingScale: 1,
            totalRows: 1_000,
            visibleSourceRows: 40,
            sourceScrollY: 500,
            maximumSourceScrollY: 1_000,
            requestedColumns: 200
        )
        let retina = CodeMinimapLayout(
            bounds: standard.bounds,
            backingScale: 2,
            totalRows: standard.totalRows,
            visibleSourceRows: standard.visibleSourceRows,
            sourceScrollY: standard.sourceScrollY,
            maximumSourceScrollY: standard.maximumSourceScrollY,
            requestedColumns: 200
        )

        XCTAssertEqual(standard.rowHeight, 2)
        XCTAssertEqual(retina.rowHeight, 1)
        XCTAssertEqual(standard.columns, 120)
        XCTAssertGreaterThan(retina.visibleRowWindow.count, standard.visibleRowWindow.count)
        XCTAssertEqual(standard.sliderFrame.midY, standard.bounds.midY, accuracy: 0.01)
    }

    func testEmptyTinyAndAdversarialGeometryStayFiniteAndClamped() {
        let layout = CodeMinimapLayout(
            bounds: CGRect(x: 0, y: 0, width: -.infinity, height: .nan),
            backingScale: 0,
            totalRows: -12,
            visibleSourceRows: .infinity,
            sourceScrollY: -.infinity,
            maximumSourceScrollY: -.infinity,
            requestedColumns: Int.max
        )

        XCTAssertEqual(layout.bounds.size, .zero)
        XCTAssertEqual(layout.backingScale, 1)
        XCTAssertEqual(layout.totalRows, 0)
        XCTAssertTrue(layout.visibleRowWindow.isEmpty)
        XCTAssertEqual(layout.sliderFrame, .zero)
        XCTAssertEqual(layout.sourceScrollY(centeredAtMinimapY: 50), 0)
    }

    func testClickAndDragMappingClampToNativeScrollRange() {
        let layout = CodeMinimapLayout(
            bounds: CGRect(x: 0, y: 0, width: 80, height: 200),
            backingScale: 2,
            totalRows: 500,
            visibleSourceRows: 25,
            sourceScrollY: 400,
            maximumSourceScrollY: 1_000,
            requestedColumns: 80
        )

        XCTAssertEqual(layout.sourceScrollY(centeredAtMinimapY: -10), 226.315, accuracy: 0.01)
        XCTAssertEqual(layout.sourceScrollY(centeredAtMinimapY: 100), 436.842, accuracy: 0.01)
        XCTAssertEqual(layout.sourceScrollY(centeredAtMinimapY: 400), 647.368, accuracy: 0.01)
        XCTAssertEqual(
            layout.sourceScrollY(draggingSliderFrom: 400, deltaY: -10_000),
            0
        )
        XCTAssertEqual(
            layout.sourceScrollY(draggingSliderFrom: 400, deltaY: 10_000),
            1_000
        )
    }

    func testShortDocumentSliderDragUsesProportionalWindowTrack() {
        let layout = CodeMinimapLayout(
            bounds: CGRect(x: 0, y: 0, width: 96, height: 800),
            backingScale: 2,
            totalRows: 200,
            visibleSourceRows: 40,
            sourceScrollY: 0,
            maximumSourceScrollY: 3_200,
            requestedColumns: 120
        )

        XCTAssertEqual(layout.windowHeight, 200)
        XCTAssertEqual(layout.sliderFrame.height, 40)
        XCTAssertEqual(layout.trackTravel, 160)
        XCTAssertEqual(
            layout.sourceScrollY(draggingSliderFrom: 0, deltaY: 80),
            1_600,
            accuracy: 0.001
        )
        XCTAssertEqual(
            layout.sourceScrollY(draggingSliderFrom: 0, deltaY: 160),
            3_200,
            accuracy: 0.001
        )
    }

    func testRecommendedWidthRespectsContainerAndHardCaps() {
        XCTAssertEqual(CodeMinimapLayout.recommendedWidth(containerWidth: 0, requestedColumns: 120), 48)
        XCTAssertLessThanOrEqual(
            CodeMinimapLayout.recommendedWidth(containerWidth: 4_000, requestedColumns: 1_000),
            160
        )
        XCTAssertLessThanOrEqual(
            CodeMinimapLayout.recommendedWidth(containerWidth: 320, requestedColumns: 120),
            320 * 0.18
        )
    }

    func testSliderEdgesTrackVisibleRowsInsideProportionalWindowAtEveryScrollPositionAndScale() {
        for scale in [CGFloat(1), 2] {
            for scrollY in [CGFloat(0), 500, 1_000] {
                let layout = CodeMinimapLayout(
                    bounds: CGRect(x: 0, y: 0, width: 80, height: 200),
                    backingScale: scale,
                    totalRows: 500,
                    visibleSourceRows: 25,
                    sourceScrollY: scrollY,
                    maximumSourceScrollY: 1_000,
                    requestedColumns: 80
                )

                XCTAssertEqual(
                    layout.sliderFrame.minY,
                    layout.y(forVisualRow: layout.firstVisibleRow),
                    accuracy: 0.51
                )
                XCTAssertEqual(
                    layout.sliderFrame.maxY,
                    layout.y(forVisualRow: layout.firstVisibleRow + layout.visibleSourceRows),
                    accuracy: 0.51
                )
            }
        }
    }

}

@MainActor
final class CodeMinimapPresentationTests: XCTestCase {
    func testGlyphAtlasDistinguishesSpacesASCIIAndUnicodeFallback() {
        let atlas = CodeMinimapGlyphAtlas.shared
        XCTAssertEqual(atlas.glyph(for: " ").mask, 0)
        XCTAssertNotEqual(atlas.glyph(for: "A").mask, 0)
        XCTAssertEqual(atlas.glyph(for: "é"), atlas.unknown)
        XCTAssertEqual(atlas.glyph(for: "界").columns, 2)
    }

    func testCappedTextHandlesTabsFullWidthAndMaximumColumns() {
        XCTAssertEqual(MinimapPresentationSnapshotBuilder.cappedText("\tAB", maxColumns: 5), "\tA")
        XCTAssertEqual(MinimapPresentationSnapshotBuilder.cappedText("A界B", maxColumns: 3), "A界")
        XCTAssertEqual(
            MinimapPresentationSnapshotBuilder.cappedText(
                String(repeating: "x", count: 200),
                maxColumns: 120
            ).count,
            120
        )
    }

    func testPresentationUsesComposedTokenColorsAndViewZoneBlankRows() {
        let snapshot = SourceSnapshot(text: "let value = 1\nsecond\n", version: 7)
        let viewport = CodeViewport(snapshot: snapshot, syntaxLanguage: .swift)
        viewport.applyLexicalCaptures(
            [SyntaxCapture(name: "keyword", utf8Range: 0..<3)],
            snapshotVersion: 7,
            layerVersion: 1
        )
        XCTAssertTrue(viewport.installViewZone(
            id: CodeViewZoneID("test"),
            afterLine: 0,
            heightInLines: 2,
            view: NSView()
        ))

        let presentation = viewport.minimapPresentation(
            visualRows: 0..<viewport.minimapTotalVisualRows,
            maxColumns: 120
        )

        XCTAssertEqual(presentation.totalVisualRows, snapshot.lineCount + 2)
        XCTAssertEqual(presentation.rows.filter(\.isViewZone).count, 2)
        XCTAssertEqual(presentation.rows.first?.tokenSpans.first?.color, viewport.theme.syntax["keyword"]?.foreground)
    }

    func testWordWrapPresentationReusesViewportVisualRows() {
        let snapshot = SourceSnapshot(text: String(repeating: "word ", count: 80))
        let viewport = CodeViewport(snapshot: snapshot)
        viewport.wordWrapEnabled = true
        viewport.theme = BundledThemes.light
        viewport.setMinimumViewportWidth(120)

        XCTAssertGreaterThan(viewport.minimapTotalVisualRows, snapshot.lineCount)
        let presentation = viewport.minimapPresentation(
            visualRows: 0..<viewport.minimapTotalVisualRows,
            maxColumns: 120
        )
        XCTAssertEqual(presentation.rows.count, viewport.minimapTotalVisualRows)
        XCTAssertEqual(Set(presentation.rows.compactMap(\.sourceLine)), [0])
    }

    func testMarkerInsideCollapsedRegionMapsToVisibleFoldHeader() async throws {
        let snapshot = SourceSnapshot(
            text: "func f() {\n    let x = 1\n    let y = 2\n}\n",
            url: URL(fileURLWithPath: "/tmp/minimap-fold.swift")
        )
        let viewport = CodeViewport(snapshot: snapshot)
        viewport.applySyntaxTree(
            try await SyntaxEngine().parse(snapshot: snapshot, language: .swift)
        )
        viewport.toggleFold(atLine: 0)
        let hiddenRange = try XCTUnwrap(snapshot.utf8RangeForLine(2))

        XCTAssertEqual(viewport.minimapVisualRows(forUTF8Range: hiddenRange), [0])
    }

    func testRendererBuffersRemainViewportBoundedForHugeDocuments() {
        let layout = CodeMinimapLayout(
            bounds: CGRect(x: 0, y: 0, width: 96, height: 600),
            backingScale: 2,
            totalRows: 1_000_000,
            visibleSourceRows: 30,
            sourceScrollY: 0,
            maximumSourceScrollY: 20_000_000,
            requestedColumns: 120
        )
        let presentation = CodeMinimapPresentation(
            totalVisualRows: 1_000_000,
            rows: [],
            requestedRows: layout.visibleRowWindow
        )
        let renderer = CodeMinimapRenderer()
        renderer.render(presentation: presentation, layout: layout, theme: .init(
            identifier: "test",
            name: "Test",
            appearance: .dark,
            surface: BundledThemes.dark.surface,
            editor: BundledThemes.dark.editor,
            syntax: [:],
            diagnostics: BundledThemes.dark.diagnostics,
            git: BundledThemes.dark.git
        ))

        XCTAssertEqual(renderer.bufferPixelSize.width, 192)
        XCTAssertEqual(renderer.bufferPixelSize.height, 1_200)
    }

    func testBaseBitmapUsesTopDownRowsAndOverlayAlignsWithFirstVisualRow() throws {
        var theme = BundledThemes.dark
        theme.minimap.background = ThemeColor(red: 0, green: 0, blue: 0)
        theme.minimap.foregroundOpacity = 1
        theme.minimap.selection = ThemeColor(red: 0, green: 1, blue: 0)
        let red = ThemeColor(red: 1, green: 0, blue: 0)
        let blue = ThemeColor(red: 0, green: 0, blue: 1)
        let layout = CodeMinimapLayout(
            bounds: CGRect(x: 0, y: 0, width: 10, height: 4),
            backingScale: 1,
            totalRows: 2,
            visibleSourceRows: 1,
            sourceScrollY: 0,
            maximumSourceScrollY: 20,
            requestedColumns: 2
        )
        let presentation = CodeMinimapPresentation(
            totalVisualRows: 2,
            rows: [
                CodeMinimapVisualRow(
                    visualRow: 0,
                    sourceLine: 0,
                    segmentIndex: 0,
                    utf8Range: 0..<1,
                    text: "A",
                    tokenSpans: [CodeMinimapTokenSpan(columns: 0..<1, color: red)],
                    isViewZone: false
                ),
                CodeMinimapVisualRow(
                    visualRow: 1,
                    sourceLine: 1,
                    segmentIndex: 0,
                    utf8Range: 2..<3,
                    text: "A",
                    tokenSpans: [CodeMinimapTokenSpan(columns: 0..<1, color: blue)],
                    isViewZone: false
                )
            ],
            requestedRows: 0..<2
        )
        let renderer = CodeMinimapRenderer()
        renderer.render(presentation: presentation, layout: layout, theme: theme)
        let image = try XCTUnwrap(renderer.image)
        let backgroundPixel = try pixelRGBA(in: image, x: 0, y: 0)
        let firstRowPixel = try pixelRGBA(in: image, x: 4, y: 0)
        let lastRowPixel = try pixelRGBA(in: image, x: 4, y: 2)
        XCTAssertEqual(
            Int(backgroundPixel.alpha),
            Int((CodeMinimapRenderer.maximumBackgroundOpacity * 255).rounded()),
            accuracy: 1
        )
        XCTAssertGreaterThan(firstRowPixel.red, firstRowPixel.blue)
        XCTAssertGreaterThan(lastRowPixel.blue, lastRowPixel.red)

        let snapshot = SourceSnapshot(text: "A\nA")
        let viewport = CodeViewport(snapshot: snapshot, theme: theme)
        let scrollView = NSScrollView(frame: layout.bounds)
        scrollView.documentView = viewport
        let minimap = CodeMinimapView(viewport: viewport, scrollView: scrollView)
        minimap.frame = layout.bounds
        minimap.updateMarkers(CodeMinimapMarkers(selection: 0..<1))
        let overlaidImage = try XCTUnwrap(minimap.snapshotImage(layout: layout))
        let selectedPixel = try pixelRGBA(in: overlaidImage, x: 1, y: 0)
        let unselectedPixel = try pixelRGBA(in: overlaidImage, x: 1, y: 2)
        XCTAssertGreaterThan(selectedPixel.green, selectedPixel.red)
        XCTAssertLessThan(unselectedPixel.green, selectedPixel.green)
    }

    func testRenderedOverlayPrecedenceUsesSelectionThenFindThenDiagnosticThenGitThenSlider() throws {
        var theme = BundledThemes.dark
        theme.minimap.background = ThemeColor(red: 0, green: 0, blue: 0)
        theme.minimap.selection = ThemeColor(red: 0, green: 1, blue: 0)
        theme.minimap.find = ThemeColor(red: 1, green: 1, blue: 0)
        theme.minimap.error = ThemeColor(red: 1, green: 0, blue: 0)
        theme.minimap.gutterModified = ThemeColor(red: 0, green: 0, blue: 1)
        theme.minimap.sliderHover = ThemeColor(red: 1, green: 0, blue: 1)
        let snapshot = SourceSnapshot(text: "A\nA\nA\nA")
        let viewport = CodeViewport(snapshot: snapshot, theme: theme)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 16, height: 8))
        scrollView.documentView = viewport
        let minimap = CodeMinimapView(viewport: viewport, scrollView: scrollView)
        minimap.frame = scrollView.bounds
        minimap.updateMarkers(CodeMinimapMarkers(
            selection: 0..<snapshot.utf8Count,
            findMatches: [0..<1, 2..<3, 4..<5],
            diagnostics: [
                CodeMinimapDiagnosticMarker(utf8Range: 2..<3, severity: .error),
                CodeMinimapDiagnosticMarker(utf8Range: 4..<5, severity: .error)
            ],
            gitChanges: [
                CodeGutterChange(
                    id: "modified",
                    kind: .modified,
                    location: .lines(2..<3),
                    accessibilityLabel: "Modified"
                )
            ]
        ))
        let layout = CodeMinimapLayout(
            bounds: minimap.bounds,
            backingScale: 1,
            totalRows: viewport.minimapTotalVisualRows,
            visibleSourceRows: 4,
            sourceScrollY: 0,
            maximumSourceScrollY: 0,
            requestedColumns: 4
        )

        let layered = try XCTUnwrap(minimap.snapshotImage(layout: layout))
        let selection = try pixelRGBA(in: layered, x: 1, y: 0)
        XCTAssertGreaterThan(selection.green, selection.red)
        let find = try pixelRGBA(in: layered, x: 9, y: 0)
        XCTAssertGreaterThan(find.red, find.blue)
        XCTAssertGreaterThan(find.green, find.blue)
        let diagnostic = try pixelRGBA(in: layered, x: 9, y: 2)
        XCTAssertGreaterThan(diagnostic.red, diagnostic.green)
        let git = try pixelRGBA(in: layered, x: 14, y: 4)
        XCTAssertGreaterThan(git.blue, git.red)

        let hover = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        ))
        minimap.mouseEntered(with: hover)
        let withSlider = try XCTUnwrap(minimap.snapshotImage(layout: layout))
        for point in [(1, 0), (9, 0), (9, 2), (14, 4)] {
            let pixel = try pixelRGBA(in: withSlider, x: point.0, y: point.1)
            XCTAssertGreaterThan(pixel.red, pixel.green)
            XCTAssertGreaterThan(pixel.blue, pixel.green)
        }
    }

    func testSamePointSizeAtDifferentBackingScaleInvalidatesAndRerendersBaseBuffer() {
        let oneX = CodeMinimapLayout(
            bounds: CGRect(x: 0, y: 0, width: 96, height: 400),
            backingScale: 1,
            totalRows: 1_000,
            visibleSourceRows: 20,
            sourceScrollY: 0,
            maximumSourceScrollY: 10_000,
            requestedColumns: 120
        )
        let twoX = CodeMinimapLayout(
            bounds: oneX.bounds,
            backingScale: 2,
            totalRows: oneX.totalRows,
            visibleSourceRows: oneX.visibleSourceRows,
            sourceScrollY: oneX.sourceScrollY,
            maximumSourceScrollY: oneX.maximumSourceScrollY,
            requestedColumns: oneX.columns
        )
        let presentation = CodeMinimapPresentation(
            totalVisualRows: 1_000,
            rows: [],
            requestedRows: oneX.visibleRowWindow
        )
        let renderer = CodeMinimapRenderer()
        renderer.render(presentation: presentation, layout: oneX, theme: BundledThemes.dark)
        XCTAssertTrue(renderer.isCompatible(with: oneX))
        XCTAssertFalse(renderer.isCompatible(with: twoX))

        renderer.render(presentation: presentation, layout: twoX, theme: BundledThemes.dark)
        XCTAssertTrue(renderer.isCompatible(with: twoX))
        XCTAssertEqual(renderer.bufferPixelSize, CGSize(width: 192, height: 800))
    }

    func testScrollRerendersOnlyWhenProportionalRowWindowChanges() {
        let snapshot = SourceSnapshot(text: String(repeating: "x\n", count: 2_000))
        let viewport = CodeViewport(snapshot: snapshot)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 96, height: 400))
        scrollView.documentView = viewport
        let minimap = CodeMinimapView(viewport: viewport, scrollView: scrollView)
        minimap.frame = scrollView.bounds
        let first = CodeMinimapLayout(
            bounds: minimap.bounds,
            backingScale: 2,
            totalRows: viewport.minimapTotalVisualRows,
            visibleSourceRows: 20,
            sourceScrollY: 0,
            maximumSourceScrollY: viewport.frame.height,
            requestedColumns: 120
        )
        let sameWindow = CodeMinimapLayout(
            bounds: first.bounds,
            backingScale: first.backingScale,
            totalRows: first.totalRows,
            visibleSourceRows: first.visibleSourceRows,
            sourceScrollY: 1,
            maximumSourceScrollY: first.maximumSourceScrollY,
            requestedColumns: first.columns
        )
        let nextWindow = CodeMinimapLayout(
            bounds: first.bounds,
            backingScale: first.backingScale,
            totalRows: first.totalRows,
            visibleSourceRows: first.visibleSourceRows,
            sourceScrollY: first.maximumSourceScrollY,
            maximumSourceScrollY: first.maximumSourceScrollY,
            requestedColumns: first.columns
        )

        XCTAssertNotNil(minimap.snapshotImage(layout: first))
        let initialRenderCount = minimap.baseRenderCount
        minimap.viewportDidScroll()
        XCTAssertNotNil(minimap.snapshotImage(layout: sameWindow))
        XCTAssertEqual(minimap.baseRenderCount, initialRenderCount)
        XCTAssertNotNil(minimap.snapshotImage(layout: nextWindow))
        XCTAssertEqual(minimap.baseRenderCount, initialRenderCount + 1)
    }

    func testSelectionOnlyUpdatesDoNotRebuildLargeMarkerCaches() {
        let snapshot = SourceSnapshot(text: String(repeating: "x\n", count: 2_100_000))
        let viewport = CodeViewport(snapshot: snapshot)
        let scrollView = NSScrollView()
        scrollView.documentView = viewport
        let minimap = CodeMinimapView(viewport: viewport, scrollView: scrollView)
        let count = 20_000
        let findMatches = (0..<count).map { ($0 * 2)..<($0 * 2 + 1) }
        let gitChanges = (0..<count).map {
            CodeGutterChange(
                id: "\($0)",
                kind: .modified,
                location: .lines(($0 * 100)..<($0 * 100 + 1)),
                accessibilityLabel: "Modified"
            )
        }
        minimap.updateMarkerCollections(
            findMatches: findMatches,
            diagnostics: [],
            gitChanges: gitChanges
        )
        let rebuilds = minimap.markerCacheRebuildCount

        for offset in 0..<1_000 {
            minimap.updateSelection(offset..<(offset + 1))
        }

        XCTAssertEqual(minimap.markerCacheRebuildCount, rebuilds)
        XCTAssertEqual(minimap.currentMarkers.findMatches.count, count)
        XCTAssertEqual(minimap.currentMarkers.gitChanges.count, count)
    }

    func testZeroWidthDiagnosticAtColumnZeroAndEOFNormalizesToVisibleBytes() {
        let snapshot = SourceSnapshot(text: "abc\nxyz")
        let viewport = CodeViewport(snapshot: snapshot)
        let scrollView = NSScrollView()
        scrollView.documentView = viewport
        let minimap = CodeMinimapView(viewport: viewport, scrollView: scrollView)
        minimap.updateMarkerCollections(
            findMatches: [],
            diagnostics: [
                CodeMinimapDiagnosticMarker(utf8Range: 0..<0, severity: .error),
                CodeMinimapDiagnosticMarker(
                    utf8Range: snapshot.utf8Count..<snapshot.utf8Count,
                    severity: .error
                )
            ],
            gitChanges: []
        )

        XCTAssertEqual(
            minimap.cachedDiagnosticRanges(for: .error),
            [0..<1, (snapshot.utf8Count - 1)..<snapshot.utf8Count]
        )
        XCTAssertEqual(
            viewport.minimapVisualRows(
                forUTF8Ranges: minimap.cachedDiagnosticRanges(for: .error),
                limitedTo: 0..<viewport.minimapTotalVisualRows
            ),
            [0, 1]
        )
    }

    func testTenMegabyteSelectionFindAndGitOverlaysVisitOnlyVisibleWindowRows() throws {
        let source = String(repeating: "x\n", count: 5 * 1_024 * 1_024)
        let snapshot = SourceSnapshot(text: source)
        let viewport = CodeViewport(snapshot: snapshot)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 96, height: 600))
        scrollView.documentView = viewport
        let minimap = CodeMinimapView(viewport: viewport, scrollView: scrollView)
        minimap.frame = scrollView.bounds
        let layout = CodeMinimapLayout(
            bounds: minimap.bounds,
            backingScale: 2,
            totalRows: viewport.minimapTotalVisualRows,
            visibleSourceRows: 30,
            sourceScrollY: viewport.frame.height / 2,
            maximumSourceScrollY: viewport.frame.height,
            requestedColumns: 120
        )
        let markerCount = 20_000
        let findMatches = (0..<markerCount).map { index in
            let offset = index * 2
            return offset..<(offset + 1)
        }
        let gitChanges = (0..<markerCount).map { index in
            CodeGutterChange(
                id: "change-\(index)",
                kind: .modified,
                location: .lines((index * 100)..<(index * 100 + 1)),
                accessibilityLabel: "Modified"
            )
        }
        minimap.updateMarkers(CodeMinimapMarkers(
            selection: 0..<snapshot.utf8Count,
            findMatches: findMatches,
            gitChanges: gitChanges
        ))
        viewport.resetMinimapMappingVisitCount()

        XCTAssertNotNil(minimap.snapshotImage(layout: layout))
        XCTAssertLessThanOrEqual(
            viewport.minimapMappingVisitCount,
            layout.visibleRowWindow.count * 3
        )
    }

    func testViewportEmitsGranularMinimapInvalidations() throws {
        let snapshot = SourceSnapshot(text: "let value = 1\n", version: 9)
        let viewport = CodeViewport(snapshot: snapshot, syntaxLanguage: .swift)
        var invalidations: [CodeMinimapInvalidation] = []
        viewport.onMinimapInvalidation = { invalidations.append($0) }

        try viewport.selectUTF8Range(0..<3)
        viewport.applyLexicalCaptures(
            [SyntaxCapture(name: "keyword", utf8Range: 0..<3)],
            snapshotVersion: 9,
            layerVersion: 1
        )
        viewport.wordWrapEnabled = true
        viewport.theme = BundledThemes.light
        XCTAssertTrue(viewport.applyGutterChanges(
            [
                CodeGutterChange(
                    id: "added",
                    kind: .added,
                    location: .lines(0..<1),
                    accessibilityLabel: "Added"
                )
            ],
            snapshotVersion: 9,
            layerVersion: 1
        ))

        XCTAssertTrue(invalidations.contains(.selection))
        XCTAssertTrue(invalidations.contains(.tokens))
        XCTAssertTrue(invalidations.contains(.layout))
        XCTAssertTrue(invalidations.contains(.markers))
        XCTAssertTrue(invalidations.contains(.appearance))
    }
}
