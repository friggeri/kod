import AppKit
import CodeViewport
import FontCore
import KodUIComponents
import LanguageAdapters
import SettingsCore
import SourceModel
import SyntaxCore
import ThemeCore

@MainActor
private final class StandaloneDocumentRootView: NSView {
    var onEffectiveAppearanceChanged: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChanged?()
    }
}

/// Wraps `CodeDocumentViewController` for the single-file (non-workspace)
/// window path so Find in File, Go to Line, and Word Wrap share the same
/// menu actions as workspace windows, without `CodeViewport`'s package
/// needing to depend on any App-layer panel type.
@MainActor
final class StandaloneDocumentViewController: NSViewController {
    private var documentController: CodeDocumentViewController
    private let languageSupportService: LanguageSupportService
    private let appearanceCenter: AppearanceCenter
    private var appearanceObservation: SettingsObservation?
    private var profileObservation: SettingsObservation?
    private var goToLinePanelController: GoToLinePanelController?
    private var wordWrapEnabled = false {
        didSet { documentController.wordWrapEnabled = wordWrapEnabled }
    }
    private var minimapEnabled = true {
        didSet { documentController.minimapEnabled = minimapEnabled }
    }

    init(
        snapshot: SourceSnapshot,
        languageSupportService: LanguageSupportService,
        appearanceCenter: AppearanceCenter
    ) {
        self.languageSupportService = languageSupportService
        self.appearanceCenter = appearanceCenter
        let appearance = appearanceCenter.snapshot
        documentController = CodeDocumentViewController(
            snapshot: snapshot,
            syntaxLanguage: languageSupportService.syntaxLanguage(
                for: snapshot
            ),
            theme: appearance.theme,
            fontSettings: appearance.fontSettings
        )
        super.init(nibName: nil, bundle: nil)
        appearanceObservation = appearanceCenter.observe {
            [weak self] snapshot in
            self?.applyAppearance(snapshot)
        }
        profileObservation = languageSupportService.profileRegistry
            .observeChanges { [weak self] in
                self?.languageProfilesDidChange()
            }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func applyAppearance(_ snapshot: AppearanceCenter.Snapshot) {
        documentController.theme = snapshot.theme
        documentController.fontSettings = snapshot.fontSettings
    }

    private func languageProfilesDidChange() {
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
        let rootView = StandaloneDocumentRootView()
        rootView.onEffectiveAppearanceChanged = { [weak self] in
            self?.appearanceCenter.refresh()
        }
        view = rootView
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
