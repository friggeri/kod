import AppKit
import KodUIComponents
import WorkspaceCore

@MainActor
final class WorkspaceActivityBarView: NSView {
    static let orderedSurfaces: [WorkspaceSidebarSurface] = [
        .explorer,
        .search,
        .sourceControl,
        .problems
    ]

    var onSelectSurface: ((WorkspaceSidebarSurface) -> Void)?

    private(set) var selectedSurface: WorkspaceSidebarSurface = .explorer
    private var buttons: [WorkspaceSidebarSurface: KodSymbolButton] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("workspace.activityBar")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(
            Localized.string(
                "Activity",
                comment: "Accessibility label for the workspace activity bar"
            )
        )

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        for surface in Self.orderedSurfaces {
            let item = makeItem(for: surface)
            stack.addArrangedSubview(item)
        }

        addSubview(stack)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 40),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4)
        ])
        configureKeyViewOrder()
        updateSelection()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func setSelectedSurface(_ surface: WorkspaceSidebarSurface) {
        selectedSurface = surface
        updateSelection()
    }

    func button(for surface: WorkspaceSidebarSurface) -> KodSymbolButton? {
        buttons[surface]
    }

    func focusSelectedButton() {
        guard let button = buttons[selectedSurface] else {
            return
        }
        window?.makeFirstResponder(button)
    }

    func setNextKeyViewAfterBar(_ view: NSView?) {
        buttons[Self.orderedSurfaces.last ?? .problems]?.nextKeyView = view
    }

    private func makeItem(for surface: WorkspaceSidebarSurface) -> NSView {
        let descriptor = descriptor(for: surface)
        let button = KodSymbolButton(
            systemSymbolName: descriptor.symbolName,
            accessibilityLabel: descriptor.label,
            pointSize: 14,
            target: self,
            action: #selector(selectSurface(_:))
        )
        button.identifier = NSUserInterfaceItemIdentifier(
            "workspace.activity.\(surface.rawValue)"
        )
        button.tag = Self.orderedSurfaces.firstIndex(of: surface) ?? 0
        button.showsHoverBackground = true
        button.setAccessibilityHelp(descriptor.help)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.onDirectionalNavigation = { [weak self, weak button] direction in
            guard let self, let button else {
                return
            }
            self.moveFocus(from: button, direction: direction)
        }

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28)
        ])

        buttons[surface] = button
        return button
    }

    private func configureKeyViewOrder() {
        let orderedButtons = Self.orderedSurfaces.compactMap { buttons[$0] }
        for (button, nextButton) in zip(orderedButtons, orderedButtons.dropFirst()) {
            button.nextKeyView = nextButton
        }
    }

    @objc
    private func selectSurface(_ sender: KodSymbolButton) {
        guard Self.orderedSurfaces.indices.contains(sender.tag) else {
            return
        }
        onSelectSurface?(Self.orderedSurfaces[sender.tag])
    }

    private func moveFocus(
        from button: KodSymbolButton,
        direction: KodSymbolButton.NavigationDirection
    ) {
        guard let currentIndex = Self.orderedSurfaces.firstIndex(where: {
            buttons[$0] === button
        }) else {
            return
        }
        let delta = direction == .previous ? -1 : 1
        let nextIndex = (
            currentIndex + delta + Self.orderedSurfaces.count
        ) % Self.orderedSurfaces.count
        guard let nextButton = buttons[Self.orderedSurfaces[nextIndex]] else {
            return
        }
        window?.makeFirstResponder(nextButton)
    }

    private func updateSelection() {
        let selectedValue = Localized.string(
            "Selected",
            comment: "Accessibility value for the selected activity bar destination"
        )
        let notSelectedValue = Localized.string(
            "Not selected",
            comment: "Accessibility value for an unselected activity bar destination"
        )
        for surface in Self.orderedSurfaces {
            let isSelected = surface == selectedSurface
            buttons[surface]?.isSelectedStyle = isSelected
            buttons[surface]?.setAccessibilityValue(
                isSelected ? selectedValue : notSelectedValue
            )
        }
        setAccessibilityValue(descriptor(for: selectedSurface).label)
    }

    private func descriptor(
        for surface: WorkspaceSidebarSurface
    ) -> (symbolName: String, label: String, help: String) {
        switch surface {
        case .explorer:
            let label = Localized.string(
                "Explorer",
                comment: "Activity bar destination for the file Explorer"
            )
            return ("doc.on.doc", label, label)
        case .search:
            let label = Localized.string(
                "Search",
                comment: "Activity bar destination for workspace Search"
            )
            return (
                "magnifyingglass",
                label,
                Localized.string(
                    "Search Workspace, Command-Shift-F",
                    comment: "Accessibility help for the Search activity bar destination"
                )
            )
        case .sourceControl:
            let label = Localized.string(
                "Source Control",
                comment: "Activity bar destination for Source Control"
            )
            return (
                "arrow.triangle.branch",
                label,
                Localized.string(
                    "Show Source Control, Command-Shift-G",
                    comment: "Accessibility help for the Source Control activity bar destination"
                )
            )
        case .problems:
            let label = Localized.string(
                "Problems",
                comment: "Activity bar destination for workspace Problems"
            )
            return ("exclamationmark.triangle", label, label)
        }
    }
}
