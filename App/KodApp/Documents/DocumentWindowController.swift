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
        var loadIgnoringByteLimit: @MainActor (URL) async throws ->
            SourceSnapshot = { _ in throw CancellationError() }
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
            let loader = SourceSnapshotLoader(
                renderingSafetyPolicy: .codeViewportDefault
            )
            return Services(
                load: { url in
                    try await loader.loadDetached(url: url)
                },
                loadIgnoringByteLimit: { url in
                    try await loader.loadIgnoringByteLimitDetached(url: url)
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
                    if !UITestWindowGeometry.apply(to: window) {
                        window.center()
                    }
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
    var oversizedFileLoadConfirmation: ((URL, Int, Int) -> Bool)?
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
        let loadingController = Self.makeLoadingViewController(
            filename: documentURL.lastPathComponent
        )
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
            // The guarded read, the user's answer to the oversized
            // question, and the unrestricted retry are one task, not
            // three awaits with the handle dropped in between. Clearing
            // `loadTask` before the retry (as this once did) meant
            // `shutdown()` had nothing left to cancel or await, so
            // closing the window walked away from a read of the largest
            // file the app ever opens while it was still running.
            task = Task { @MainActor [weak self] in
                guard let self else {
                    throw CancellationError()
                }
                return try await self.loadAskingBeforeExceedingTheByteLimit()
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

    /// The full open-a-file flow, start to finish, inside the caller's
    /// task: read within the safety limit, and if the file is above it,
    /// ask the user once and read it in full only if they say yes.
    private func loadAskingBeforeExceedingTheByteLimit() async throws -> SourceSnapshot {
        do {
            return try await services.load(documentURL)
        } catch SourceIOError.fileExceedsRenderingByteLimit(
            let url,
            let byteCount,
            let limit
        ) {
            // Never put a modal question in front of the user for a
            // window that is already closing or a load already abandoned.
            try Task.checkCancellation()
            guard !isShuttingDown else {
                throw CancellationError()
            }
            guard confirmLoadingOversizedFile(
                url: url,
                byteCount: byteCount,
                limit: limit
            ) else {
                throw CancellationError()
            }
            try Task.checkCancellation()
            return try await services.loadIgnoringByteLimit(url)
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

    private func confirmLoadingOversizedFile(
        url: URL,
        byteCount: Int,
        limit: Int
    ) -> Bool {
        if let oversizedFileLoadConfirmation {
            return oversizedFileLoadConfirmation(url, byteCount, limit)
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Localized.string(
            "Open Large File?",
            comment: "Confirmation title before loading an oversized standalone source file"
        )
        alert.informativeText = Localized.string(
            "\(url.lastPathComponent) is \(Self.formattedByteCount(byteCount)), above Kod's \(Self.formattedByteCount(limit)) safety limit. Loading it may use substantial memory.",
            comment: "Confirmation detail before loading an oversized standalone source file"
        )
        alert.addButton(
            withTitle: Localized.string(
                "Load Anyway",
                comment: "Confirmation button that loads an oversized source file"
            )
        )
        alert.addButton(
            withTitle: Localized.string(
                "Cancel",
                comment: "Button that cancels loading an oversized source file"
            )
        )
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func formattedByteCount(_ count: Int) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(count),
            countStyle: .file
        )
    }

    static func makeLoadingViewController(filename: String) -> NSViewController {
        let controller = NSViewController()
        let view = NSView()
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .regular
        indicator.setAccessibilityElement(false)
        indicator.startAnimation(nil)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        let status = NSTextField(
            labelWithString: Localized.string(
                "Opening \(filename)...",
                comment: "Visible and accessible status shown while a standalone file is opening"
            )
        )
        status.identifier = NSUserInterfaceItemIdentifier("document.loadingStatus")
        status.alignment = .center
        status.setAccessibilityElement(true)
        status.setAccessibilityRole(.staticText)
        status.setAccessibilityLabel(status.stringValue)
        status.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [indicator, status])
        stack.identifier = NSUserInterfaceItemIdentifier("document.loading")
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        controller.view = view
        return controller
    }
}
