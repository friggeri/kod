import AppKit

@MainActor
open class KodSymbolButton: NSButton {
    public enum NavigationDirection: Equatable {
        case previous
        case next
    }

    public var onDirectionalNavigation: ((NavigationDirection) -> Void)?

    public var showsHoverBackground = false {
        didSet {
            updateAppearance()
        }
    }

    public var isSelectedStyle = false {
        didSet {
            updateAppearance()
        }
    }

    private var isHovered = false
    private var hoverTrackingArea: NSTrackingArea?

    open override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    public init(
        systemSymbolName: String,
        accessibilityLabel: String,
        pointSize: CGFloat = 14,
        weight: NSFont.Weight = .regular,
        target: AnyObject? = nil,
        action: Selector? = nil
    ) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        bezelStyle = .inline
        isBordered = false
        imagePosition = .imageOnly
        focusRingType = .exterior
        wantsLayer = true
        layer?.cornerRadius = 6
        setSymbol(
            systemSymbolName,
            accessibilityDescription: accessibilityLabel,
            pointSize: pointSize,
            weight: weight
        )
        toolTip = accessibilityLabel
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityRole(.button)
        updateAppearance()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public func setSymbol(
        _ systemSymbolName: String,
        accessibilityDescription: String,
        pointSize: CGFloat = 14,
        weight: NSFont.Weight = .regular
    ) {
        image = NSImage(
            systemSymbolName: systemSymbolName,
            accessibilityDescription: accessibilityDescription
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        )
    }

    open override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        hoverTrackingArea = trackingArea
        addTrackingArea(trackingArea)
    }

    open override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    open override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance()
    }

    open override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        updateAppearance()
        return accepted
    }

    open override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        layer?.borderWidth = 0
        layer?.borderColor = NSColor.clear.cgColor
        DispatchQueue.main.async { [weak self] in
            self?.updateAppearance()
        }
        return resigned
    }

    open override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    open override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 126:
            onDirectionalNavigation?(.previous)
        case 124, 125:
            onDirectionalNavigation?(.next)
        case 36, 76:
            performClick(nil)
        default:
            super.keyDown(with: event)
        }
    }

    private func updateAppearance() {
        contentTintColor = isSelectedStyle ? .labelColor : .secondaryLabelColor
        if isSelectedStyle {
            layer?.backgroundColor = NSColor.selectedContentBackgroundColor
                .withAlphaComponent(0.18)
                .cgColor
        } else if isHovered, showsHoverBackground {
            layer?.backgroundColor = NSColor.labelColor
                .withAlphaComponent(0.08)
                .cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        let emphasizeFocus = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            && window?.firstResponder === self
        layer?.borderWidth = emphasizeFocus ? 1 : 0
        layer?.borderColor = emphasizeFocus
            ? NSColor.keyboardFocusIndicatorColor.cgColor
            : NSColor.clear.cgColor
    }
}
