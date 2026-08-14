import AppKit
import XCTest
@testable import KodUIComponents

/// Headless coverage for the shared read-only text presentation. These
/// tests build views only — no window is created, made key, or ordered
/// front, and no UI automation is involved.
@MainActor
final class ReadOnlyScrollingTextViewTests: XCTestCase {
    func testConfigurationIsReadOnlyButSelectable() {
        let scrollView = makeScrollView()
        let textView = NSTextView()

        configureReadOnlyScrollingTextView(textView, in: scrollView, wrapsLines: true)

        XCTAssertFalse(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertIdentical(scrollView.documentView, textView)
        XCTAssertTrue(textView.isVerticallyResizable)
        XCTAssertEqual(textView.textContainerInset, NSSize(width: 10, height: 8))
        XCTAssertEqual(
            textView.maxSize,
            NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        )
    }

    func testWrappingConfigurationTracksTheScrollViewWidth() throws {
        let scrollView = makeScrollView()
        let textView = NSTextView()
        configureReadOnlyScrollingTextView(textView, in: scrollView, wrapsLines: true)

        let container = try XCTUnwrap(textView.textContainer)
        XCTAssertFalse(textView.isHorizontallyResizable)
        XCTAssertTrue(container.widthTracksTextView)
        XCTAssertEqual(
            container.size.width,
            textView.bounds.width - (2 * textView.textContainerInset.width)
        )
        XCTAssertFalse(scrollView.hasHorizontalScroller)
    }

    func testNonWrappingConfigurationScrollsHorizontally() throws {
        let scrollView = makeScrollView()
        let textView = NSTextView()

        configureReadOnlyScrollingTextView(textView, in: scrollView, wrapsLines: false)

        let container = try XCTUnwrap(textView.textContainer)
        XCTAssertTrue(textView.isHorizontallyResizable)
        XCTAssertFalse(container.widthTracksTextView)
        XCTAssertEqual(container.size.width, CGFloat.greatestFiniteMagnitude)
        XCTAssertTrue(scrollView.hasHorizontalScroller)
    }

    func testConfigurationToleratesAZeroSizedScrollView() {
        let scrollView = NSScrollView()
        let textView = NSTextView()

        configureReadOnlyScrollingTextView(textView, in: scrollView, wrapsLines: true)

        XCTAssertGreaterThanOrEqual(textView.frame.width, 0)
        XCTAssertGreaterThanOrEqual(textView.frame.height, 0)
    }

    func testBuilderProducesAConfiguredReadOnlySurface() {
        let surface = makeReadOnlyScrollingTextView(wrapsLines: true)

        XCTAssertIdentical(surface.scrollView.documentView, surface.textView)
        XCTAssertFalse(surface.textView.isEditable)
        XCTAssertTrue(surface.textView.isSelectable)
        XCTAssertTrue(surface.scrollView.hasVerticalScroller)
        XCTAssertFalse(surface.scrollView.translatesAutoresizingMaskIntoConstraints)
    }

    func testBuilderAnnouncesTheLocalizedReadOnlyRoleDescription() {
        let surface = makeReadOnlyScrollingTextView(wrapsLines: false)

        XCTAssertEqual(
            surface.textView.accessibilityRoleDescription(),
            KodUIStringCatalog.components.string(
                .readOnlyTextAccessibilityRoleDescription,
                comment: "Role description announced for a read-only text area"
            )
        )
    }

    private func makeScrollView() -> NSScrollView {
        NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
    }
}
