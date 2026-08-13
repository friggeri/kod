import AppKit
import CodeViewport
import LanguageAdapters
import SourceModel
import SyntaxCore

/// Wraps `CodeDocumentViewController` for the single-file (non-workspace)
/// window path so Find in File, Go to Line, and Word Wrap share the same
/// menu actions as workspace windows, without `CodeViewport`'s package
/// needing to depend on any App-layer panel type.
@MainActor
final class StandaloneDocumentViewController: NSViewController {
    private var documentController: CodeDocumentViewController
    private let languageSupportService: LanguageSupportService
    private var goToLinePanelController: GoToLinePanelController?
    private var wordWrapEnabled = false {
        didSet { documentController.wordWrapEnabled = wordWrapEnabled }
    }
    private var minimapEnabled = true {
        didSet { documentController.minimapEnabled = minimapEnabled }
    }

    init(
        snapshot: SourceSnapshot,
        languageSupportService: LanguageSupportService
    ) {
        self.languageSupportService = languageSupportService
        documentController = CodeDocumentViewController(
            snapshot: snapshot,
            syntaxLanguage: languageSupportService.syntaxLanguage(
                for: snapshot
            ),
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageProfilesDidChange(_:)),
            name: .kodLanguageProfilesDidChange,
            object: languageSupportService.profileStore
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

    @objc
    private func languageProfilesDidChange(_ notification: Notification) {
        languageSupportService.profileRegistry.reload()
        let syntaxLanguage = languageSupportService.syntaxLanguage(
            for: documentController.snapshot
        )
        guard syntaxLanguage != documentController.viewport.language else {
            return
        }

        let oldController = documentController
        let anchor = oldController.captureNavigationAnchor()
        let foldedHeaderLines =
            oldController.viewport.foldedHeaderLinesSnapshot()
        let findState = oldController.captureFindState()
        let wasViewportFirstResponder =
            oldController.view.window?.firstResponder
                === oldController.viewport
        let replacement = CodeDocumentViewController(
            snapshot: oldController.snapshot,
            syntaxLanguage: syntaxLanguage,
            theme: oldController.theme,
            fontSettings: oldController.fontSettings
        )
        replacement.wordWrapEnabled = wordWrapEnabled
        replacement.minimapEnabled = minimapEnabled
        replacement.viewport.restoreFoldedHeaderLines(foldedHeaderLines)

        if isViewLoaded {
            oldController.view.removeFromSuperview()
            oldController.removeFromParent()
            installDocumentController(replacement)
            replacement.restoreFindState(findState)
            view.window?.layoutIfNeeded()
            replacement.restoreNavigationAnchor(
                selection: anchor.selection,
                viewportAnchorLine: anchor.viewportAnchorLine
            )
            if wasViewportFirstResponder {
                view.window?.makeFirstResponder(replacement.viewport)
            }
        }
        documentController = replacement
    }

    var syntaxLanguage: SyntaxLanguage? {
        documentController.viewport.language
    }

    override func loadView() {
        view = NSView()
        installDocumentController(documentController)
    }

    private func installDocumentController(
        _ controller: CodeDocumentViewController
    ) {
        addChild(controller)
        let documentView = controller.view
        documentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(documentView)
        NSLayoutConstraint.activate([
            documentView.topAnchor.constraint(equalTo: view.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            documentView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
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

    @objc
    func toggleMinimap(_ sender: Any?) {
        minimapEnabled.toggle()
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
        } else if menuItem.action == #selector(toggleMinimap(_:)) {
            menuItem.state = minimapEnabled ? .on : .off
        }
        return true
    }
}
