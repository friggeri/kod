import AppKit
import FontCore
import KodUIComponents
import SourceIO
import SourceModel
import ThemeCore

@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    struct Services {
        var load: @MainActor (URL) async throws -> SourceSnapshot
        var makeContentViewController: @MainActor (
            SourceSnapshot
        ) throws -> StandaloneDocumentViewController
        var makeWindow: @MainActor (NSViewController) -> NSWindow
        var present: @MainActor (NSWindowController) -> Void
        var focus: @MainActor (NSWindow) -> Void
        var activate: @MainActor () -> Void

        static func production(
            languageSupportService: LanguageSupportService,
            appearanceCenter: AppearanceCenter
        ) -> Services {
            Services(
                load: { url in
                    try await Task.detached(priority: .userInitiated) {
                        try SourceSnapshotLoader(
                            renderingSafetyPolicy: .codeViewportDefault
                        ).load(url: url)
                    }.value
                },
                makeContentViewController: { snapshot in
                    StandaloneDocumentViewController(
                        snapshot: snapshot,
                        languageSupportService: languageSupportService,
                        appearanceCenter: appearanceCenter
                    )
                },
                makeWindow: { contentViewController in
                    let window = NSWindow(
                        contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                        styleMask: [.titled, .closable, .miniaturizable, .resizable],
                        backing: .buffered,
                        defer: false
                    )
                    window.contentViewController = contentViewController
                    window.minSize = NSSize(width: 640, height: 420)
                    window.center()
                    return window
                },
                present: { $0.showWindow(nil) },
                focus: { $0.makeKeyAndOrderFront(nil) },
                activate: { NSApp.activate(ignoringOtherApps: true) }
            )
        }
    }

    let documentURL: URL
    var onWindowWillClose: ((DocumentWindowController) -> Void)?
    private(set) var contentController: StandaloneDocumentViewController?

    private let services: Services
    private var loadTask: Task<SourceSnapshot, any Error>?
    private var hasPresented = false
    private var didFinishLoading = false
    private var isShuttingDown = false
    private var shutdownTask: Task<Void, Never>?

    init(url: URL, services: Services) {
        documentURL = url.standardizedFileURL.resolvingSymlinksInPath()
        self.services = services
        let loadingController = Self.makeLoadingViewController()
        let window = services.makeWindow(loadingController)
        super.init(window: window)
        window.identifier = NSUserInterfaceItemIdentifier(
            "document.window.\(documentURL.path)"
        )
        window.title = documentURL.lastPathComponent
        window.isReleasedWhenClosed = false
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func loadAndShow() async throws {
        if didFinishLoading {
            focusSessionWindow()
            return
        }
        showLoadingWindowIfNeeded()
        let task: Task<SourceSnapshot, any Error>
        if let loadTask {
            task = loadTask
        } else {
            task = Task { [services, documentURL] in
                try await services.load(documentURL)
            }
            loadTask = task
        }

        let snapshot = try await task.value
        try Task.checkCancellation()
        guard !isShuttingDown else {
            throw CancellationError()
        }
        if !didFinishLoading {
            let controller = try services.makeContentViewController(snapshot)
            contentController = controller
            window?.contentViewController = controller
            window?.title = documentURL.lastPathComponent
            window?.layoutIfNeeded()
            didFinishLoading = true
            loadTask = nil
        }
    }

    func focusSessionWindow() {
        guard let window else {
            return
        }
        services.focus(window)
        services.activate()
    }

    func closeSessionWindow() {
        window?.close()
    }

    func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        let task = Task { @MainActor [self] in
            await performShutdown()
        }
        shutdownTask = task
        await task.value
    }

    private func performShutdown() async {
        isShuttingDown = true
        let task = loadTask
        loadTask = nil
        task?.cancel()
        if let task {
            _ = try? await task.value
        }
    }

    func windowWillClose(_ notification: Notification) {
        onWindowWillClose?(self)
    }

    private func showLoadingWindowIfNeeded() {
        guard !hasPresented else {
            return
        }
        hasPresented = true
        services.present(self)
        services.activate()
    }

    private static func makeLoadingViewController() -> NSViewController {
        let controller = NSViewController()
        let view = NSView()
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .regular
        indicator.startAnimation(nil)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        controller.view = view
        return controller
    }
}
