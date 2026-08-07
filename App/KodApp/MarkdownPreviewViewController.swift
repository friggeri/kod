import AppKit
import DiagnosticsCore
import FontCore
import PreviewCore
import ThemeCore

/// The built-in Markdown preview: a native `NSTextView`-based rendered
/// view (SPEC 10.1: "Prefer a native attributed/document model"; Kod
/// never uses WebKit for this — see `MarkdownRenderer`'s doc comment).
/// Renders `MarkdownRenderDocument` into an `NSAttributedString`, shows
/// link destinations, requires confirmation before opening a non-local
/// link from an untrusted workspace, and never loads a remote image
/// unless the user explicitly opts in for *this* document via
/// `remoteImagesButton`.
@MainActor
final class MarkdownPreviewViewController: NSViewController {
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let remoteImagesButton = NSButton(
        title: Localized.string(
            "Load Remote Images (\(NetworkAttribution.remoteMarkdownResource.userFacingDescription))",
            comment: "Button title inviting the user to opt into loading remote images for this Markdown document"
        ),
        target: nil,
        action: nil
    )
    private let diagnosticsLabel = NSTextField(wrappingLabelWithString: "")

    private(set) var renderDocument: MarkdownRenderDocument
    private(set) var resourcePolicy: MarkdownResourcePolicy
    private let theme: KodTheme
    private let fontSettings: FontSettings
    /// Injected so tests can substitute a confirmation outcome without a
    /// real alert sheet; production uses a real `NSAlert`.
    var confirmBeforeOpening: @MainActor (URL) -> Bool
    var openLocalRelativePath: ((String) -> Void)?
    private(set) var lastOpenedURL: URL?
    private(set) var lastConfirmationPrompted: URL?

    /// Set of remote image destinations actually referenced by the
    /// current document — used to enable/disable `remoteImagesButton`
    /// without guessing.
    private(set) var remoteImageDestinations: [MarkdownDestination] = []

    init(
        renderDocument: MarkdownRenderDocument,
        resourcePolicy: MarkdownResourcePolicy,
        theme: KodTheme,
        fontSettings: FontSettings,
        confirmBeforeOpening: @escaping @MainActor (URL) -> Bool = { _ in false }
    ) {
        self.renderDocument = renderDocument
        self.resourcePolicy = resourcePolicy
        self.theme = theme
        self.fontSettings = fontSettings
        self.confirmBeforeOpening = confirmBeforeOpening
        super.init(nibName: nil, bundle: nil)
        self.remoteImageDestinations = Self.collectRemoteImageDestinations(renderDocument, policy: resourcePolicy)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let container = NSView()

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = theme.editor.background.nsColor
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        remoteImagesButton.target = self
        remoteImagesButton.action = #selector(handleLoadRemoteImages)
        remoteImagesButton.isHidden = remoteImageDestinations.isEmpty
        remoteImagesButton.translatesAutoresizingMaskIntoConstraints = false
        // SPEC 13.3: name the actual purpose of this opt-in network
        // access explicitly, rather than a generic "Allow network
        // access?" — this is the one place in the app layer where a
        // user opts a document into an outbound fetch.
        remoteImagesButton.toolTip = NetworkAttribution.remoteMarkdownResource.userFacingDescription
        remoteImagesButton.setAccessibilityLabel(
            Localized.string(
                "Load remote images for this document. \(NetworkAttribution.remoteMarkdownResource.userFacingDescription)",
                comment: "Accessibility label for the load-remote-images button, explaining the opt-in network access"
            )
        )

        diagnosticsLabel.textColor = .secondaryLabelColor
        diagnosticsLabel.font = .systemFont(ofSize: 10)
        diagnosticsLabel.isHidden = renderDocument.sanitizerDiagnostics.isEmpty
        diagnosticsLabel.stringValue = renderDocument.sanitizerDiagnostics.isEmpty
            ? ""
            : Localized.string(
                "\(renderDocument.sanitizerDiagnostics.count) unsafe construct(s) removed while rendering this document.",
                comment: "Status text reporting how many unsafe Markdown constructs were sanitized out of the rendered document"
            )
        diagnosticsLabel.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsLabel.setAccessibilityLabel(Localized.string("Sanitizer diagnostics", comment: "Accessibility label for the Markdown sanitizer diagnostics text"))

        container.addSubview(remoteImagesButton)
        container.addSubview(diagnosticsLabel)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            remoteImagesButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            remoteImagesButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            diagnosticsLabel.centerYAnchor.constraint(equalTo: remoteImagesButton.centerYAnchor),
            diagnosticsLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            diagnosticsLabel.trailingAnchor.constraint(lessThanOrEqualTo: remoteImagesButton.leadingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: remoteImagesButton.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        view = container
        applyAttributedText()
    }

    /// Re-renders after `resourcePolicy` changes (e.g. remote images were
    /// just explicitly enabled) or a new render document arrives.
    func update(renderDocument: MarkdownRenderDocument, resourcePolicy: MarkdownResourcePolicy) {
        self.renderDocument = renderDocument
        self.resourcePolicy = resourcePolicy
        self.remoteImageDestinations = Self.collectRemoteImageDestinations(renderDocument, policy: resourcePolicy)
        remoteImagesButton.isHidden = remoteImageDestinations.isEmpty
        applyAttributedText()
    }

    @objc
    private func handleLoadRemoteImages(_ sender: Any?) {
        resourcePolicy.remoteImagesEnabledForThisDocument = true
        remoteImagesButton.isHidden = true
        applyAttributedText()
    }

    private static func collectRemoteImageDestinations(
        _ document: MarkdownRenderDocument,
        policy: MarkdownResourcePolicy
    ) -> [MarkdownDestination] {
        var destinations: [MarkdownDestination] = []
        func collectFromRuns(_ runs: [MarkdownRenderRun]) {
            for run in runs where run.isImage {
                guard let destination = run.link, !policy.shouldLoadRemoteImage(destination) else {
                    continue
                }
                destinations.append(destination)
            }
        }
        func walk(_ blocks: [MarkdownRenderBlock]) {
            for block in blocks {
                switch block {
                case .heading(_, let runs), .paragraph(let runs):
                    collectFromRuns(runs)
                case .image(let destination, _, _):
                    if !policy.shouldLoadRemoteImage(destination) {
                        destinations.append(destination)
                    }
                case .blockquote(let inner):
                    walk(inner)
                case .list(_, _, let items):
                    walk(items)
                case .listItem(_, let inner):
                    walk(inner)
                case .table(_, let header, let rows):
                    header.forEach(collectFromRuns)
                    for row in rows {
                        row.forEach(collectFromRuns)
                    }
                default:
                    break
                }
            }
        }
        walk(document.blocks)
        return destinations
    }

    private func applyAttributedText() {
        let result = NSMutableAttributedString()
        let baseFont = NSFont(name: fontSettings.familyName, size: CGFloat(fontSettings.pointSize)) ?? .monospacedSystemFont(ofSize: CGFloat(fontSettings.pointSize), weight: .regular)

        func append(_ runs: [MarkdownRenderRun]) {
            for run in runs {
                if run.isSoftBreak || run.isHardBreak {
                    result.append(NSAttributedString(string: "\n"))
                    continue
                }
                if run.isImage, let destination = run.link {
                    if resourcePolicy.shouldLoadRemoteImage(destination) {
                        result.append(NSAttributedString(string: "[image: \(run.text)]", attributes: [.font: baseFont, .foregroundColor: NSColor.secondaryLabelColor]))
                    } else {
                        result.append(NSAttributedString(
                            string: "[remote image blocked: \(run.text) (\(destination.rawValue))]",
                            attributes: [.font: baseFont, .foregroundColor: NSColor.systemOrange]
                        ))
                    }
                    continue
                }
                var traits: NSFontDescriptor.SymbolicTraits = []
                if run.isBold { traits.insert(.bold) }
                if run.isItalic { traits.insert(.italic) }
                var font = baseFont
                if !traits.isEmpty, let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits) as NSFontDescriptor? {
                    font = NSFont(descriptor: descriptor, size: baseFont.pointSize) ?? baseFont
                }
                if run.isCode {
                    font = .monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
                }
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: theme.editor.foreground.nsColor
                ]
                if run.isStrikethrough {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                if let link = run.link {
                    attributes[.foregroundColor] = NSColor.linkColor
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.link] = link.rawValue
                    attributes[.toolTip] = link.rawValue
                }
                result.append(NSAttributedString(string: run.text, attributes: attributes))
            }
        }

        func renderBlock(_ block: MarkdownRenderBlock) {
            switch block {
            case .heading(let level, let runs):
                let scale = max(2.2 - Double(level) * 0.2, 1.0)
                let headingFont = NSFont.boldSystemFont(ofSize: baseFont.pointSize * CGFloat(scale))
                let start = result.length
                append(runs)
                result.addAttribute(.font, value: headingFont, range: NSRange(location: start, length: result.length - start))
                result.append(NSAttributedString(string: "\n\n"))
            case .paragraph(let runs):
                append(runs)
                result.append(NSAttributedString(string: "\n\n"))
            case .blockquote(let inner):
                for child in inner {
                    renderBlock(child)
                }
            case .list(_, _, let items):
                for item in items {
                    renderBlock(item)
                }
            case .listItem(let checked, let blocks):
                let prefix: String
                if let checked {
                    prefix = checked ? "\u{2611} " : "\u{2610} "
                } else {
                    prefix = "\u{2022} "
                }
                result.append(NSAttributedString(string: prefix, attributes: [.font: baseFont]))
                for child in blocks {
                    renderBlock(child)
                }
            case .codeBlock(_, let sourceText, let highlightedRuns):
                let codeFont = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
                let start = result.length
                result.append(NSAttributedString(string: sourceText, attributes: [
                    .font: codeFont,
                    .foregroundColor: theme.editor.foreground.nsColor,
                    .backgroundColor: theme.editor.background.nsColor.blended(withFraction: 0.08, of: .black) ?? theme.editor.background.nsColor
                ]))
                for run in highlightedRuns {
                    guard let style = run.style.foreground else { continue }
                    let utf8 = Array(sourceText.utf8)
                    guard run.utf8Range.upperBound <= utf8.count,
                          let rangeStart = String(decoding: utf8[0..<run.utf8Range.lowerBound], as: UTF8.self).utf16.count as Int?,
                          let rangeEnd = String(decoding: utf8[0..<run.utf8Range.upperBound], as: UTF8.self).utf16.count as Int? else {
                        continue
                    }
                    result.addAttribute(.foregroundColor, value: style.nsColor, range: NSRange(location: start + rangeStart, length: rangeEnd - rangeStart))
                }
                result.append(NSAttributedString(string: "\n\n"))
            case .thematicBreak:
                result.append(NSAttributedString(string: "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\n\n", attributes: [.foregroundColor: NSColor.separatorColor]))
            case .table(_, let header, let rows):
                let headerLine = header.map { runs in runs.map(\.text).joined() }.joined(separator: " \u{2502} ")
                result.append(NSAttributedString(string: headerLine + "\n", attributes: [.font: NSFont.boldSystemFont(ofSize: baseFont.pointSize)]))
                for row in rows {
                    let line = row.map { runs in runs.map(\.text).joined() }.joined(separator: " \u{2502} ")
                    result.append(NSAttributedString(string: line + "\n", attributes: [.font: baseFont]))
                }
                result.append(NSAttributedString(string: "\n"))
            case .rawHTML(let text):
                result.append(NSAttributedString(string: text, attributes: [.font: baseFont, .foregroundColor: NSColor.secondaryLabelColor]))
            case .image(let destination, _, let altText):
                if resourcePolicy.shouldLoadRemoteImage(destination) {
                    result.append(NSAttributedString(string: "[image: \(altText)]\n", attributes: [.font: baseFont]))
                } else {
                    result.append(NSAttributedString(string: "[remote image blocked: \(altText) (\(destination.rawValue))]\n", attributes: [.font: baseFont, .foregroundColor: NSColor.systemOrange]))
                }
            }
        }

        for block in renderDocument.blocks {
            renderBlock(block)
        }

        textView.textStorage?.setAttributedString(result)
    }
}

extension MarkdownPreviewViewController {
    // MARK: - Test-facing state

    var remoteImagesButtonAccessibilityLabel: String? { remoteImagesButton.accessibilityLabel() }
    var diagnosticsAccessibilityLabel: String? { diagnosticsLabel.accessibilityLabel() }
}

extension MarkdownPreviewViewController: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let rawValue = link as? String else {
            return false
        }
        let destination = MarkdownDestination(rawValue: rawValue)
        guard let url = URL(string: rawValue) else {
            return false
        }

        if destination.scheme == .local {
            openLocalRelativePath?(rawValue)
            lastOpenedURL = url
            return true
        }

        if resourcePolicy.requiresConfirmationToOpen(destination) {
            lastConfirmationPrompted = url
            guard confirmBeforeOpening(url) else {
                return true
            }
        }
        lastOpenedURL = url
        NSWorkspace.shared.open(url)
        return true
    }
}
