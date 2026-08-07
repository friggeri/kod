import AppKit
import CodeViewport
import SourceModel

/// Wraps `CodeDocumentViewController` for the single-file (non-workspace)
/// window path so Find in File, Go to Line, and Word Wrap share the same
/// menu actions as workspace windows, without `CodeViewport`'s package
/// needing to depend on any App-layer panel type.
@MainActor
final class StandaloneDocumentViewController: NSViewController {
    private let documentController: CodeDocumentViewController
    private var goToLinePanelController: GoToLinePanelController?
    private var wordWrapEnabled = false {
        didSet { documentController.wordWrapEnabled = wordWrapEnabled }
    }

    init(snapshot: SourceSnapshot) {
        documentController = CodeDocumentViewController(
            snapshot: snapshot,
            theme: AppearanceSettings.currentTheme(),
            fontSettings: AppearanceSettings.currentFontSettings()
        )
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceSettingsDidChange),
            name: .kodAppearanceSettingsChanged,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func appearanceSettingsDidChange() {
        documentController.theme = AppearanceSettings.currentTheme()
        documentController.fontSettings = AppearanceSettings.currentFontSettings()
    }

    override func loadView() {
        addChild(documentController)
        view = documentController.view
    }

    @objc
    func findInFile(_ sender: Any?) {
        documentController.toggleFindBar()
    }

    @objc
    func showGoToLinePanel(_ sender: Any?) {
        guard let window = view.window else {
            return
        }
        let controller = GoToLinePanelController(onSubmit: { [weak self] line in
            self?.documentController.goToLine(line)
        })
        goToLinePanelController = controller
        controller.show(asSheetFor: window)
    }

    @objc
    func toggleWordWrap(_ sender: Any?) {
        wordWrapEnabled.toggle()
    }

    /// Cmd-W has no "tab" to close outside a workspace, so it falls back to
    /// closing the window (matching ordinary single-document apps).
    @objc
    func closeActiveTab(_ sender: Any?) {
        view.window?.performClose(sender)
    }
}

extension StandaloneDocumentViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleWordWrap(_:)) {
            menuItem.state = wordWrapEnabled ? .on : .off
        }
        return true
    }
}
