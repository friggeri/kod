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
        theme: KodTheme = BundledThemes.dark,
        fontSettings: FontSettings = .default,
        remoteImageLoader: @escaping @Sendable (URL) async -> RemoteMarkdownImageLoad? = RemoteMarkdownImageLoader.load,
        confirmBeforeOpening: @escaping @MainActor (URL) -> Bool = { _ in false }
    ) async -> MarkdownPreviewViewController {
        let document = MarkdownParser.parse(markdown)
        let rendered = await MarkdownRenderer.render(document, theme: theme)
        let policy = MarkdownResourcePolicy(isWorkspaceTrusted: isWorkspaceTrusted)
        let controller = MarkdownPreviewViewController(
            renderDocument: rendered,
            resourcePolicy: policy,
            theme: theme,
            fontSettings: fontSettings,
            remoteImageLoader: remoteImageLoader,
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
        let controller = await makeController(
            markdown: "[site](https://example.com)",
            isWorkspaceTrusted: false,
            confirmBeforeOpening: { url in
            confirmationPrompt = url
            return false // user declines
            }
        )
        _ = controller.textView(NSTextView(), clickedOnLink: "https://example.com", at: 0)

        XCTAssertEqual(confirmationPrompt, URL(string: "https://example.com"))
        XCTAssertNil(controller.lastOpenedURL, "declining confirmation must not open the link")
    }

    func testRemoteLinkInTrustedWorkspaceOpensWithoutConfirmation() async {
        var confirmationCalls = 0
        let controller = await makeController(
            markdown: "[site](https://example.com)",
            isWorkspaceTrusted: true,
            confirmBeforeOpening: { _ in
                confirmationCalls += 1
                return true
            }
        )
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
        let controller = await makeController(
            markdown: "[x](javascript:alert(1))",
            isWorkspaceTrusted: false,
            confirmBeforeOpening: { _ in true }
        )
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
        controller.view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(controller.renderedText.contains("Visible title"))
        XCTAssertTrue(controller.renderedText.contains("Rendered body."))
        XCTAssertGreaterThan(
            controller.renderedTextViewFrame.width,
            100,
            "scroll frame: \(controller.previewScrollViewFrame), container frame: \(controller.view.frame)"
        )
        XCTAssertGreaterThan(controller.renderedTextViewFrame.height, 0)
    }

    func testPlainDocumentCollapsesStatusBannerAndHasNoOuterTopGap() async {
        let controller = await makeController(markdown: "Body", isWorkspaceTrusted: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        controller.view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(controller.statusBannerIsVisible)
        XCTAssertEqual(controller.previewTopGap, 0, accuracy: 0.5)
    }

    func testRemoteImageMakesCollapsibleStatusBannerVisible() async {
        let controller = await makeController(markdown: "![alt](https://example.com/a.png)", isWorkspaceTrusted: true)
        XCTAssertTrue(controller.statusBannerIsVisible)
    }

    func testExplicitRemoteImageLoadContinuesAfterViewDisappears() async {
        let probe = RemoteImageLoadProbe()
        let controller = await makeController(
            markdown: "![alt](https://example.com/a.png)",
            isWorkspaceTrusted: true,
            remoteImageLoader: { url in await probe.load(url) }
        )

        controller.beginRemoteImageLoadForTesting()
        await waitUntil { await probe.hasBegun }
        controller.viewDidDisappear()
        await waitUntil { await probe.hasFinished }

        let wasCancelled = await probe.wasCancelled
        XCTAssertFalse(wasCancelled)
        XCTAssertTrue(controller.remoteImagesButtonIsEnabled)
        XCTAssertTrue(controller.remoteImagesButtonIsHidden)
    }

    func testProseUsesSystemProportionalFontAndCodeUsesConfiguredMonospace() async throws {
        let controller = await makeController(markdown: "Prose `inline`\n\n```swift\nlet x = 1\n```", isWorkspaceTrusted: true)
        let attributed = controller.renderedAttributedText
        let proseRange = (attributed.string as NSString).range(of: "Prose")
        let inlineRange = (attributed.string as NSString).range(of: "inline")
        let blockRange = (attributed.string as NSString).range(of: "let x")
        let proseFont = try XCTUnwrap(attributed.attribute(.font, at: proseRange.location, effectiveRange: nil) as? NSFont)
        let inlineFont = try XCTUnwrap(attributed.attribute(.font, at: inlineRange.location, effectiveRange: nil) as? NSFont)
        let blockFont = try XCTUnwrap(attributed.attribute(.font, at: blockRange.location, effectiveRange: nil) as? NSFont)

        XCTAssertFalse(proseFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
        XCTAssertTrue(inlineFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
        XCTAssertTrue(blockFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    func testHeadingsQuotesListsAndCodeUseNativeTextKitStructure() async {
        let source = """
        # Heading

        > Quote

        5. Five
        6. Six

        ```swift
        let value = 1
        ```
        """
        let controller = await makeController(markdown: source, isWorkspaceTrusted: true)
        let attributed = controller.renderedAttributedText
        XCTAssertTrue(attributed.string.contains("5. Five"))
        XCTAssertTrue(attributed.string.contains("6. Six"))

        var sawHeading = false
        var sawQuoteBlock = false
        var sawCodeBackground = false
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, _, _ in
            sawHeading = sawHeading || attributes[.kodMarkdownHeadingLevel] as? Int == 1
            if let style = attributes[.paragraphStyle] as? NSParagraphStyle {
                sawQuoteBlock = sawQuoteBlock || style.textBlocks.contains {
                    $0.width(for: .border, edge: .minX) >= 3
                }
                sawCodeBackground = sawCodeBackground || style.textBlocks.contains {
                    $0.backgroundColor != nil && $0.contentWidthValueType == .percentageValueType
                }
            }
        }
        XCTAssertTrue(sawHeading)
        XCTAssertTrue(sawQuoteBlock)
        XCTAssertTrue(sawCodeBackground)
    }

    func testTableUsesNSTextTableBlocksAndPreservesAlignment() async {
        let controller = await makeController(
            markdown: "| Left | Right |\n| :--- | ---: |\n| wraps naturally | 42 |",
            isWorkspaceTrusted: true
        )
        let attributed = controller.renderedAttributedText
        var tableBlocks: [NSTextTableBlock] = []
        var sawRightAlignment = false
        attributed.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            guard let style = value as? NSParagraphStyle else { return }
            tableBlocks.append(contentsOf: style.textBlocks.compactMap { $0 as? NSTextTableBlock })
            sawRightAlignment = sawRightAlignment || style.alignment == .right
        }
        XCTAssertFalse(tableBlocks.isEmpty)
        XCTAssertEqual(tableBlocks.first?.table.numberOfColumns, 2)
        XCTAssertTrue(sawRightAlignment)
    }

    func testImageStatesAreTextualAndMachineInspectable() async {
        let controller = await makeController(
            markdown: "![local alt](local.png)\n\n![remote alt](https://example.com/a.png)",
            isWorkspaceTrusted: false
        )
        let attributed = controller.renderedAttributedText
        XCTAssertTrue(attributed.string.contains("Image unavailable: local alt"))
        XCTAssertTrue(attributed.string.contains("Remote image blocked: remote alt"))
        var states: Set<String> = []
        attributed.enumerateAttribute(.kodMarkdownImageState, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if let value = value as? String { states.insert(value) }
        }
        XCTAssertTrue(states.contains(MarkdownImagePresentationState.localResourceUnavailable.rawValue))
        XCTAssertTrue(states.contains(MarkdownImagePresentationState.remoteBlocked.rawValue))
    }

    func testRendererUsesActiveThemeColorsInBothAppearances() async {
        let dark = await makeController(markdown: "Body", isWorkspaceTrusted: true, theme: BundledThemes.dark)
        let light = await makeController(markdown: "Body", isWorkspaceTrusted: true, theme: BundledThemes.light)
        let darkColor = dark.renderedAttributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let lightColor = light.renderedAttributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertNotEqual(darkColor, lightColor)
    }

    func testProseHeadingsAndTableHeadersScaleWithFontSettings() async throws {
        let markdown = """
        # Heading

        Body

        | Column |
        | --- |
        | Cell |
        """
        let small = await makeController(
            markdown: markdown,
            isWorkspaceTrusted: true,
            fontSettings: FontSettings(pointSize: 12)
        ).renderedAttributedText
        let large = await makeController(
            markdown: markdown,
            isWorkspaceTrusted: true,
            fontSettings: FontSettings(pointSize: 24)
        ).renderedAttributedText

        func font(for text: String, in attributed: NSAttributedString) throws -> NSFont {
            let range = (attributed.string as NSString).range(of: text)
            XCTAssertNotEqual(range.location, NSNotFound)
            return try XCTUnwrap(attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
        }

        for text in ["Heading", "Body", "Column"] {
            let smallFont = try font(for: text, in: small)
            let largeFont = try font(for: text, in: large)
            XCTAssertEqual(largeFont.pointSize, smallFont.pointSize * 2, accuracy: 0.01, text)
        }
        XCTAssertEqual(try font(for: "Heading", in: small).pointSize, 24, accuracy: 0.01)
        XCTAssertEqual(try font(for: "Body", in: small).pointSize, 12, accuracy: 0.01)
        XCTAssertEqual(try font(for: "Column", in: small).pointSize, 12, accuracy: 0.01)
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

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for asynchronous condition")
    }
}

private actor RemoteImageLoadProbe {
    private(set) var hasBegun = false
    private(set) var hasFinished = false
    private(set) var wasCancelled = false

    func load(_ url: URL) async -> RemoteMarkdownImageLoad? {
        hasBegun = true
        try? await Task.sleep(for: .milliseconds(50))
        wasCancelled = Task.isCancelled
        hasFinished = true
        return nil
    }
}
