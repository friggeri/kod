import AppKit

/// A small sheet prompting for a 1-based line number, modeled on
/// `QuickOpenPanelController`'s sheet-panel pattern.
@MainActor
final class GoToLinePanelController: NSWindowController {
    private let onSubmit: (Int) -> Void
    private let lineField = NSTextField()

    init(onSubmit: @escaping (Int) -> Void) {
        self.onSubmit = onSubmit

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = Localized.string("Go to Line", comment: "Title of the Go to Line panel window")
        panel.isReleasedWhenClosed = false

        super.init(window: panel)
        panel.contentViewController = makeContentViewController()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show(asSheetFor parent: NSWindow) {
        guard let window else {
            return
        }
        parent.beginSheet(window)
        window.makeFirstResponder(lineField)
    }

    private func makeContentViewController() -> NSViewController {
        let controller = NSViewController()
        let container = NSView()

        let label = NSTextField(labelWithString: Localized.string("Line number:", comment: "Label preceding the line-number field in the Go to Line panel"))
        label.translatesAutoresizingMaskIntoConstraints = false

        lineField.identifier = NSUserInterfaceItemIdentifier("goToLine.field")
        lineField.placeholderString = "1"
        lineField.delegate = self
        lineField.translatesAutoresizingMaskIntoConstraints = false

        let goButton = NSButton(
            title: Localized.string("Go", comment: "Submit button title in the Go to Line panel"),
            target: self,
            action: #selector(handleSubmit)
        )
        goButton.identifier = NSUserInterfaceItemIdentifier("goToLine.submit")
        goButton.keyEquivalent = "\r"

        let cancelButton = NSButton(
            title: Localized.string("Cancel", comment: "Cancel button title in the Go to Line panel"),
            target: self,
            action: #selector(handleCancel)
        )
        cancelButton.identifier = NSUserInterfaceItemIdentifier("goToLine.cancel")
        cancelButton.keyEquivalent = "\u{1b}"

        let buttonRow = NSStackView(views: [cancelButton, goButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(label)
        container.addSubview(lineField)
        container.addSubview(buttonRow)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            lineField.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            lineField.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            lineField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            buttonRow.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16),
            buttonRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            buttonRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
        ])

        controller.view = container
        return controller
    }

    @objc
    private func handleSubmit(_ sender: Any?) {
        guard let line = Int(lineField.stringValue), line > 0,
              let window,
              let parent = window.sheetParent else {
            return
        }
        parent.endSheet(window)
        onSubmit(line)
    }

    @objc
    private func handleCancel(_ sender: Any?) {
        guard let window, let parent = window.sheetParent else {
            return
        }
        parent.endSheet(window)
    }
}

extension GoToLinePanelController: NSTextFieldDelegate {
    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            handleSubmit(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            handleCancel(nil)
            return true
        default:
            return false
        }
    }
}
