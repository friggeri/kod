import AppKit
import CodeViewport
import GitCore
import SourceModel
import ThemeCore

@MainActor
func configureReadOnlyScrollingTextView(
    _ textView: NSTextView,
    in scrollView: NSScrollView,
    wrapsLines: Bool
) {
    let contentSize = NSSize(
        width: max(scrollView.contentSize.width, 1),
        height: max(scrollView.contentSize.height, 1)
    )
    textView.frame = NSRect(origin: .zero, size: contentSize)
    textView.minSize = NSSize(width: 0, height: contentSize.height)
    textView.maxSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
    )
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = !wrapsLines
    textView.autoresizingMask = [.width]
    textView.textContainer?.containerSize = NSSize(
        width: wrapsLines ? contentSize.width : CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
    )
    textView.textContainer?.widthTracksTextView = wrapsLines
    textView.textContainerInset = NSSize(width: 10, height: 8)
    scrollView.documentView = textView
    scrollView.hasHorizontalScroller = !wrapsLines
}

@MainActor
private final class GitQuickDiffTextView: NSTextView {
    struct RowBackground {
        let characterRange: NSRange
        let color: NSColor
    }

    var rowBackgrounds: [RowBackground] = [] {
        didSet {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        dirtyRect.fill()
        drawRowBackgrounds(in: dirtyRect)
        super.draw(dirtyRect)
    }

    private func drawRowBackgrounds(in dirtyRect: NSRect) {
        guard let layoutManager, let textContainer else {
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        let origin = textContainerOrigin
        for row in rowBackgrounds {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: row.characterRange,
                actualCharacterRange: nil
            )
            guard glyphRange.length > 0 else {
                continue
            }
            let fragment = layoutManager.lineFragmentRect(
                forGlyphAt: glyphRange.location,
                effectiveRange: nil
            )
            let rowRect = NSRect(
                x: 0,
                y: fragment.minY + origin.y,
                width: bounds.width,
                height: fragment.height
            )
            guard rowRect.intersects(dirtyRect) else {
                continue
            }
            row.color.setFill()
            rowRect.fill()
        }
    }
}

/// The Git file diff viewer (SPEC 9.1: "Unified and side-by-side diff
/// modes"). Renders a single `GitFileDiff` either as one linear list of
/// context/added/removed lines or as paired left/right rows (via
/// `GitSideBySideProjection`, already unit-tested in `GitCoreTests`).
/// Rendering itself uses two plain `NSTextView`s; every row's content is
/// built by a pure, headlessly-testable method (`unifiedRows`/
/// `sideBySideRows`) so `GitDiffViewControllerTests` can assert on
/// exactly what would be displayed without measuring drawn text.
@MainActor
final class GitDiffViewController: NSViewController {
    enum Mode: Equatable {
        case unified
        case sideBySide
    }

    struct GitQuickDiffSource {
        let label: String
        let diff: GitFileDiff
        let projection: GitQuickDiffProjection
        let layer: CodeGutterChange.Layer
    }

    @MainActor
    final class GitQuickDiffController {
        private weak var documentController: CodeDocumentViewController?
        private var sourcesByProviderID: [String: GitQuickDiffSource] = [:]
        private var hunksByID: [GitQuickDiffHunkID: GitQuickDiffHunk] = [:]
        private var orderedHunkIDs: [GitQuickDiffHunkID] = []
        private var hunkIDByGutterID: [String: GitQuickDiffHunkID] = [:]
        private var peekController: GitQuickDiffPeekViewController?
        private var unavailableController: GitQuickDiffUnavailableViewController?
        private var unavailableDiff: GitFileDiff?
        private(set) var selectedHunkID: GitQuickDiffHunkID?
        private var layerVersion = 0

        var onOpenFullDiff: ((GitFileDiff) -> Void)?

        init(documentController: CodeDocumentViewController) {
            self.documentController = documentController
            documentController.viewport.onGutterChangeClick = { [weak self] gutterID in
                self?.toggleHunk(forGutterID: gutterID)
            }
            documentController.viewport.onCancelEmbeddedViewZone = { [weak self] in
                self?.dismissPresentedZone() ?? false
            }
        }

        func update(sources: [GitQuickDiffSource], revealFirstHunk: Bool = false) {
            guard let documentController else {
                return
            }
            removeUnavailable()

            sourcesByProviderID = Dictionary(
                uniqueKeysWithValues: sources.map { ($0.projection.provider.id, $0) }
            )
            hunksByID = [:]
            hunkIDByGutterID = [:]
            var changes: [CodeGutterChange] = []
            var visibleHunkIDs: Set<GitQuickDiffHunkID> = []

            for source in sources {
                for hunk in source.projection.hunks {
                    hunksByID[hunk.id] = hunk
                    for mark in hunk.marks {
                        let gutterID = Self.gutterID(for: mark.hunkID)
                        let zeroBasedRange = (mark.currentLineRange.lowerBound - 1)..<(mark.currentLineRange.upperBound - 1)
                        guard !zeroBasedRange.isEmpty else {
                            continue
                        }
                        hunkIDByGutterID[gutterID] = mark.hunkID
                        visibleHunkIDs.insert(mark.hunkID)
                        let kind: CodeGutterChange.Kind = mark.kind == .added ? .added : .modified
                        changes.append(
                            CodeGutterChange(
                                id: gutterID,
                                kind: kind,
                                layer: source.layer,
                                location: .lines(zeroBasedRange),
                                accessibilityLabel: Self.accessibilityLabel(
                                    kind: kind,
                                    oneBasedRange: mark.currentLineRange,
                                    providerLabel: source.label
                                )
                            )
                        )
                    }
                    for deletion in hunk.deletionAnchors {
                        let gutterID = Self.gutterID(for: deletion.hunkID)
                        hunkIDByGutterID[gutterID] = deletion.hunkID
                        visibleHunkIDs.insert(deletion.hunkID)
                        changes.append(
                            CodeGutterChange(
                                id: gutterID,
                                kind: .deleted,
                                layer: source.layer,
                                location: .deletion(afterLine: deletion.afterCurrentLineNumber - 1),
                                accessibilityLabel: Localized.string(
                                    "Deleted lines, \(source.label)",
                                    comment: "Accessibility label for a deleted Git hunk in the editor gutter"
                                )
                            )
                        )
                    }
                }
            }

            orderedHunkIDs = visibleHunkIDs.sorted { lhs, rhs in
                let lhsStart = hunksByID[lhs]?.diffHunk.newStart ?? Int.max
                let rhsStart = hunksByID[rhs]?.diffHunk.newStart ?? Int.max
                if lhsStart != rhsStart {
                    return lhsStart < rhsStart
                }
                return lhs < rhs
            }

            layerVersion += 1
            guard documentController.viewport.applyGutterChanges(
                changes,
                snapshotVersion: documentController.snapshot.version,
                layerVersion: layerVersion
            ) else {
                closePeek()
                documentController.viewport.clearGutterChanges()
                return
            }

            if let selectedHunkID, visibleHunkIDs.contains(selectedHunkID) {
                showHunk(selectedHunkID)
            } else {
                closePeek()
                if revealFirstHunk, let first = orderedHunkIDs.first {
                    showHunk(first)
                }
            }
        }

        func clear() {
            sourcesByProviderID = [:]
            hunksByID = [:]
            orderedHunkIDs = []
            hunkIDByGutterID = [:]
            closePeek()
            removeUnavailable()
            documentController?.viewport.clearGutterChanges()
        }

        func showUnavailable(message: String, diff: GitFileDiff? = nil) {
            guard let documentController else {
                return
            }
            sourcesByProviderID = [:]
            hunksByID = [:]
            orderedHunkIDs = []
            hunkIDByGutterID = [:]
            closePeek()
            removeUnavailable()
            documentController.viewport.clearGutterChanges()

            let controller = GitQuickDiffUnavailableViewController(
                message: message,
                onOpenFullDiff: diff.map { _ in { [weak self] in self?.openFullDiff() } }
            )
            controller.loadViewIfNeeded()
            let anchor = max(-1, documentController.viewport.topmostVisibleLine - 1)
            guard documentController.viewport.installViewZone(
                id: Self.unavailableZoneID,
                afterLine: anchor,
                heightInLines: 5,
                view: controller.view
            ) else {
                return
            }
            unavailableDiff = diff
            unavailableController = controller
        }

        func showNextHunk() {
            navigateHunk(by: 1)
        }

        func showPreviousHunk() {
            navigateHunk(by: -1)
        }

        func openFullDiff() {
            if let selectedHunkID,
               let source = sourcesByProviderID[selectedHunkID.provider.id] {
                onOpenFullDiff?(source.diff)
            } else if let unavailableDiff {
                onOpenFullDiff?(unavailableDiff)
            }
        }

        func closePeek() {
            let viewport = documentController?.viewport
            let window = viewport?.window
            let focusedInsidePeek = (window?.firstResponder as? NSView).map { responder in
                guard let peekView = peekController?.view else {
                    return false
                }
                return responder === peekView || responder.isDescendant(of: peekView)
            } ?? false
            if let selectedHunkID {
                viewport?.removeViewZone(
                    id: CodeViewZoneID(Self.gutterID(for: selectedHunkID))
                )
            }
            selectedHunkID = nil
            peekController = nil
            if focusedInsidePeek, let viewport {
                window?.makeFirstResponder(viewport)
            }
        }

        private func dismissPresentedZone() -> Bool {
            if selectedHunkID != nil {
                closePeek()
                return true
            }
            if unavailableController != nil {
                removeUnavailable()
                return true
            }
            return false
        }

        func refreshTheme() {
            guard let selectedHunkID else {
                return
            }
            showHunk(selectedHunkID)
        }

        private func toggleHunk(forGutterID gutterID: String) {
            guard let hunkID = hunkIDByGutterID[gutterID] else {
                return
            }
            if selectedHunkID == hunkID {
                closePeek()
            } else {
                showHunk(hunkID)
            }
        }

        private func navigateHunk(by offset: Int) {
            guard !orderedHunkIDs.isEmpty else {
                return
            }
            let currentIndex = selectedHunkID.flatMap { orderedHunkIDs.firstIndex(of: $0) }
                ?? (offset > 0 ? -1 : orderedHunkIDs.count)
            let nextIndex = (currentIndex + offset + orderedHunkIDs.count) % orderedHunkIDs.count
            showHunk(orderedHunkIDs[nextIndex])
        }

        private func showHunk(_ hunkID: GitQuickDiffHunkID) {
            guard let documentController,
                  let hunk = hunksByID[hunkID],
                  let source = sourcesByProviderID[hunkID.provider.id] else {
                closePeek()
                return
            }
            let window = documentController.viewport.window
            let focusedInsideExistingPeek = (window?.firstResponder as? NSView).map { responder in
                guard let peekView = peekController?.view else {
                    return false
                }
                return responder === peekView || responder.isDescendant(of: peekView)
            } ?? false

            if let selectedHunkID, selectedHunkID != hunkID {
                documentController.viewport.removeViewZone(
                    id: CodeViewZoneID(Self.gutterID(for: selectedHunkID))
                )
            }

            let index = orderedHunkIDs.firstIndex(of: hunkID) ?? 0
            let controller = GitQuickDiffPeekViewController(
                hunk: hunk.diffHunk,
                fileName: (source.diff.change.newPath as NSString).lastPathComponent,
                providerLabel: source.label,
                hunkIndex: index,
                hunkCount: orderedHunkIDs.count,
                theme: documentController.theme,
                onPrevious: { [weak self] in self?.showPreviousHunk() },
                onNext: { [weak self] in self?.showNextHunk() },
                onOpenFullDiff: { [weak self] in self?.openFullDiff() },
                onClose: { [weak self] in self?.closePeek() }
            )
            controller.loadViewIfNeeded()

            let anchor = Self.anchorAfterLine(for: hunk, lineCount: documentController.snapshot.lineCount)
            let height = max(3, min(10, hunk.diffHunk.lines.count) + 1)
            guard documentController.viewport.installViewZone(
                id: CodeViewZoneID(Self.gutterID(for: hunkID)),
                afterLine: anchor,
                heightInLines: height,
                view: controller.view
            ) else {
                closePeek()
                return
            }

            selectedHunkID = hunkID
            peekController = controller
            documentController.viewport.scrollViewZoneToTop(id: CodeViewZoneID(Self.gutterID(for: hunkID)))
            if focusedInsideExistingPeek {
                window?.makeFirstResponder(documentController.viewport)
            }
        }

        private func removeUnavailable() {
            documentController?.viewport.removeViewZone(id: Self.unavailableZoneID)
            unavailableController = nil
            unavailableDiff = nil
        }

        private static func anchorAfterLine(for hunk: GitQuickDiffHunk, lineCount: Int) -> Int {
            let markAnchors = hunk.marks.map { $0.currentLineRange.upperBound - 2 }
            let deletionAnchors = hunk.deletionAnchors.map { $0.afterCurrentLineNumber - 1 }
            let fallback = hunk.diffHunk.newStart + max(0, hunk.diffHunk.newCount - 1) - 1
            return max(-1, min((markAnchors + deletionAnchors).max() ?? fallback, lineCount - 1))
        }

        private static func gutterID(for hunkID: GitQuickDiffHunkID) -> String {
            "\(hunkID.provider.id):\(hunkID.index)"
        }

        private static let unavailableZoneID = CodeViewZoneID("git-quick-diff:unavailable")

        private static func accessibilityLabel(
            kind: CodeGutterChange.Kind,
            oneBasedRange: Range<Int>,
            providerLabel: String
        ) -> String {
            let kindLabel: String
            switch kind {
            case .added:
                kindLabel = Localized.string("Added", comment: "Git gutter change kind")
            case .modified:
                kindLabel = Localized.string("Modified", comment: "Git gutter change kind")
            case .deleted:
                kindLabel = Localized.string("Deleted", comment: "Git gutter change kind")
            }
            let rangeLabel = oneBasedRange.count == 1
                ? "\(oneBasedRange.lowerBound)"
                : "\(oneBasedRange.lowerBound)-\(oneBasedRange.upperBound - 1)"
            return Localized.string(
                "\(kindLabel) lines \(rangeLabel), \(providerLabel)",
                comment: "Accessibility label for an added or modified Git hunk in the editor gutter"
            )
        }
    }

    @MainActor
    final class GitQuickDiffUnavailableViewController: NSViewController {
        private let message: String
        private let onOpenFullDiff: (() -> Void)?

        init(message: String, onOpenFullDiff: (() -> Void)?) {
            self.message = message
            self.onOpenFullDiff = onOpenFullDiff
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override func loadView() {
            let container = NSView()
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            container.layer?.borderColor = NSColor.separatorColor.cgColor
            container.layer?.borderWidth = 1

            let label = NSTextField(wrappingLabelWithString: message)
            label.setAccessibilityLabel(message)
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)

            var trailingAnchor = label.trailingAnchor.constraint(
                lessThanOrEqualTo: container.trailingAnchor,
                constant: -12
            )
            if onOpenFullDiff != nil {
                let button = NSButton(
                    title: Localized.string(
                        "Open Full Diff",
                        comment: "Button title opening the full Git diff from an unavailable inline diff"
                    ),
                    target: self,
                    action: #selector(openFullDiff(_:))
                )
                button.bezelStyle = .rounded
                button.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(button)
                trailingAnchor = label.trailingAnchor.constraint(
                    lessThanOrEqualTo: button.leadingAnchor,
                    constant: -12
                )
                NSLayoutConstraint.activate([
                    button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
                    button.centerYAnchor.constraint(equalTo: container.centerYAnchor)
                ])
            }

            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                trailingAnchor
            ])
            view = container
        }

        @objc
        private func openFullDiff(_ sender: Any?) {
            onOpenFullDiff?()
        }
    }

    @MainActor
    final class GitQuickDiffPeekViewController: NSViewController {
        private let hunk: GitDiffHunk
        private let fileName: String
        private let providerLabel: String
        private let hunkIndex: Int
        private let hunkCount: Int
        private let theme: KodTheme
        private let onPrevious: () -> Void
        private let onNext: () -> Void
        private let onOpenFullDiff: () -> Void
        private let onClose: () -> Void

        private let titleLabel = NSTextField(labelWithString: "")
        private let textView = GitQuickDiffTextView()

        init(
            hunk: GitDiffHunk,
            fileName: String,
            providerLabel: String,
            hunkIndex: Int,
            hunkCount: Int,
            theme: KodTheme,
            onPrevious: @escaping () -> Void,
            onNext: @escaping () -> Void,
            onOpenFullDiff: @escaping () -> Void,
            onClose: @escaping () -> Void
        ) {
            self.hunk = hunk
            self.fileName = fileName
            self.providerLabel = providerLabel
            self.hunkIndex = hunkIndex
            self.hunkCount = hunkCount
            self.theme = theme
            self.onPrevious = onPrevious
            self.onNext = onNext
            self.onOpenFullDiff = onOpenFullDiff
            self.onClose = onClose
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override func loadView() {
            let container = NSView()
            container.wantsLayer = true
            container.layer?.backgroundColor = theme.editor.background.nsColor.cgColor
            container.layer?.borderColor = theme.git.gutterModified.nsColor.cgColor
            container.layer?.borderWidth = 1
            container.layer?.masksToBounds = true

            let title = Localized.string(
                "\(fileName) Git Local Changes (\(providerLabel)) — \(hunkIndex + 1) of \(max(1, hunkCount))",
                comment: "Inline Git diff hunk header"
            )
            titleLabel.stringValue = title
            titleLabel.font = .systemFont(ofSize: 11)
            titleLabel.textColor = theme.editor.foreground.nsColor
            titleLabel.lineBreakMode = .byTruncatingMiddle
            titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            titleLabel.setAccessibilityLabel(title)

            let previousButton = symbolButton(
                "chevron.up",
                label: Localized.string("Previous Change", comment: "Inline Git diff previous-change button"),
                action: #selector(previousChange(_:))
            )
            let nextButton = symbolButton(
                "chevron.down",
                label: Localized.string("Next Change", comment: "Inline Git diff next-change button"),
                action: #selector(nextChange(_:))
            )
            let fullDiffButton = symbolButton(
                "rectangle.split.2x1",
                label: Localized.string(
                    "Open Full Diff",
                    comment: "Inline Git diff action opening the full diff view"
                ),
                action: #selector(openFullDiff(_:))
            )
            let closeButton = symbolButton(
                "xmark",
                label: Localized.string("Close Inline Diff", comment: "Inline Git diff close button"),
                action: #selector(closeInlineDiff(_:))
            )

            let header = NSStackView(views: [
                titleLabel,
                NSView(),
                fullDiffButton,
                previousButton,
                nextButton,
                closeButton
            ])
            header.orientation = .horizontal
            header.alignment = .centerY
            header.spacing = 4
            header.edgeInsets = NSEdgeInsets(top: 2, left: 10, bottom: 2, right: 6)
            header.translatesAutoresizingMaskIntoConstraints = false
            header.wantsLayer = true
            header.layer?.backgroundColor = theme.editor.stickyScopeBackground.nsColor.cgColor

            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.backgroundColor = theme.editor.background.nsColor
            textView.textColor = theme.editor.foreground.nsColor
            textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            textView.setAccessibilityLabel(
                Localized.string(
                    "Inline diff for \(providerLabel)",
                    comment: "Accessibility label for inline Git diff text"
                )
            )

            let scrollView = NSScrollView()
            scrollView.hasVerticalScroller = hunk.lines.count > 10
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = false
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            configureReadOnlyScrollingTextView(textView, in: scrollView, wrapsLines: false)
            textView.textContainerInset = NSSize(width: 6, height: 3)

            container.addSubview(header)
            container.addSubview(scrollView)
            NSLayoutConstraint.activate([
                header.topAnchor.constraint(equalTo: container.topAnchor),
                header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
                scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])

            view = container
            renderHunk()
        }

        @objc
        override func cancelOperation(_ sender: Any?) {
            onClose()
        }

        @objc
        private func previousChange(_ sender: Any?) {
            onPrevious()
        }

        @objc
        private func nextChange(_ sender: Any?) {
            onNext()
        }

        @objc
        private func openFullDiff(_ sender: Any?) {
            onOpenFullDiff()
        }

        @objc
        private func closeInlineDiff(_ sender: Any?) {
            onClose()
        }

        private func symbolButton(_ symbol: String, label: String, action: Selector) -> NSButton {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
            let button = NSButton(image: image, target: self, action: action)
            button.bezelStyle = .inline
            button.controlSize = .small
            button.toolTip = label
            button.setAccessibilityLabel(label)
            return button
        }

        private func renderHunk() {
            let attributed = NSMutableAttributedString()
            var rowBackgrounds: [GitQuickDiffTextView.RowBackground] = []
            var intralineRangesByLine: [Int: [Range<Int>]] = [:]
            for highlight in GitIntralineDiff.highlights(for: hunk) {
                intralineRangesByLine[highlight.lineIndex] = highlight.utf16Ranges
            }
            let lineNumberWidth = max(
                1,
                String(max(hunk.oldStart + hunk.oldCount, hunk.newStart + hunk.newCount)).count
            )

            for (index, line) in hunk.lines.enumerated() {
                let marker: String
                let markerColor: NSColor
                let background: NSColor?
                switch line.kind {
                case .added:
                    marker = "+"
                    markerColor = theme.git.gutterAdded.nsColor
                    background = theme.git.insertedBackground.nsColor
                case .removed:
                    marker = "-"
                    markerColor = theme.git.gutterDeleted.nsColor
                    background = theme.git.removedBackground.nsColor
                case .context:
                    marker = " "
                    markerColor = theme.editor.gutterForeground.nsColor
                    background = nil
                case .noNewlineAtEndOfFile:
                    marker = "\\"
                    markerColor = theme.editor.gutterForeground.nsColor
                    background = nil
                }

                let oldNumber = Self.padded(line.oldLineNumber, width: lineNumberWidth)
                let newNumber = Self.padded(line.newLineNumber, width: lineNumberWidth)
                let prefix = "\(marker) \(oldNumber) \(newNumber)  "
                let row = "\(prefix)\(line.text)"
                    + (index == hunk.lines.count - 1 ? "" : "\n")
                let rowRange = NSRange(location: attributed.length, length: (row as NSString).length)
                let rowString = NSMutableAttributedString(
                    string: row,
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                        .foregroundColor: theme.editor.foreground.nsColor
                    ]
                )
                rowString.addAttribute(
                    .foregroundColor,
                    value: markerColor,
                    range: NSRange(location: 0, length: min(1, rowString.length))
                )
                let intralineBackground: NSColor?
                switch line.kind {
                case .added:
                    intralineBackground = theme.git.insertedTextBackground.nsColor
                case .removed:
                    intralineBackground = theme.git.removedTextBackground.nsColor
                case .context, .noNewlineAtEndOfFile:
                    intralineBackground = nil
                }
                if let intralineBackground {
                    let contentOffset = (prefix as NSString).length
                    for range in intralineRangesByLine[index] ?? [] {
                        let highlightRange = NSRange(
                            location: contentOffset + range.lowerBound,
                            length: range.count
                        )
                        guard NSMaxRange(highlightRange) <= rowString.length else {
                            continue
                        }
                        rowString.addAttribute(
                            .backgroundColor,
                            value: intralineBackground,
                            range: highlightRange
                        )
                    }
                }
                if let background {
                    rowBackgrounds.append(
                        GitQuickDiffTextView.RowBackground(
                            characterRange: rowRange,
                            color: background
                        )
                    )
                }
                attributed.append(rowString)
            }
            textView.textStorage?.setAttributedString(attributed)
            textView.rowBackgrounds = rowBackgrounds
        }

        private static func padded(_ value: Int?, width: Int) -> String {
            guard let value else {
                return String(repeating: " ", count: width)
            }
            let string = String(value)
            return String(repeating: " ", count: max(0, width - string.count)) + string
        }

        var renderedText: String {
            textView.string
        }

        var renderedTitle: String {
            titleLabel.stringValue
        }

        var renderedColoredRowCount: Int {
            textView.rowBackgrounds.count
        }

        var renderedIntralineHighlights: [String] {
            guard let textStorage = textView.textStorage else {
                return []
            }
            var result: [String] = []
            textStorage.enumerateAttribute(
                .backgroundColor,
                in: NSRange(location: 0, length: textStorage.length)
            ) { value, range, _ in
                guard value != nil else {
                    return
                }
                result.append((textStorage.string as NSString).substring(with: range))
            }
            return result
        }
    }

    struct UnifiedRow: Equatable {
        let kind: GitDiffLineKind
        let text: String
    }

    struct SideBySideDisplayRow: Equatable {
        let leftText: String?
        let rightText: String?
        /// Textual left/right change markers ("+"/"-"/" ", matching the
        /// unified mode's own marker vocabulary) so side-by-side mode
        /// conveys added/removed/context the same way as text, never by
        /// color alone (SPEC 14).
        let leftMarker: String
        let rightMarker: String
    }

    private(set) var mode: Mode = .unified
    private(set) var diff: GitFileDiff?

    private let modeControl = NSSegmentedControl(
        labels: [
            Localized.string("Unified", comment: "Diff view mode segment: unified diff layout"),
            Localized.string("Side by Side", comment: "Diff view mode segment: side-by-side diff layout")
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let statusLabel = NSTextField(labelWithString: Localized.string("No diff.", comment: "Status text shown when there is no Git diff to display"))
    private let textView = NSTextView()

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let container = NSView()

        modeControl.segmentStyle = .texturedRounded
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.identifier = NSUserInterfaceItemIdentifier("gitDiff.mode")
        modeControl.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.identifier = NSUserInterfaceItemIdentifier("gitDiff.status")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        textView.identifier = NSUserInterfaceItemIdentifier("gitDiff.textView")
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .labelColor
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        configureReadOnlyScrollingTextView(textView, in: scrollView, wrapsLines: false)

        container.addSubview(modeControl)
        container.addSubview(statusLabel)
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            modeControl.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            modeControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: modeControl.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: modeControl.trailingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        view = container
    }

    func update(diff: GitFileDiff?) {
        self.diff = diff
        renderCurrentMode()
    }

    func setMode(_ mode: Mode) {
        self.mode = mode
        modeControl.selectedSegment = mode == .unified ? 0 : 1
        renderCurrentMode()
    }

    @objc
    private func modeChanged(_ sender: Any?) {
        mode = modeControl.selectedSegment == 0 ? .unified : .sideBySide
        renderCurrentMode()
    }

    private func renderCurrentMode() {
        guard let diff else {
            textView.string = ""
            statusLabel.stringValue = Localized.string("No diff.", comment: "Status text shown when there is no Git diff to display")
            return
        }

        if case .binary = diff.content {
            textView.string = Localized.string(
                "Binary file — no textual diff available.",
                comment: "Text shown in the diff view when the file is binary and has no textual diff"
            )
            statusLabel.stringValue = Localized.string(
                "\(diff.change.newPath) (binary)",
                comment: "Status text showing a binary file's path"
            )
            return
        }

        statusLabel.stringValue = diff.change.newPath

        switch mode {
        case .unified:
            textView.string = Self.unifiedRows(for: diff.hunks)
                .map { row in
                    let marker: String
                    switch row.kind {
                    case .added: marker = "+"
                    case .removed: marker = "-"
                    case .context: marker = " "
                    case .noNewlineAtEndOfFile: marker = "\\"
                    }
                    return marker + row.text
                }
                .joined(separator: "\n")
        case .sideBySide:
            textView.string = Self.sideBySideDisplayRows(for: diff.hunks)
                .map { "\($0.leftMarker)\($0.leftText ?? "") | \($0.rightMarker)\($0.rightText ?? "")" }
                .joined(separator: "\n")
        }
        textView.setAccessibilityLabel(
            Localized.string(
                "Diff for \(diff.change.newPath), \(mode == .unified ? "unified" : "side by side") mode",
                comment: "Accessibility label for the diff text view, naming the file and current diff-layout mode"
            )
        )
    }

    /// Pure: every hunk's lines in linear (unified) order, with a blank
    /// separator row's absence between hunks left to the caller (Kod
    /// currently renders hunks back to back without an explicit "..."
    /// ellipsis row).
    static func unifiedRows(for hunks: [GitDiffHunk]) -> [UnifiedRow] {
        hunks.flatMap { hunk in
            hunk.lines.map { UnifiedRow(kind: $0.kind, text: $0.text) }
        }
    }

    /// Pure: every hunk's lines projected side by side via
    /// `GitSideBySideProjection`.
    static func sideBySideDisplayRows(for hunks: [GitDiffHunk]) -> [SideBySideDisplayRow] {
        hunks.flatMap { hunk in
            GitSideBySideProjection.rows(for: hunk).map { row in
                SideBySideDisplayRow(
                    leftText: row.left?.text,
                    rightText: row.right?.text,
                    leftMarker: marker(for: row.left?.kind),
                    rightMarker: marker(for: row.right?.kind)
                )
            }
        }
    }

    private static func marker(for kind: GitDiffLineKind?) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "-"
        case .context: return " "
        case .noNewlineAtEndOfFile: return "\\"
        case nil: return " "
        }
    }

    var renderedText: String { textView.string }
    var renderedTextViewFrame: NSRect { textView.frame }
}

typealias GitQuickDiffSource = GitDiffViewController.GitQuickDiffSource
typealias GitQuickDiffController = GitDiffViewController.GitQuickDiffController
