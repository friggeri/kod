import AppKit
import GitCore

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
