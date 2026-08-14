import AppKit
import FontCore
import KodUIComponents
import PreviewCore
import ThemeCore

extension NSAttributedString.Key {
    static let kodMarkdownImageState = NSAttributedString.Key("KodMarkdownImageState")
    static let kodMarkdownHeadingLevel = NSAttributedString.Key("KodMarkdownHeadingLevel")
    static let kodMarkdownInlineCodeBackground = NSAttributedString.Key("KodMarkdownInlineCodeBackground")
}

final class MarkdownPreviewLayoutManager: NSLayoutManager {
    static func inlineCodeBackgroundRect(
        for rect: NSRect,
        font: NSFont,
        baselineOffset: CGFloat
    ) -> NSRect {
        let baseline = rect.minY + baselineOffset
        let minY = max(rect.minY + 0.5, baseline - font.ascender - 1)
        let maxY = min(rect.maxY - 0.5, baseline - font.descender + 1)
        return NSRect(
            x: rect.minX - 3,
            y: minY,
            width: rect.width + 6,
            height: max(1, maxY - minY)
        )
    }

    override func fillBackgroundRectArray(
        _ rectArray: UnsafePointer<NSRect>,
        count rectCount: Int,
        forCharacterRange charRange: NSRange,
        color: NSColor
    ) {
        // NSTextKit normally fills the full line fragment; inline code is
        // anchored to the glyph baseline so the tighter chip stays aligned.
        guard rectCount > 0,
              charRange.location != NSNotFound,
              charRange.location < (textStorage?.length ?? 0),
              let inlineColor = textStorage?.attribute(
                  .kodMarkdownInlineCodeBackground,
                  at: charRange.location,
                  effectiveRange: nil
              ) as? NSColor,
              inlineColor.isEqual(color),
              let font = textStorage?.attribute(
                  .font,
                  at: charRange.location,
                  effectiveRange: nil
              ) as? NSFont else {
            super.fillBackgroundRectArray(
                rectArray,
                count: rectCount,
                forCharacterRange: charRange,
                color: color
            )
            return
        }

        let glyphRange = glyphRange(
            forCharacterRange: charRange,
            actualCharacterRange: nil
        )
        var baselineOffsets: [CGFloat] = []
        enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, lineGlyphRange, _ in
            let visibleRange = NSIntersectionRange(glyphRange, lineGlyphRange)
            guard visibleRange.length > 0 else { return }
            baselineOffsets.append(self.location(forGlyphAt: visibleRange.location).y)
        }
        guard let firstBaselineOffset = baselineOffsets.first else {
            super.fillBackgroundRectArray(
                rectArray,
                count: rectCount,
                forCharacterRange: charRange,
                color: color
            )
            return
        }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        color.setFill()
        for index in 0..<rectCount {
            let baselineOffset = index < baselineOffsets.count
                ? baselineOffsets[index]
                : firstBaselineOffset
            let rect = Self.inlineCodeBackgroundRect(
                for: rectArray[index],
                font: font,
                baselineOffset: baselineOffset
            )
            NSBezierPath(
                roundedRect: rect,
                xRadius: min(4, rect.height / 2),
                yRadius: min(4, rect.height / 2)
            ).fill()
        }
    }
}

final class MarkdownRoundedTextBlock: NSTextBlock {
    let cornerRadius: CGFloat = 7

    override func drawBackground(
        withFrame frameRect: NSRect,
        in controlView: NSView,
        characterRange charRange: NSRange,
        layoutManager: NSLayoutManager
    ) {
        guard let backgroundColor else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        backgroundColor.setFill()
        NSBezierPath(
            roundedRect: frameRect,
            xRadius: cornerRadius,
            yRadius: cornerRadius
        ).fill()
    }
}

final class MarkdownTextTable: NSTextTable {
    var numberOfRows = 0
    var separatorColor: NSColor = .clear
    let cornerRadius: CGFloat = 7

    override func drawBackground(
        for block: NSTextTableBlock,
        withFrame frameRect: NSRect,
        in controlView: NSView,
        characterRange charRange: NSRange,
        layoutManager: NSLayoutManager
    ) {
        let corners = corners(for: block)
        let path = roundedPath(in: frameRect, corners: corners)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if let backgroundColor = block.backgroundColor {
            backgroundColor.setFill()
            path.fill()
        }
        separatorColor.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    private struct Corners: OptionSet {
        let rawValue: Int

        static let minXMinY = Corners(rawValue: 1 << 0)
        static let maxXMinY = Corners(rawValue: 1 << 1)
        static let maxXMaxY = Corners(rawValue: 1 << 2)
        static let minXMaxY = Corners(rawValue: 1 << 3)
    }

    private func corners(for block: NSTextTableBlock) -> Corners {
        var corners: Corners = []
        let lastColumn = Int(numberOfColumns) - 1
        let lastRow = numberOfRows - 1
        if block.startingRow == 0 && block.startingColumn == 0 {
            corners.insert(.minXMinY)
        }
        if block.startingRow == 0 && block.startingColumn == lastColumn {
            corners.insert(.maxXMinY)
        }
        if block.startingRow == lastRow && block.startingColumn == lastColumn {
            corners.insert(.maxXMaxY)
        }
        if block.startingRow == lastRow && block.startingColumn == 0 {
            corners.insert(.minXMaxY)
        }
        return corners
    }

    private func roundedPath(in rect: NSRect, corners: Corners) -> NSBezierPath {
        let radius = min(cornerRadius, min(rect.width, rect.height) / 2)
        let curveOffset = radius * 0.552_284_75
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + (corners.contains(.minXMinY) ? radius : 0), y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX - (corners.contains(.maxXMinY) ? radius : 0), y: rect.minY))
        if corners.contains(.maxXMinY) {
            path.curve(
                to: NSPoint(x: rect.maxX, y: rect.minY + radius),
                controlPoint1: NSPoint(x: rect.maxX - radius + curveOffset, y: rect.minY),
                controlPoint2: NSPoint(x: rect.maxX, y: rect.minY + radius - curveOffset)
            )
        } else {
            path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        }
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - (corners.contains(.maxXMaxY) ? radius : 0)))
        if corners.contains(.maxXMaxY) {
            path.curve(
                to: NSPoint(x: rect.maxX - radius, y: rect.maxY),
                controlPoint1: NSPoint(x: rect.maxX, y: rect.maxY - radius + curveOffset),
                controlPoint2: NSPoint(x: rect.maxX - radius + curveOffset, y: rect.maxY)
            )
        } else {
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        }
        path.line(to: NSPoint(x: rect.minX + (corners.contains(.minXMaxY) ? radius : 0), y: rect.maxY))
        if corners.contains(.minXMaxY) {
            path.curve(
                to: NSPoint(x: rect.minX, y: rect.maxY - radius),
                controlPoint1: NSPoint(x: rect.minX + radius - curveOffset, y: rect.maxY),
                controlPoint2: NSPoint(x: rect.minX, y: rect.maxY - radius + curveOffset)
            )
        } else {
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        }
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + (corners.contains(.minXMinY) ? radius : 0)))
        if corners.contains(.minXMinY) {
            path.curve(
                to: NSPoint(x: rect.minX + radius, y: rect.minY),
                controlPoint1: NSPoint(x: rect.minX, y: rect.minY + radius - curveOffset),
                controlPoint2: NSPoint(x: rect.minX + radius - curveOffset, y: rect.minY)
            )
        } else {
            path.line(to: NSPoint(x: rect.minX, y: rect.minY))
        }
        path.close()
        return path
    }
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
    private let resolvedCodeFont: ResolvedFont

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
        self.resolvedCodeFont = FontResolver.resolve(fontSettings)
    }

    private static let defaultProsePointSize: CGFloat = 16
    private static let headingScaleFactors: [CGFloat] = [2, 1.5, 1.25, 1, 0.875, 0.85]

    private var prosePointSize: CGFloat {
        Self.defaultProsePointSize * CGFloat(fontSettings.pointSize / FontSettings.default.pointSize)
    }
    private var proseFont: NSFont { .systemFont(ofSize: prosePointSize) }
    private var configuredCodeFont: NSFont { resolvedCodeFont.nsFont }
    private var codeFont: NSFont { codeFont(matchingXHeightOf: proseFont) }
    private var backgroundColor: NSColor {
        ThemeColorAppKitBridge.nsColor(theme.editor.background)
    }
    private var foregroundColor: NSColor {
        ThemeColorAppKitBridge.nsColor(theme.editor.foreground)
    }
    private var mutedColor: NSColor { surfaceColor(foregroundFraction: 0.62) }
    private var borderColor: NSColor { surfaceColor(foregroundFraction: 0.16) }
    private var inlineCodeBackgroundColor: NSColor { surfaceColor(foregroundFraction: 0.08) }
    private var codeBlockBackgroundColor: NSColor { surfaceColor(foregroundFraction: 0.055) }
    private var tableHeaderBackgroundColor: NSColor { surfaceColor(foregroundFraction: 0.08) }
    private var tableStripeBackgroundColor: NSColor { surfaceColor(foregroundFraction: 0.025) }

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
                before: level == 1 ? 0 : 24,
                after: level <= 2 ? 16 : 12,
                lineHeightMultiple: 1.25,
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
                after: context.compactParagraphs ? 4 : 16
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
                attributes: codeTextAttributes(font: codeFont, foregroundColor: mutedColor)
            )
            appendParagraph(content, into: output, context: context, before: 0, after: 16)

        case .image(let destination, _, let altText):
            let run = MarkdownRenderRun(text: altText, isImage: true, link: destination)
            appendParagraph(
                runs: [run],
                into: output,
                context: context,
                font: proseFont,
                before: 0,
                after: 16
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
        lineHeightMultiple: CGFloat = 1.5,
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
            lineHeightMultiple: lineHeightMultiple,
            extraBlock: extraBlock
        )
    }

    private func appendParagraph(
        _ content: NSMutableAttributedString,
        into output: NSMutableAttributedString,
        context: RenderContext,
        before: CGFloat,
        after: CGFloat,
        lineHeightMultiple: CGFloat = 1.5,
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
        let style = paragraphStyle(
            before: before,
            after: after,
            lineHeightMultiple: lineHeightMultiple,
            blocks: blocks
        )
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
            var font = run.isCode ? codeFont(relativeTo: baseFont) : baseFont
            if !traits.isEmpty {
                let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
                font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
            }
            var attributes = run.isCode
                ? codeTextAttributes(font: font, foregroundColor: foregroundColor)
                : [.font: font, .foregroundColor: foregroundColor]
            if run.isCode {
                attributes[.backgroundColor] = inlineCodeBackgroundColor
                attributes[.kodMarkdownInlineCodeBackground] = inlineCodeBackgroundColor
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
                string: previewUIStrings.string(
                    " Image: \(altText)",
                    comment: "Markdown preview caption following a successfully loaded image"
                ),
                attributes: [.font: proseFont, .foregroundColor: mutedColor, .toolTip: destination.rawValue]
            ))
            return result
        } else if destination.scheme == .local {
            state = .localResourceUnavailable
            text = previewUIStrings.string(
                "[Image unavailable: \(altText)]",
                comment: "Markdown preview placeholder for an unavailable local image"
            )
            color = mutedColor
        } else if failedImageDestinations.contains(destination.rawValue) {
            state = .remoteLoadFailed
            text = previewUIStrings.string(
                "[Remote image failed safety checks: \(altText)]",
                comment: "Markdown preview placeholder for a remote image rejected by safety limits"
            )
            color = .systemRed
        } else if resourcePolicy.shouldLoadRemoteImage(destination) {
            state = .remoteLoadingUnavailable
            text = previewUIStrings.string(
                "[Remote image loading: \(altText)]",
                comment: "Markdown preview placeholder while a remote image is loading"
            )
            color = mutedColor
        } else {
            state = .remoteBlocked
            text = previewUIStrings.string(
                "[Remote image blocked: \(altText)]",
                comment: "Markdown preview placeholder for a remote image blocked until explicit opt-in"
            )
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
        let content = NSMutableAttributedString(
            string: sourceText,
            attributes: codeTextAttributes(font: codeFont, foregroundColor: foregroundColor)
        )
        let utf8 = Array(sourceText.utf8)
        for run in highlightedRuns {
            guard let color = run.style.foreground,
                  run.utf8Range.lowerBound >= 0,
                  run.utf8Range.upperBound <= utf8.count else { continue }
            let lower = String(decoding: utf8[0..<run.utf8Range.lowerBound], as: UTF8.self).utf16.count
            let upper = String(decoding: utf8[0..<run.utf8Range.upperBound], as: UTF8.self).utf16.count
            content.addAttribute(
                .foregroundColor,
                value: ThemeColorAppKitBridge.nsColor(color),
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
            before: 0,
            after: 16,
            lineHeightMultiple: 1.45,
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

        let table = MarkdownTextTable()
        table.numberOfColumns = columnCount
        table.numberOfRows = allRows.count
        table.separatorColor = borderColor
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false

        for rowIndex in allRows.indices {
            for columnIndex in 0..<columnCount {
                let runs = columnIndex < allRows[rowIndex].count ? allRows[rowIndex][columnIndex] : []
                let font = rowIndex == 0
                    ? NSFont.systemFont(ofSize: prosePointSize, weight: .semibold)
                    : proseFont
                let cell = attributedRuns(runs, baseFont: font)
                cell.append(NSAttributedString(
                    string: "\n",
                    attributes: [.font: font, .foregroundColor: foregroundColor]
                ))

                let tableBlock = NSTextTableBlock(
                    table: table,
                    startingRow: rowIndex,
                    rowSpan: 1,
                    startingColumn: columnIndex,
                    columnSpan: 1
                )
                tableBlock.setWidth(0.5, type: .absoluteValueType, for: .border)
                tableBlock.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
                tableBlock.setWidth(12, type: .absoluteValueType, for: .padding, edge: .maxX)
                tableBlock.setWidth(7, type: .absoluteValueType, for: .padding, edge: .minY)
                tableBlock.setWidth(7, type: .absoluteValueType, for: .padding, edge: .maxY)
                tableBlock.setBorderColor(borderColor)
                if rowIndex == 0 {
                    tableBlock.backgroundColor = tableHeaderBackgroundColor
                } else if rowIndex.isMultiple(of: 2) {
                    tableBlock.backgroundColor = tableStripeBackgroundColor
                }
                if rowIndex == allRows.count - 1 {
                    tableBlock.setWidth(16, type: .absoluteValueType, for: .margin, edge: .maxY)
                }
                let style = paragraphStyle(
                    before: 0,
                    after: 0,
                    lineHeightMultiple: 1.35,
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
        lineHeightMultiple: CGFloat = 1.5,
        blocks: [NSTextBlock]
    ) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.lineHeightMultiple = lineHeightMultiple
        style.lineBreakMode = .byWordWrapping
        style.textBlocks = blocks
        return style
    }

    private func makeCodeBlock() -> NSTextBlock {
        let block = MarkdownRoundedTextBlock()
        block.backgroundColor = codeBlockBackgroundColor
        block.setWidth(14, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(14, type: .absoluteValueType, for: .padding, edge: .maxX)
        block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxY)
        block.setContentWidth(100, type: .percentageValueType)
        return block
    }

    private func makeQuoteBlock() -> NSTextBlock {
        let block = NSTextBlock()
        block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
        block.setBorderColor(mutedColor, for: .minX)
        block.setContentWidth(100, type: .percentageValueType)
        return block
    }

    private func makeHeadingBlock() -> NSTextBlock {
        let block = NSTextBlock()
        block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
        block.setBorderColor(borderColor, for: .maxY)
        block.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxY)
        block.setContentWidth(100, type: .percentageValueType)
        return block
    }

    private func makeRuleBlock() -> NSTextBlock {
        let block = NSTextBlock()
        block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
        block.setBorderColor(borderColor, for: .maxY)
        block.setContentWidth(100, type: .percentageValueType)
        return block
    }

    private func surfaceColor(foregroundFraction: CGFloat) -> NSColor {
        backgroundColor.blended(withFraction: foregroundFraction, of: foregroundColor)
            ?? backgroundColor
    }

    private func codeFont(relativeTo baseFont: NSFont) -> NSFont {
        codeFont(matchingXHeightOf: baseFont)
    }

    private func codeFont(matchingXHeightOf referenceFont: NSFont) -> NSFont {
        guard configuredCodeFont.xHeight > 0 else { return configuredCodeFont }
        let size = configuredCodeFont.pointSize * (referenceFont.xHeight / configuredCodeFont.xHeight)
        return NSFont(descriptor: configuredCodeFont.fontDescriptor, size: size)
            ?? configuredCodeFont
    }

    private func codeTextAttributes(
        font: NSFont,
        foregroundColor: NSColor
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foregroundColor,
            .ligature: resolvedCodeFont.ligatureAttributeValue
        ]
        if resolvedCodeFont.letterSpacing != 0 {
            attributes[.kern] = resolvedCodeFont.letterSpacing
        }
        return attributes
    }
}
