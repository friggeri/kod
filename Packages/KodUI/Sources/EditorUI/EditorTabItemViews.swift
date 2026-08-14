import AppKit
import KodUIComponents
import QuartzCore
import WorkspaceCore

/// The views one tab chip is built from — its collection-view item, its
/// hit-testing container, the title/icon/close/pin controls and the
/// selection backing — together with the pure accessibility value they
/// present.

/// Pure: the accessibility "value" describing one tab's current state
/// (selection, pinned vs. preview, tombstoned) as a short spoken phrase —
/// e.g. "Selected, pinned tab" or "Unavailable, preview tab" — kept
/// separate from the tab chip that renders it (`EditorTabCollectionItem`,
/// below) so `EditorGroupTabAccessibilityTests` can assert on it directly
/// without needing a real view, and so the phrase used in the chip's actual
/// `accessibilityValue()` can never silently drift from what a test
/// verifies (SPEC 14: tabs need "a value/state for pinned vs. preview
/// vs. dirty-external-change/tombstoned" — Kod is strictly read-only, so
/// there is no "dirty/unsaved" tab state to represent here).
func editorTabAccessibilityValue(tab: EditorTab, isSelected: Bool) -> String {
    var parts: [String] = []
    if isSelected {
        parts.append(editorUIStrings.string("Selected", comment: "Accessibility value component indicating a tab chip is the currently selected tab"))
    }
    if tab.isTombstoned {
        parts.append(editorUIStrings.string("Unavailable", comment: "Accessibility value component indicating a tab chip's file is no longer available"))
    }
    parts.append(
        tab.isPinned
            ? editorUIStrings.string("Pinned tab", comment: "Accessibility value component indicating a tab chip is pinned")
            : editorUIStrings.string("Preview tab", comment: "Accessibility value component indicating a tab chip is an unpinned preview tab")
    )
    return parts.joined(separator: ", ")
}

@MainActor
final class EditorTabItemView: NSView {
    var tabID: EditorTabID?
    var onMouseDown: ((NSEvent) -> Void)?
    var onMouseDragged: ((NSEvent) -> Void)?
    var onMouseUp: ((NSEvent) -> Void)?
    var onSetDraggingAppearance: ((Bool) -> Void)?
    var onSetDisplacement: ((CGFloat, TimeInterval) -> Void)?
    var onResetDisplacement: (() -> Void)?
    var onSetSeparatorSuppressedForDrag: ((Bool) -> Void)?
    private var trackedMouseDragged: ((NSEvent) -> Void)?
    private var trackedMouseUp: ((NSEvent) -> Void)?

    func setDraggingAppearance(_ isDragging: Bool) {
        onSetDraggingAppearance?(isDragging)
    }

    func setDisplacement(x: CGFloat, duration: TimeInterval) {
        onSetDisplacement?(x, duration)
    }

    func resetDisplacement() {
        onResetDisplacement?()
    }

    func setSeparatorSuppressedForDrag(_ isSuppressed: Bool) {
        onSetSeparatorSuppressedForDrag?(isSuppressed)
    }

    override func mouseDown(with event: NSEvent) {
        guard let onMouseDown else {
            trackedMouseDragged = nil
            trackedMouseUp = nil
            super.mouseDown(with: event)
            return
        }
        trackedMouseDragged = onMouseDragged
        trackedMouseUp = onMouseUp
        onMouseDown(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let handler = trackedMouseDragged ?? onMouseDragged else {
            super.mouseDragged(with: event)
            return
        }
        handler(event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let handler = trackedMouseUp ?? onMouseUp else {
            super.mouseUp(with: event)
            return
        }
        trackedMouseDragged = nil
        trackedMouseUp = nil
        handler(event)
    }
}

@MainActor
private final class EditorTabTitleButton: NSButton {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // NSButton otherwise consumes the mouse sequence, preventing the
        // collection view from recognizing a drag that begins on the title.
        nil
    }
}

@MainActor
private final class EditorTabIconView: MaterialFileIconView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
private final class EditorTabContentView: NSStackView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hitView = super.hitTest(point)
        return hitView is NSButton ? hitView : nil
    }
}

@MainActor
private final class EditorTabBackgroundView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
private final class EditorTabVisualView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hitView = super.hitTest(point)
        return hitView is NSButton ? hitView : nil
    }
}

@MainActor
final class EditorTabCollectionItem: NSCollectionViewItem {
    private let itemView = EditorTabItemView()
    private let visualView = EditorTabVisualView()
    private let titleButton = EditorTabTitleButton(title: "", target: nil, action: nil)
    private let fileIconView = EditorTabIconView()
    private let contentView = EditorTabContentView()
    private let selectionBackgroundView = EditorTabBackgroundView()
    private let pinButton = NSButton(
        image: NSImage(
            systemSymbolName: "pin",
            accessibilityDescription: editorUIStrings.string(
                "Pin Tab",
                comment: "Generic accessibility description for the pin-tab image, overridden per-tab below"
            )
        ) ?? NSImage(),
        target: nil,
        action: nil
    )
    private let closeButton = NSButton(
        image: NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: editorUIStrings.string(
                "Close Tab",
                comment: "Generic accessibility description for the close-tab image, overridden per-tab below"
            )
        ) ?? NSImage(),
        target: nil,
        action: nil
    )
    private let trailingSeparator = NSView()
    private var tab: EditorTab?
    private var configuredSelection = false
    private var showsTrailingSeparator = false
    private var isSeparatorSuppressedForDrag = false
    private var isHovered = false
    private var isBeingDragged = false
    private var hoverTrackingArea: NSTrackingArea?
    private var onSelect: () -> Void = {}
    private var onClose: () -> Void = {}
    private var onPin: () -> Void = {}

    override func loadView() {
        let container = itemView
        container.wantsLayer = true
        container.onSetDraggingAppearance = { [weak self] in
            self?.setDraggingAppearance($0)
        }
        container.onSetDisplacement = { [weak self] x, duration in
            self?.setDisplacement(x: x, duration: duration)
        }
        container.onResetDisplacement = { [weak self] in
            self?.resetDisplacement()
        }
        container.onSetSeparatorSuppressedForDrag = { [weak self] in
            self?.setSeparatorSuppressedForDrag($0)
        }
        visualView.wantsLayer = true
        visualView.frame = container.bounds
        visualView.autoresizingMask = [.width, .height]

        selectionBackgroundView.wantsLayer = true
        selectionBackgroundView.layer?.cornerRadius = 13
        selectionBackgroundView.translatesAutoresizingMaskIntoConstraints = false

        titleButton.bezelStyle = .inline
        titleButton.isBordered = false
        titleButton.setButtonType(.momentaryPushIn)
        titleButton.alignment = .center
        titleButton.lineBreakMode = .byTruncatingMiddle
        titleButton.target = self
        titleButton.action = #selector(handleSelect)
        titleButton.translatesAutoresizingMaskIntoConstraints = false
        titleButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        fileIconView.imageScaling = .scaleProportionallyUpOrDown
        fileIconView.translatesAutoresizingMaskIntoConstraints = false
        fileIconView.setAccessibilityElement(false)

        for button in [pinButton, closeButton] {
            button.bezelStyle = .inline
            button.isBordered = false
            button.imageScaling = .scaleProportionallyDown
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        pinButton.image = pinButton.image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
        )
        closeButton.image = closeButton.image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
        )
        pinButton.target = self
        pinButton.action = #selector(handlePin)
        closeButton.target = self
        closeButton.action = #selector(handleClose)

        contentView.setViews([fileIconView, titleButton], in: .leading)
        contentView.orientation = .horizontal
        contentView.alignment = .centerY
        contentView.spacing = 3
        contentView.translatesAutoresizingMaskIntoConstraints = false

        trailingSeparator.wantsLayer = true
        trailingSeparator.identifier = NSUserInterfaceItemIdentifier("tab.separator")
        trailingSeparator.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.122).cgColor
        trailingSeparator.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(visualView)
        visualView.addSubview(selectionBackgroundView)
        visualView.addSubview(contentView)
        visualView.addSubview(closeButton)
        visualView.addSubview(pinButton)
        visualView.addSubview(trailingSeparator)
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        container.addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
        NSLayoutConstraint.activate([
            selectionBackgroundView.topAnchor.constraint(equalTo: visualView.topAnchor, constant: 3),
            selectionBackgroundView.leadingAnchor.constraint(equalTo: visualView.leadingAnchor, constant: 3),
            selectionBackgroundView.trailingAnchor.constraint(equalTo: visualView.trailingAnchor, constant: -3),
            selectionBackgroundView.bottomAnchor.constraint(equalTo: visualView.bottomAnchor, constant: -3),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
            closeButton.leadingAnchor.constraint(equalTo: visualView.leadingAnchor, constant: 7),
            closeButton.centerYAnchor.constraint(equalTo: visualView.centerYAnchor),
            fileIconView.widthAnchor.constraint(equalToConstant: 18),
            fileIconView.heightAnchor.constraint(equalToConstant: 18),
            contentView.centerXAnchor.constraint(equalTo: visualView.centerXAnchor),
            contentView.centerYAnchor.constraint(equalTo: visualView.centerYAnchor),
            contentView.leadingAnchor.constraint(greaterThanOrEqualTo: visualView.leadingAnchor, constant: 28),
            contentView.trailingAnchor.constraint(lessThanOrEqualTo: visualView.trailingAnchor, constant: -28),
            pinButton.widthAnchor.constraint(equalToConstant: 18),
            pinButton.heightAnchor.constraint(equalToConstant: 18),
            pinButton.trailingAnchor.constraint(equalTo: visualView.trailingAnchor, constant: -7),
            pinButton.centerYAnchor.constraint(equalTo: visualView.centerYAnchor),
            trailingSeparator.widthAnchor.constraint(equalToConstant: 1),
            trailingSeparator.topAnchor.constraint(equalTo: visualView.topAnchor, constant: 8),
            trailingSeparator.trailingAnchor.constraint(equalTo: visualView.trailingAnchor),
            trailingSeparator.bottomAnchor.constraint(equalTo: visualView.bottomAnchor, constant: -8)
        ])
        view = container
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applySelectionAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applySelectionAppearance()
    }

    override var isSelected: Bool {
        didSet {
            applySelectionAppearance()
        }
    }

    func configure(
        tab: EditorTab,
        isSelected: Bool,
        showsTrailingSeparator: Bool,
        onSelect: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onPin: @escaping () -> Void,
        onMouseDown: @escaping (NSEvent) -> Void,
        onMouseDragged: @escaping (NSEvent) -> Void,
        onMouseUp: @escaping (NSEvent) -> Void
    ) {
        _ = view
        self.tab = tab
        self.configuredSelection = isSelected
        self.showsTrailingSeparator = showsTrailingSeparator
        isSeparatorSuppressedForDrag = false
        isBeingDragged = false
        itemView.layer?.removeAllAnimations()
        itemView.layer?.zPosition = 0
        resetDisplacement()
        self.onSelect = onSelect
        self.onClose = onClose
        self.onPin = onPin
        itemView.tabID = tab.id
        itemView.onMouseDown = onMouseDown
        itemView.onMouseDragged = onMouseDragged
        itemView.onMouseUp = onMouseUp

        let displayName = (tab.relativePath as NSString).lastPathComponent
        let titleFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize + 2)
        titleButton.title = displayName
        titleButton.font = tab.isPinned
            ? titleFont
            : NSFontManager.shared.convert(titleFont, toHaveTrait: .italicFontMask)
        titleButton.toolTip = tab.relativePath
        view.toolTip = tab.relativePath
        titleButton.identifier = NSUserInterfaceItemIdentifier("tab.title.\(tab.relativePath)")
        titleButton.setAccessibilityLabel(displayName)
        titleButton.setAccessibilityValue(
            editorTabAccessibilityValue(tab: tab, isSelected: isSelected)
        )
        fileIconView.fileName = tab.relativePath
        fileIconView.identifier = NSUserInterfaceItemIdentifier("tab.icon.\(tab.relativePath)")
        contentView.identifier = NSUserInterfaceItemIdentifier("tab.content.\(tab.relativePath)")
        visualView.identifier = NSUserInterfaceItemIdentifier("tab.visual.\(tab.relativePath)")
        trailingSeparator.identifier = NSUserInterfaceItemIdentifier("tab.separator.\(tab.relativePath)")
        pinButton.isHidden = tab.isPinned || !isHovered
        pinButton.identifier = NSUserInterfaceItemIdentifier("tab.pin.\(tab.relativePath)")
        pinButton.setAccessibilityLabel(
            editorUIStrings.string(
                "Pin \(displayName)",
                comment: "Accessibility label for a tab chip's pin button, naming the specific file it pins"
            )
        )
        pinButton.toolTip = pinButton.accessibilityLabel()
        closeButton.identifier = NSUserInterfaceItemIdentifier("tab.close.\(tab.relativePath)")
        closeButton.setAccessibilityLabel(
            editorUIStrings.string(
                "Close \(displayName)",
                comment: "Accessibility label for a tab chip's close button, naming the specific file it closes"
            )
        )
        closeButton.toolTip = closeButton.accessibilityLabel()
        view.identifier = NSUserInterfaceItemIdentifier("tab.\(tab.relativePath)")
        applySelectionAppearance()
    }

    func setDraggingAppearance(_ isDragging: Bool) {
        isBeingDragged = isDragging
        view.layer?.zPosition = isDragging ? 1_000 : 0
        applySelectionAppearance()
    }

    func setSeparatorSuppressedForDrag(_ isSuppressed: Bool) {
        guard isSeparatorSuppressedForDrag != isSuppressed else {
            return
        }
        isSeparatorSuppressedForDrag = isSuppressed
        applySelectionAppearance()
    }

    func setDisplacement(x: CGFloat, duration: TimeInterval) {
        let targetFrame = NSRect(
            x: x,
            y: 0,
            width: itemView.bounds.width,
            height: itemView.bounds.height
        )
        guard visualView.frame != targetFrame else {
            return
        }
        guard duration > 0 else {
            visualView.frame = targetFrame
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            visualView.animator().frame = targetFrame
        }
    }

    func resetDisplacement() {
        visualView.layer?.removeAllAnimations()
        visualView.frame = itemView.bounds
    }

    private func applySelectionAppearance() {
        let selected = isSelected || configuredSelection
        if selected {
            let isDark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let component: CGFloat = isDark ? 0.27 : 250 / 255
            selectionBackgroundView.layer?.backgroundColor = NSColor(
                srgbRed: component,
                green: component,
                blue: component,
                alpha: 1
            ).cgColor
            selectionBackgroundView.layer?.shadowColor = NSColor.shadowColor.cgColor
            selectionBackgroundView.layer?.shadowOpacity = isBeingDragged ? 0.24 : 0.12
            selectionBackgroundView.layer?.shadowRadius = isBeingDragged ? 4 : 1
            selectionBackgroundView.layer?.shadowOffset = NSSize(
                width: 0,
                height: isBeingDragged ? -1 : -0.5
            )
        } else {
            selectionBackgroundView.layer?.backgroundColor = isHovered
                ? NSColor.labelColor.withAlphaComponent(0.06).cgColor
                : NSColor.clear.cgColor
            selectionBackgroundView.layer?.shadowOpacity = 0
        }
        trailingSeparator.isHidden = selected
            || !showsTrailingSeparator
            || isSeparatorSuppressedForDrag
        titleButton.contentTintColor = selected
            ? .labelColor
            : NSColor.labelColor.withAlphaComponent(0.78)
        fileIconView.isHidden = false
        closeButton.isHidden = !isHovered
        pinButton.isHidden = tab?.isPinned != false || !isHovered
        pinButton.contentTintColor = .secondaryLabelColor
        closeButton.contentTintColor = .secondaryLabelColor
        if let tab {
            titleButton.setAccessibilityValue(
                editorTabAccessibilityValue(tab: tab, isSelected: selected)
            )
        }
    }

    @objc
    private func handleSelect(_ sender: Any?) {
        onSelect()
    }

    @objc
    private func handleClose(_ sender: Any?) {
        onClose()
    }

    @objc
    private func handlePin(_ sender: Any?) {
        onPin()
    }
}
