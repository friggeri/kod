import AppKit
import SourceModel
import WorkspaceCore
import XCTest
@testable import Kod

@MainActor
final class AppSessionRegistryTests: XCTestCase {
    func testDistinctKeysCoexistAndCanonicalDuplicatesFocusExistingWindows()
        async throws {
        let fixture = try KodAppTestEnvironment.make(in: self)
        let recorder = RegistryRecorder()
        let registry = makeRegistry(
            environment: fixture.environment,
            recorder: recorder
        )
        let firstRoot = try makeDirectory()
        let secondRoot = try makeDirectory()
        let firstIdentity = try WorkspaceIdentity(root: firstRoot)
        let duplicateIdentity = try WorkspaceIdentity(
            root: firstRoot.appendingPathComponent(".")
        )
        let secondIdentity = try WorkspaceIdentity(root: secondRoot)
        let file = try makeFile(in: firstRoot, name: "first.swift")
        let duplicateFile = firstRoot
            .appendingPathComponent("child")
            .appendingPathComponent("..")
            .appendingPathComponent("first.swift")
        let otherFile = try makeFile(in: secondRoot, name: "second.swift")

        XCTAssertTrue(registry.openWorkspace(firstIdentity))
        XCTAssertTrue(registry.openWorkspace(duplicateIdentity))
        XCTAssertTrue(registry.openWorkspace(secondIdentity))
        let openedFile = await registry.openDocument(at: file)
        let reusedFile = await registry.openDocument(at: duplicateFile)
        let openedOtherFile = await registry.openDocument(at: otherFile)
        XCTAssertTrue(openedFile)
        XCTAssertTrue(reusedFile)
        XCTAssertTrue(openedOtherFile)

        XCTAssertEqual(recorder.workspaceControllers.count, 2)
        XCTAssertEqual(recorder.documentControllers.count, 2)
        XCTAssertEqual(recorder.workspaceFocusCount, 1)
        XCTAssertEqual(recorder.documentFocusCount, 1)
        XCTAssertEqual(registry.activeSessionCount, 4)
        XCTAssertEqual(
            registry.activeKeys,
            [
                AppSessionKey(workspace: firstIdentity),
                AppSessionKey(workspace: secondIdentity),
                AppSessionKey(documentURL: file),
                AppSessionKey(documentURL: otherFile)
            ]
        )
    }

    func testWelcomeClosesOnlyAfterFirstSuccessfulSession() throws {
        let fixture = try KodAppTestEnvironment.make(in: self)
        let recorder = RegistryRecorder()
        let registry = makeRegistry(
            environment: fixture.environment,
            recorder: recorder
        )
        let delegate = AppDelegate(
            environment: fixture.environment,
            sessionRegistry: registry
        )
        delegate.showWelcomeWindow()
        XCTAssertNotNil(delegate.welcomeWindowController)

        XCTAssertTrue(
            registry.openWorkspace(
                try WorkspaceIdentity(root: makeDirectory())
            )
        )

        XCTAssertNil(delegate.welcomeWindowController)
    }

    func testClosingRemovesActiveImmediatelyButRetainsUntilShutdownFinishes()
        async throws {
        let fixture = try KodAppTestEnvironment.make(in: self)
        let recorder = RegistryRecorder()
        let gate = RegistryShutdownGate()
        recorder.shutdownGate = gate
        let registry = makeRegistry(
            environment: fixture.environment,
            recorder: recorder
        )
        let identity = try WorkspaceIdentity(root: makeDirectory())
        XCTAssertTrue(registry.openWorkspace(identity))
        let controller = try XCTUnwrap(
            registry.workspaceController(
                for: AppSessionKey(workspace: identity)
            )
        )

        controller.windowWillClose(
            Notification(name: NSWindow.willCloseNotification)
        )

        XCTAssertEqual(registry.activeSessionCount, 0)
        XCTAssertEqual(registry.closingSessionCount, 1)
        await gate.waitUntilEntered()
        XCTAssertEqual(recorder.workspaceShutdownCount, 1)
        gate.open()
        await registry.shutdownAll()
        XCTAssertEqual(registry.closingSessionCount, 0)
    }

    func testOneWindowCloseLeavesOtherSessionActive() throws {
        let fixture = try KodAppTestEnvironment.make(in: self)
        let recorder = RegistryRecorder()
        let registry = makeRegistry(
            environment: fixture.environment,
            recorder: recorder
        )
        let first = try WorkspaceIdentity(root: makeDirectory())
        let second = try WorkspaceIdentity(root: makeDirectory())
        XCTAssertTrue(registry.openWorkspace(first))
        XCTAssertTrue(registry.openWorkspace(second))
        let firstController = try XCTUnwrap(
            registry.workspaceController(
                for: AppSessionKey(workspace: first)
            )
        )

        firstController.windowWillClose(
            Notification(name: NSWindow.willCloseNotification)
        )

        XCTAssertFalse(registry.contains(AppSessionKey(workspace: first)))
        XCTAssertTrue(registry.contains(AppSessionKey(workspace: second)))
        XCTAssertEqual(registry.activeSessionCount, 1)
    }

    func testConcurrentShutdownAllJoinsOneCleanup() async throws {
        let fixture = try KodAppTestEnvironment.make(in: self)
        let recorder = RegistryRecorder()
        let gate = RegistryShutdownGate()
        recorder.shutdownGate = gate
        let registry = makeRegistry(
            environment: fixture.environment,
            recorder: recorder
        )
        XCTAssertTrue(
            registry.openWorkspace(
                try WorkspaceIdentity(root: makeDirectory())
            )
        )

        let first = Task { @MainActor in await registry.shutdownAll() }
        let second = Task { @MainActor in await registry.shutdownAll() }
        await gate.waitUntilEntered()
        XCTAssertEqual(recorder.workspaceShutdownCount, 1)
        gate.open()
        _ = await (first.value, second.value)

        XCTAssertEqual(recorder.workspaceShutdownCount, 1)
        XCTAssertEqual(registry.activeSessionCount, 0)
        XCTAssertEqual(registry.closingSessionCount, 0)
    }

    func testConcurrentTerminationRequestsJoinAndReplyAfterCleanup()
        async throws {
        let fixture = try KodAppTestEnvironment.make(in: self)
        let recorder = RegistryRecorder()
        let gate = RegistryShutdownGate()
        recorder.shutdownGate = gate
        let registry = makeRegistry(
            environment: fixture.environment,
            recorder: recorder
        )
        let delegate = AppDelegate(
            environment: fixture.environment,
            sessionRegistry: registry
        )
        XCTAssertTrue(
            registry.openWorkspace(
                try WorkspaceIdentity(root: makeDirectory())
            )
        )
        var replyCount = 0

        let first = delegate.beginTermination { replyCount += 1 }
        let second = delegate.beginTermination { replyCount += 1 }
        await gate.waitUntilEntered()
        XCTAssertEqual(replyCount, 0)
        XCTAssertEqual(recorder.workspaceShutdownCount, 1)
        gate.open()
        await first.value
        await second.value

        XCTAssertEqual(replyCount, 2)
        XCTAssertEqual(recorder.workspaceShutdownCount, 1)
    }

    func testHandleOpenFilesProcessesEveryPathInInputOrder() async throws {
        let fixture = try KodAppTestEnvironment.make(in: self)
        let recorder = RegistryRecorder()
        let registry = makeRegistry(
            environment: fixture.environment,
            recorder: recorder
        )
        let delegate = AppDelegate(
            environment: fixture.environment,
            sessionRegistry: registry
        )
        let firstDirectory = try makeDirectory()
        let firstFile = try makeFile(in: firstDirectory, name: "one.txt")
        let secondDirectory = try makeDirectory()
        let secondFile = try makeFile(in: secondDirectory, name: "two.txt")
        let missingFile = secondDirectory.appendingPathComponent("missing.txt")

        let succeeded = await delegate.handleOpenFiles([
            firstDirectory.path,
            firstFile.path,
            missingFile.path,
            secondDirectory.path,
            secondFile.path
        ])

        XCTAssertFalse(succeeded)
        XCTAssertEqual(recorder.openOrder, [
            "workspace:\(firstDirectory.lastPathComponent)",
            "document:one.txt",
            "workspace:\(secondDirectory.lastPathComponent)",
            "document:two.txt"
        ])
        XCTAssertEqual(registry.activeSessionCount, 4)
    }

    private func makeRegistry(
        environment: AppEnvironment,
        recorder: RegistryRecorder
    ) -> AppSessionRegistry {
        AppSessionRegistry(
            environment: environment,
            factories: AppSessionRegistry.Factories(
                makeWorkspaceWindowController: { identity in
                    recorder.openOrder.append(
                        "workspace:\(identity.root.lastPathComponent)"
                    )
                    let session = environment.makeWorkspaceSession(
                        identity: identity
                    )
                    var services = WorkspaceWindowController.Services.production
                    services.makeWindow = Self.makeWindow
                    services.present = { _ in }
                    services.focus = { _ in
                        recorder.workspaceFocusCount += 1
                    }
                    services.activate = {}
                    services.beginSession = { _ in }
                    services.shutdownSession = { _ in
                        recorder.workspaceShutdownCount += 1
                        if let gate = recorder.shutdownGate {
                            await gate.wait()
                        }
                    }
                    let controller = WorkspaceWindowController(
                        identity: identity,
                        session: session,
                        services: services
                    )
                    recorder.workspaceControllers.append(controller)
                    return controller
                },
                makeDocumentWindowController: { url in
                    var services = DocumentWindowController.Services.production(
                        languageSupportService:
                            environment.languageSupportService,
                        appearanceCenter: environment.appearanceCenter
                    )
                    services.load = { requestedURL in
                        recorder.openOrder.append(
                            "document:\(requestedURL.lastPathComponent)"
                        )
                        return SourceSnapshot(
                            text: "",
                            url: requestedURL,
                            version: 1
                        )
                    }
                    services.makeWindow = Self.makeWindow
                    services.present = { _ in }
                    services.focus = { _ in
                        recorder.documentFocusCount += 1
                    }
                    services.activate = {}
                    let controller = DocumentWindowController(
                        url: url,
                        services: services
                    )
                    recorder.documentControllers.append(controller)
                    return controller
                },
                presentError: { error, _ in
                    XCTFail("Unexpected open error: \(error)")
                }
            )
        )
    }

    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func makeFile(in directory: URL, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data().write(to: url)
        return url
    }

    private static func makeWindow(
        contentViewController: NSViewController
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = contentViewController
        return window
    }
}

@MainActor
private final class RegistryRecorder {
    var workspaceControllers: [WorkspaceWindowController] = []
    var documentControllers: [DocumentWindowController] = []
    var workspaceFocusCount = 0
    var documentFocusCount = 0
    var workspaceShutdownCount = 0
    var openOrder: [String] = []
    var shutdownGate: RegistryShutdownGate?
}

@MainActor
private final class RegistryShutdownGate {
    private var isOpen = false
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else {
            return
        }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
