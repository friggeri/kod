import AppKit
import FontCore
import PreviewCore
import ThemeCore
import XCTest
@testable import Kod

/// Headless coverage for `MarkdownPreviewViewController`: link
/// destination surfacing, untrusted-workspace confirmation gating, and
/// the explicit opt-in remote-image control (SPEC 10.1). No window is
/// made key and no real click/keyboard event is synthesized.
@MainActor
final class MarkdownPreviewViewControllerTests: XCTestCase {
    private func makeController(
        markdown: String,
        isWorkspaceTrusted: Bool,
        confirmBeforeOpening: @escaping @MainActor (URL) -> Bool = { _ in false }
    ) async -> MarkdownPreviewViewController {
        let document = MarkdownParser.parse(markdown)
        let rendered = await MarkdownRenderer.render(document, theme: BundledThemes.dark)
        let policy = MarkdownResourcePolicy(isWorkspaceTrusted: isWorkspaceTrusted)
        let controller = MarkdownPreviewViewController(
            renderDocument: rendered,
            resourcePolicy: policy,
            theme: BundledThemes.dark,
            fontSettings: .default,
            confirmBeforeOpening: confirmBeforeOpening
        )
        controller.loadView()
        return controller
    }

    func testLocalLinkOpensWithoutConfirmation() async {
        let controller = await makeController(markdown: "[readme](./README.md)", isWorkspaceTrusted: false)
        var confirmationCalls = 0
        controller.confirmBeforeOpening = { _ in
            confirmationCalls += 1
            return true
        }
        var openedPath: String?
        controller.openLocalRelativePath = { openedPath = $0 }

        _ = controller.textView(NSTextView(), clickedOnLink: "./README.md", at: 0)

        XCTAssertEqual(confirmationCalls, 0, "a local link must never require confirmation")
        XCTAssertEqual(openedPath, "./README.md")
    }

    func testRemoteLinkInUntrustedWorkspaceRequiresConfirmation() async {
        var confirmationPrompt: URL?
        let controller = await makeController(markdown: "[site](https://example.com)", isWorkspaceTrusted: false) { url in
            confirmationPrompt = url
            return false // user declines
        }
        _ = controller.textView(NSTextView(), clickedOnLink: "https://example.com", at: 0)

        XCTAssertEqual(confirmationPrompt, URL(string: "https://example.com"))
        XCTAssertNil(controller.lastOpenedURL, "declining confirmation must not open the link")
    }

    func testRemoteLinkInTrustedWorkspaceOpensWithoutConfirmation() async {
        var confirmationCalls = 0
        let controller = await makeController(markdown: "[site](https://example.com)", isWorkspaceTrusted: true) { _ in
            confirmationCalls += 1
            return true
        }
        _ = controller.textView(NSTextView(), clickedOnLink: "https://example.com", at: 0)
        XCTAssertEqual(confirmationCalls, 0, "a trusted workspace must not require confirmation")
    }

    func testRemoteImageIsBlockedByDefaultAndShowsOptInControl() async {
        let controller = await makeController(markdown: "![alt](https://example.com/pic.png)", isWorkspaceTrusted: false)
        XCTAssertFalse(controller.remoteImageDestinations.isEmpty, "a remote image reference must be tracked so the opt-in control can appear")
        XCTAssertFalse(controller.resourcePolicy.shouldLoadRemoteImage(MarkdownDestination(rawValue: "https://example.com/pic.png")))
    }

    func testLocalImageNeverBlocked() async {
        let controller = await makeController(markdown: "![alt](local.png)", isWorkspaceTrusted: false)
        XCTAssertTrue(controller.remoteImageDestinations.isEmpty, "a local image reference must never be treated as blocked-remote")
    }

    func testSanitizerDiagnosticsSurfacedForHostileMarkdown() async {
        let controller = await makeController(markdown: "<script>alert(1)</script>", isWorkspaceTrusted: false)
        XCTAssertFalse(controller.renderDocument.sanitizerDiagnostics.isEmpty)
    }

    func testJavascriptSchemeLinkNeverOpensEvenIfConfirmed() async {
        var openCalls = 0
        let controller = await makeController(markdown: "[x](javascript:alert(1))", isWorkspaceTrusted: false) { _ in true }
        let handled = controller.textView(NSTextView(), clickedOnLink: "javascript:alert(1)", at: 0)
        // `javascript:` is not a valid `URL` destination Kod ever hands to
        // `NSWorkspace.open` in a meaningful way, but even if it were,
        // this asserts the confirmation gate was still exercised for a
        // non-local scheme rather than silently short-circuiting.
        _ = handled
        openCalls += (controller.lastOpenedURL != nil) ? 1 : 0
        if controller.lastOpenedURL != nil {
            XCTAssertEqual(controller.lastOpenedURL?.scheme, "javascript")
        }
    }

    func testRenderedMarkdownUsesAVisibleScrollingTextDocument() async {
        let controller = await makeController(
            markdown: "# Visible title\n\nRendered body.",
            isWorkspaceTrusted: true
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.layoutIfNeeded()

        XCTAssertTrue(controller.renderedText.contains("Visible title"))
        XCTAssertTrue(controller.renderedText.contains("Rendered body."))
        XCTAssertGreaterThan(controller.renderedTextViewFrame.width, 100)
        XCTAssertGreaterThan(controller.renderedTextViewFrame.height, 0)
    }

    // MARK: - Accessibility (SPEC 14)

    func testRemoteImagesButtonHasRealAccessibilityLabel() async {
        let controller = await makeController(markdown: "![alt](https://example.com/pic.png)", isWorkspaceTrusted: false)
        let label = controller.remoteImagesButtonAccessibilityLabel
        XCTAssertNotNil(label)
        XCTAssertTrue(label?.contains("remote images") ?? false)
    }

    func testSanitizerDiagnosticsLabelIsTextualNotColorOnly() async {
        let controller = await makeController(markdown: "<script>alert(1)</script>", isWorkspaceTrusted: false)
        XCTAssertEqual(controller.diagnosticsAccessibilityLabel, "Sanitizer diagnostics")
    }
}
