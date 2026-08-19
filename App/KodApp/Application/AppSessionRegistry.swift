import AppKit
import WorkspaceCore

enum AppSessionKey: Hashable {
    case workspace(String)
    case document(URL)

    init(workspace identity: WorkspaceIdentity) {
        self = .workspace(identity.persistenceKey)
    }

    init(documentURL: URL) {
        self = .document(
            documentURL.standardizedFileURL.resolvingSymlinksInPath()
        )
    }
}

@MainActor
final class AppSessionRegistry {
    struct Factories {
        var makeWorkspaceWindowController: @MainActor (
            WorkspaceIdentity
        ) -> WorkspaceWindowController
        var makeDocumentWindowController: @MainActor (
            URL
        ) -> DocumentWindowController
        var presentError: @MainActor (any Error, NSWindow?) -> Void

        static func production(environment: AppEnvironment) -> Factories {
            Factories(
                makeWorkspaceWindowController: { identity in
                    let session = environment.makeWorkspaceSession(
                        identity: identity
                    )
                    return WorkspaceWindowController(
                        identity: identity,
                        session: session
                    )
                },
                makeDocumentWindowController: { url in
                    DocumentWindowController(
                        url: url,
                        services: .production(
                            languageSupportService:
                                environment.languageSupportService,
                            appearanceCenter: environment.appearanceCenter
                        )
                    )
                },
                presentError: { error, _ in
                    let alert = NSAlert(error: error)
                    alert.runModal()
                }
            )
        }
    }

    @MainActor
    private enum SessionController {
        case workspace(WorkspaceWindowController)
        case document(DocumentWindowController)

        var objectIdentifier: ObjectIdentifier {
            switch self {
            case .workspace(let controller):
                return ObjectIdentifier(controller)
            case .document(let controller):
                return ObjectIdentifier(controller)
            }
        }

        func focus() {
            switch self {
            case .workspace(let controller):
                controller.focusSessionWindow()
            case .document(let controller):
                controller.focusSessionWindow()
            }
        }

        func closeWindow() {
            switch self {
            case .workspace(let controller):
                controller.closeSessionWindow()
            case .document(let controller):
                controller.closeSessionWindow()
            }
        }

        func shutdown() async {
            switch self {
            case .workspace(let controller):
                await controller.shutdown()
            case .document(let controller):
                await controller.shutdown()
            }
        }
    }

    var onFirstSessionOpened: (() -> Void)?
    var onSessionSetChanged: (() -> Void)?
    var onShowLanguageSupportSettings: ((String?) -> Void)?

    private let factories: Factories
    private var active: [AppSessionKey: SessionController] = [:]
    private var closing: [ObjectIdentifier: SessionController] = [:]
    private var cleanupTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var shutdownAllTask: Task<Void, Never>?
    private var hasOpenedFirstSession = false
    private var isShuttingDown = false

    init(
        environment: AppEnvironment,
        factories: Factories? = nil
    ) {
        self.factories = factories ?? .production(environment: environment)
    }

    var activeSessionCount: Int {
        active.count
    }

    var closingSessionCount: Int {
        closing.count
    }

    var activeKeys: Set<AppSessionKey> {
        Set(active.keys)
    }

    func contains(_ key: AppSessionKey) -> Bool {
        active[key] != nil
    }

    func workspaceController(
        for key: AppSessionKey
    ) -> WorkspaceWindowController? {
        guard case .workspace(let controller) = active[key] else {
            return nil
        }
        return controller
    }

    func documentController(
        for key: AppSessionKey
    ) -> DocumentWindowController? {
        guard case .document(let controller) = active[key] else {
            return nil
        }
        return controller
    }

    @discardableResult
    func openWorkspace(_ identity: WorkspaceIdentity) -> Bool {
        guard !isShuttingDown else {
            return false
        }
        let key = AppSessionKey(workspace: identity)
        if let existing = active[key] {
            existing.focus()
            return true
        }

        let controller = factories.makeWorkspaceWindowController(identity)
        controller.workspaceViewController.onShowLanguageSupportSettings = {
            [weak self] profileIdentifier in
            self?.onShowLanguageSupportSettings?(profileIdentifier)
        }
        controller.onWindowWillClose = { [weak self, weak controller] _ in
            guard let self, let controller else {
                return
            }
            self.controllerWillClose(
                .workspace(controller),
                key: key
            )
        }
        active[key] = .workspace(controller)
        controller.showSessionWindow()
        sessionOpenedSuccessfully()
        onSessionSetChanged?()
        return true
    }

    @discardableResult
    func openDocument(at url: URL) async -> Bool {
        guard !isShuttingDown else {
            return false
        }
        let key = AppSessionKey(documentURL: url)
        if let existing = active[key] {
            existing.focus()
            return true
        }

        let canonicalURL: URL
        guard case .document(let value) = key else {
            return false
        }
        canonicalURL = value
        let controller = factories.makeDocumentWindowController(canonicalURL)
        controller.onWindowWillClose = { [weak self, weak controller] _ in
            guard let self, let controller else {
                return
            }
            self.controllerWillClose(
                .document(controller),
                key: key
            )
        }
        active[key] = .document(controller)
        onSessionSetChanged?()

        do {
            try await controller.loadAndShow()
            guard isActive(.document(controller), for: key) else {
                return false
            }
            sessionOpenedSuccessfully()
            return true
        } catch {
            let session = SessionController.document(controller)
            if isActive(session, for: key) {
                beginClosing(session, key: key, closeWindow: true)
            }
            if !(error is CancellationError) {
                factories.presentError(error, controller.window)
            }
            return false
        }
    }

    func shutdownAll() async {
        if let shutdownAllTask {
            await shutdownAllTask.value
            return
        }
        isShuttingDown = true
        let task = Task { @MainActor [self] in
            let sessions = active
            for (key, session) in sessions {
                beginClosing(session, key: key, closeWindow: true)
            }
            while !cleanupTasks.isEmpty {
                let tasks = Array(cleanupTasks.values)
                for task in tasks {
                    await task.value
                }
            }
        }
        shutdownAllTask = task
        await task.value
    }

    private func sessionOpenedSuccessfully() {
        guard !hasOpenedFirstSession else {
            return
        }
        hasOpenedFirstSession = true
        onFirstSessionOpened?()
    }

    private func controllerWillClose(
        _ session: SessionController,
        key: AppSessionKey
    ) {
        guard isActive(session, for: key) else {
            return
        }
        beginClosing(session, key: key, closeWindow: false)
    }

    private func beginClosing(
        _ session: SessionController,
        key: AppSessionKey,
        closeWindow: Bool
    ) {
        let identifier = session.objectIdentifier
        if isActive(session, for: key) {
            active.removeValue(forKey: key)
            onSessionSetChanged?()
        }
        closing[identifier] = session
        if cleanupTasks[identifier] == nil {
            let task = Task { @MainActor [weak self] in
                await session.shutdown()
                self?.finishClosing(identifier)
            }
            cleanupTasks[identifier] = task
        }
        if closeWindow {
            session.closeWindow()
        }
    }

    private func finishClosing(_ identifier: ObjectIdentifier) {
        cleanupTasks.removeValue(forKey: identifier)
        closing.removeValue(forKey: identifier)
    }

    private func isActive(
        _ session: SessionController,
        for key: AppSessionKey
    ) -> Bool {
        active[key]?.objectIdentifier == session.objectIdentifier
    }
}
