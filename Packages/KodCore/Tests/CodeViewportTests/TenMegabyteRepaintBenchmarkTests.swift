import AppKit
import SourceModel
import XCTest
@testable import CodeViewport

/// Headless repaint benchmark for a 10 MB file, exercising the same
/// virtualized Core Text drawing path the app uses, rendered into an
/// off-screen bitmap context so no window is ever ordered front and no UI
/// automation is involved (SPEC 12.2: "Open 10 MB UTF-8 source to first
/// plain-text viewport <= 250 ms"; this measures the steady-state
/// scroll-repaint cost of a full visible page, not the one-time open).
///
/// The viewport must be embedded in a real (if never-shown) window and
/// scroll view before drawing: an `NSView` with no superview reports
/// `visibleRect` as `NSRect.infinite`, which would otherwise crash the
/// viewport's visible-row math — the same hosting `CodeDocumentViewControllerTests`
/// already uses for exactly this reason.
@MainActor
final class TenMegabyteRepaintBenchmarkTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment[
            "KOD_RUN_LARGE_FILE_BENCHMARKS"
        ] == "1" else {
            throw XCTSkip(
                "Set KOD_RUN_LARGE_FILE_BENCHMARKS=1 to run 10 MB benchmarks."
            )
        }
    }

    private func hostedViewport(snapshot: SourceSnapshot, size: NSSize) -> CodeViewport {
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

    private func offscreenContext(size: NSSize) throws -> NSGraphicsContext {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw XCTSkip("failed to create offscreen bitmap context")
        }
        return context
    }

    private func tenMegabyteSource() -> String {
        let line = "let value = 42 // a representative line of source text\n"
        let repeats = (10 * 1_024 * 1_024) / line.utf8.count
        return String(repeating: line, count: repeats)
    }

    func testFirstPlainTextRepaintOfTenMegabyteFileStaysUnderBudget() throws {
        let snapshot = SourceSnapshot(text: tenMegabyteSource(), url: URL(fileURLWithPath: "/ten-megabytes.txt"))
        XCTAssertNil(snapshot.safetyModeReason)

        let size = NSSize(width: 1_200, height: 800)
        let viewport = hostedViewport(snapshot: snapshot, size: size)
        let context = try offscreenContext(size: size)

        let start = CFAbsoluteTimeGetCurrent()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        viewport.draw(NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertLessThan(elapsed, 0.25, "first visible-page paint of a 10 MB file took \(elapsed)s")
    }

    func testRepeatedRepaintStaysResponsive() throws {
        let snapshot = SourceSnapshot(
            text: tenMegabyteSource(),
            url: URL(fileURLWithPath: "/ten-megabytes.swift")
        )
        let size = NSSize(width: 1_200, height: 800)
        let viewport = hostedViewport(snapshot: snapshot, size: size)
        let context = try offscreenContext(size: size)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<30 {
            viewport.draw(NSRect(origin: .zero, size: size))
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        NSGraphicsContext.restoreGraphicsState()

        // 30 frames at 60 Hz is a 500 ms real-time budget; a generous 3 s
        // ceiling still catches a genuine regression on a debug,
        // non-GPU-accelerated bitmap target without being flaky.
        XCTAssertLessThan(elapsed, 3.0, "30 repeated repaints of the same visible page took \(elapsed)s")
    }

    func testScrolledRepaintStaysResponsive() throws {
        let snapshot = SourceSnapshot(
            text: tenMegabyteSource(),
            url: URL(fileURLWithPath: "/ten-megabytes.swift")
        )
        let size = NSSize(width: 1_200, height: 800)
        let viewport = hostedViewport(snapshot: snapshot, size: size)
        let context = try offscreenContext(size: size)

        viewport.scrollSourceLineToTop(snapshot.lineCount / 2)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let start = CFAbsoluteTimeGetCurrent()
        viewport.draw(NSRect(origin: .zero, size: size))
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        NSGraphicsContext.restoreGraphicsState()

        XCTAssertLessThan(elapsed, 0.25, "mid-document repaint of a 10 MB file took \(elapsed)s")
    }
}
