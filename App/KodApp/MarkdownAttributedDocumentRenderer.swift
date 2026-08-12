import AppKit
import FontCore
import PreviewCore
import ThemeCore

extension NSAttributedString.Key {
    static let kodMarkdownImageState = NSAttributedString.Key("KodMarkdownImageState")
    static let kodMarkdownHeadingLevel = NSAttributedString.Key("KodMarkdownHeadingLevel")
}

enum MarkdownImagePresentationState: String {
    case loaded
    case localResourceUnavailable
    case remoteBlocked
    case remoteLoadFailed
    case remoteLoadingUnavailable
}

/// Converts PreviewCore's safe render model into a native TextKit document.
/// No HTML or CSS is interpreted and this type never performs I/O.
@MainActor
struct MarkdownAttributedDocumentRenderer {
    let document: MarkdownRenderDocument
    let resourcePolicy: MarkdownResourcePolicy
    let theme: KodTheme
    let fontSettings: FontSettings
    let loadedImages: [String: NSImage]
    let failedImageDestinations: Set<String>

    init(
        document: MarkdownRenderDocument,
        resourcePolicy: MarkdownResourcePolicy,
        theme: KodTheme,
        fontSettings: FontSettings,
        loadedImages: [String: NSImage] = [:],
        failedImageDestinations: Set<String> = []
    ) {
        self.document = document
        self.resourcePolicy = resourcePolicy
        self.theme = theme
        self.fontSettings = fontSettings
        self.loadedImages = loadedImages
        self.failedImageDestinations = failedImageDestinations
    }

    private static let headingScaleFactors: [CGFloat] = [2, 1.5, 1.25, 1, 0.875, 0.85]

    private var prosePointSize: CGFloat { CGFloat(fontSettings.pointSize) }
    private var proseFont: NSFont { .systemFont(ofSize: prosePointSize) }
    private var codeFont: NSFont {
        NSFont(name: fontSettings.familyName, size: CGFloat(fontSettings.pointSize))
            ?? .monospacedSystemFont(ofSize: CGFloat(fontSettings.pointSize), weight: .regular)
    }
    private var foregroundColor: NSColor { theme.editor.foreground.nsColor }
    private var mutedColor: NSColor { .secondaryLabelColor }
    private var borderColor: NSColor { .separatorColor }
    private var codeBackgroundColor: NSColor {
        theme.editor.background.nsColor.blended(withFraction: 0.08, of: foregroundColor)
            ?? .controlBackgroundColor
    }

    func render() -> NSAttributedString {
        let output = NSMutableAttributedString()
        render(blocks: document.blocks, into: output, context: RenderContext())
        while output.string.hasSuffix("\n\n") {
            output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
        }
        return output
    }

    private struct RenderContext {
        var listDepth = 0
        var quoteBlocks: [NSTextBlock] = []
        var pendingListPrefix: String?
        var compactParagraphs = false
    }

    private func render(
        blocks: [MarkdownRenderBlock],
        into output: NSMutableAttributedString,
        context: RenderContext
    ) {
        for block in blocks {
            render(block: block, into: output, context: context)
        }
    }

    private func render(
        block: MarkdownRenderBlock,
        into output: NSMutableAttributedString,
        context: RenderContext
    ) {
        switch block {
        case .heading(let level, let runs):
            let scale = Self.headingScaleFactors[min(max(level, 1), 6) - 1]
            let size = prosePointSize * scale
            let weight: NSFont.Weight = level <= 2 ? .semibold : .medium
            let headingFont = NSFont.systemFont(ofSize: size, weight: weight)
            let separatorBlock = level <= 2 ? makeHeadingBlock() : nil
            appendParagraph(
                runs: runs,
                into: output,
                context: context,
                font: headingFont,
                before: level == 1 ? 4 : 12,
                after: level <= 2 ? 12 : 7,
                extraBlock: separatorBlock,
                headingLevel: level
            )

        case .paragraph(let runs):
            appendParagraph(
                runs: runs,
                into: output,
                context: context,
                font: proseFont,
                before: 0,
                after: context.compactParagraphs ? 2 : 11
            )

        case .blockquote(let blocks):
            let quoteBlock = makeQuoteBlock()
            var quoteContext = context
            quoteContext.quoteBlocks.append(quoteBlock)
            render(blocks: blocks, into: output, context: quoteContext)

        case .list(let kind, let isTight, let items):
            renderList(kind: kind, isTight: isTight, items: items, into: output, context: context)

        case .listItem(_, let blocks):
            render(blocks: blocks, into: output, context: context)

        case .codeBlock(_, let sourceText, let highlightedRuns):
            appendCodeBlock(
                sourceText: sourceText,
                highlightedRuns: highlightedRuns,
                into: output,
                context: context
            )

        case .thematicBreak:
            let line = NSMutableAttributedString(string: "\u{200B}\n")
            let style = paragraphStyle(before: 10, after: 14, blocks: context.quoteBlocks + [makeRuleBlock()])
            line.addAttributes([
                .font: proseFont,
                .paragraphStyle: style,
                .foregroundColor: foregroundColor
            ], range: NSRange(location: 0, length: line.length))
            output.append(line)

        case .table(let alignments, let header, let rows):
            appendTable(alignments: alignments, header: header, rows: rows, into: output, context: context)

        case .rawHTML(let text):
            let content = NSMutableAttributedString(
                string: text.replacingOccurrences(of: "\n", with: "\u{2028}"),
                attributes: [
                    .font: codeFont,
                    .foregroundColor: mutedColor
                ]
            )
            appendParagraph(content, into: output, context: context, before: 0, after: 11)

        case .image(let destination, _, let altText):
            let run = MarkdownRenderRun(text: altText, isImage: true, link: destination)
            appendParagraph(
                runs: [run],
                into: output,
                context: context,
                font: proseFont,
                before: 0,
                after: 11
            )
        }
    }

    private func renderList(
        kind: MarkdownListKind,
        isTight: Bool,
        items: [MarkdownRenderBlock],
        into output: NSMutableAttributedString,
        context: RenderContext
    ) {
        for (index, item) in items.enumerated() {
            guard case .listItem(let checked, let blocks) = item else { continue }
            let marker: String
            if let checked {
                marker = checked ? "\u{2611}" : "\u{2610}"
            } else {
                switch kind {
                case .unordered:
                    marker = context.listDepth.isMultiple(of: 2) ? "\u{2022}" : "\u{25E6}"
                case .ordered(let start, let delimiter):
                    marker = "\(start + index)\(delimiter)"
                }
            }
            var itemContext = context
            itemContext.listDepth += 1
            itemContext.pendingListPrefix = marker + " "
            itemContext.compactParagraphs = isTight
            for (blockIndex, block) in blocks.enumerated() {
                var blockContext = itemContext
                if blockIndex > 0 {
                    blockContext.pendingListPrefix = nil
                }
                render(block: block, into: output, context: blockContext)
            }
        }
    }

    private func appendParagraph(
        runs: [MarkdownRenderRun],
        into output: NSMutableAttributedString,
        context: RenderContext,
        font: NSFont,
        before: CGFloat,
        after: CGFloat,
        extraBlock: NSTextBlock? = nil,
        headingLevel: Int? = nil
    ) {
        let content = attributedRuns(runs, baseFont: font)
        if let headingLevel, content.length > 0 {
            content.addAttribute(
                .kodMarkdownHeadingLevel,
                value: headingLevel,
                range: NSRange(location: 0, length: content.length)
            )
        }
        appendParagraph(
            content,
            into: output,
            context: context,
            before: before,
            after: after,
            extraBlock: extraBlock
        )
    }

    private func appendParagraph(
        _ content: NSMutableAttributedString,
        into output: NSMutableAttributedString,
        context: RenderContext,
        before: CGFloat,
        after: CGFloat,
        extraBlock: NSTextBlock? = nil
    ) {
        let paragraph = NSMutableAttributedString()
        if let prefix = context.pendingListPrefix {
            paragraph.append(NSAttributedString(
                string: prefix,
                attributes: [.font: proseFont, .foregroundColor: mutedColor]
            ))
        }
        paragraph.append(content)
        paragraph.append(NSAttributedString(string: "\n"))

        var blocks = context.quoteBlocks
        if let extraBlock {
            blocks.append(extraBlock)
        }
        let style = paragraphStyle(before: before, after: after, blocks: blocks)
        if context.listDepth > 0 {
            let indent = CGFloat(context.listDepth) * 22
            style.firstLineHeadIndent = context.pendingListPrefix == nil ? indent : indent - 18
            style.headIndent = indent
            style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        }
        paragraph.addAttribute(
            .paragraphStyle,
            value: style,
            range: NSRange(location: 0, length: paragraph.length)
        )
        output.append(paragraph)
    }

    private func attributedRuns(_ runs: [MarkdownRenderRun], baseFont: NSFont) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        for run in runs {
            if run.isSoftBreak {
                result.append(NSAttributedString(string: " "))
                continue
            }
            if run.isHardBreak {
                result.append(NSAttributedString(string: "\u{2028}"))
                continue
            }
            if run.isImage, let destination = run.link {
                result.append(imagePlaceholder(altText: run.text, destination: destination))
                continue
            }

            var traits: NSFontDescriptor.SymbolicTraits = []
            if run.isBold { traits.insert(.bold) }
            if run.isItalic { traits.insert(.italic) }
            var font = run.isCode ? codeFont : baseFont
            if !traits.isEmpty {
                let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
                font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: foregroundColor
            ]
            if run.isCode {
                attributes[.backgroundColor] = codeBackgroundColor
            }
            if run.isStrikethrough {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.foregroundColor] = NSColor.linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.link] = link.rawValue
                attributes[.toolTip] = run.linkTitle ?? link.rawValue
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }

    private func imagePlaceholder(altText: String, destination: MarkdownDestination) -> NSAttributedString {
        let state: MarkdownImagePresentationState
        let text: String
        let color: NSColor
        if let image = loadedImages[destination.rawValue] {
            let attachment = NSTextAttachment()
            attachment.image = image
            let maximumDimension: CGFloat = 640
            let scale = min(1, maximumDimension / max(image.size.width, image.size.height))
            attachment.bounds = NSRect(
                origin: .zero,
                size: NSSize(width: image.size.width * scale, height: image.size.height * scale)
            )
            let result = NSMutableAttributedString(attachment: attachment)
            result.addAttribute(
                .kodMarkdownImageState,
                value: MarkdownImagePresentationState.loaded.rawValue,
                range: NSRange(location: 0, length: result.length)
            )
            result.append(NSAttributedString(
                string: " Image: \(altText)",
                attributes: [.font: proseFont, .foregroundColor: mutedColor, .toolTip: destination.rawValue]
            ))
            return result
        } else if destination.scheme == .local {
            state = .localResourceUnavailable
            text = "[Image unavailable: \(altText)]"
            color = mutedColor
        } else if failedImageDestinations.contains(destination.rawValue) {
            state = .remoteLoadFailed
            text = "[Remote image failed safety checks: \(altText)]"
            color = .systemRed
        } else if resourcePolicy.shouldLoadRemoteImage(destination) {
            state = .remoteLoadingUnavailable
            text = "[Remote image loading: \(altText)]"
            color = mutedColor
        } else {
            state = .remoteBlocked
            text = "[Remote image blocked: \(altText)]"
            color = .systemOrange
        }
        return NSAttributedString(string: text, attributes: [
            .font: proseFont,
            .foregroundColor: color,
            .toolTip: destination.rawValue,
            .kodMarkdownImageState: state.rawValue
        ])
    }

    private func appendCodeBlock(
        sourceText: String,
        highlightedRuns: [MarkdownCodeRun],
        into output: NSMutableAttributedString,
        context: RenderContext
    ) {
        let content = NSMutableAttributedString(string: sourceText, attributes: [
            .font: codeFont,
            .foregroundColor: foregroundColor
        ])
        let utf8 = Array(sourceText.utf8)
        for run in highlightedRuns {
            guard let color = run.style.foreground,
                  run.utf8Range.lowerBound >= 0,
                  run.utf8Range.upperBound <= utf8.count else { continue }
            let lower = String(decoding: utf8[0..<run.utf8Range.lowerBound], as: UTF8.self).utf16.count
            let upper = String(decoding: utf8[0..<run.utf8Range.upperBound], as: UTF8.self).utf16.count
            content.addAttribute(
                .foregroundColor,
                value: color.nsColor,
                range: NSRange(location: lower, length: upper - lower)
            )
        }
        content.mutableString.replaceOccurrences(
            of: "\n",
            with: "\u{2028}",
            range: NSRange(location: 0, length: content.length)
        )
        appendParagraph(
            content,
            into: output,
            context: context,
            before: 6,
            after: 13,
            extraBlock: makeCodeBlock()
        )
    }

    private func appendTable(
        alignments: [MarkdownTableAlignment],
        header: [[MarkdownRenderRun]],
        rows: [[[MarkdownRenderRun]]],
        into output: NSMutableAttributedString,
        context: RenderContext
    ) {
        let allRows = [header] + rows
        let columnCount = max(alignments.count, allRows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return }

        let table = NSTextTable()
        table.numberOfColumns = columnCount
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)

        for rowIndex in allRows.indices {
            for columnIndex in 0..<columnCount {
                let runs = columnIndex < allRows[rowIndex].count ? allRows[rowIndex][columnIndex] : []
                let font = rowIndex == 0
                    ? NSFont.systemFont(ofSize: prosePointSize, weight: .semibold)
                    : proseFont
                let cell = attributedRuns(runs, baseFont: font)
                cell.append(NSAttributedString(string: "\n"))

                let tableBlock = NSTextTableBlock(
                    table: table,
                    startingRow: rowIndex,
                    rowSpan: 1,
                    startingColumn: columnIndex,
                    columnSpan: 1
                )
                tableBlock.setWidth(1, type: .absoluteValueType, for: .border)
                tableBlock.setWidth(7, type: .absoluteValueType, for: .padding)
                tableBlock.setBorderColor(borderColor)
                if rowIndex == 0 {
                    tableBlock.backgroundColor = codeBackgroundColor
                }
                let style = paragraphStyle(
                    before: rowIndex == 0 ? 6 : 0,
                    after: rowIndex == allRows.count - 1 ? 12 : 0,
                    blocks: context.quoteBlocks + [tableBlock]
                )
                if columnIndex < alignments.count {
                    switch alignments[columnIndex] {
                    case .center: style.alignment = .center
                    case .right: style.alignment = .right
                    case .left, .none: style.alignment = .left
                    }
                }
                cell.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: cell.length))
                output.append(cell)
            }
        }
    }

    private func paragraphStyle(
        before: CGFloat,
        after: CGFloat,
        blocks: [NSTextBlock]
    ) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.lineHeightMultiple = 1.22
        style.lineBreakMode = .byWordWrapping
        style.textBlocks = blocks
        return style
    }

    private func makeCodeBlock() -> NSTextBlock {
        let block = NSTextBlock()
        block.backgroundColor = codeBackgroundColor
        block.setWidth(10, type: .absoluteValueType, for: .padding)
        block.setWidth(1, type: .absoluteValueType, for: .border)
        block.setBorderColor(borderColor)
        block.setContentWidth(100, type: .percentageValueType)
        return block
    }

    private func makeQuoteBlock() -> NSTextBlock {
        let block = NSTextBlock()
        block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
        block.setBorderColor(.tertiaryLabelColor, for: .minX)
        block.setContentWidth(100, type: .percentageValueType)
        return block
    }

    private func makeHeadingBlock() -> NSTextBlock {
        let block = NSTextBlock()
        block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
        block.setBorderColor(borderColor, for: .maxY)
        block.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxY)
        return block
    }

    private func makeRuleBlock() -> NSTextBlock {
        let block = NSTextBlock()
        block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
        block.setBorderColor(borderColor, for: .maxY)
        return block
    }
}
