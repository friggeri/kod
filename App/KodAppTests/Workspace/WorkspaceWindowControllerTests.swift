import AppKit
import KodUIComponents
import WorkspaceCore
import XCTest
@testable import Kod

@MainActor
final class WorkspaceWindowControllerTests: XCTestCase {
    private func makeIdentity() throws -> WorkspaceIdentity {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return try WorkspaceIdentity(root: root)
    }

    func testShowBuildsIndependentWorkspaceChromeAndReusesWindow() throws {
        let fixture = try KodAppTestEnvironment.make(in: self)
        let identity = try makeIdentity()
        let session = fixture.environment.makeWorkspaceSession(
            identity: identity
        )
        var presentations = 0
        var focuses = 0
        var starts = 0
        var activations = 0
        let services = WorkspaceWindowController.Services(
            makeWindow: Self.makeWindow,
            present: { _ in presentations += 1 },
            focus: { _ in focuses += 1 },
            activate: { activations += 1 },
            beginSession: { _ in starts += 1 },
            shutdownSession: { _ in }
        )
        let controller = WorkspaceWindowController(
            identity: identity,
            session: session,
            services: services
        )

        controller.showSessionWindow()
        controller.showSessionWindow()

        XCTAssertEqual(presentations, 1)
        XCTAssertEqual(focuses, 1)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(activations, 2)
        XCTAssertEqual(controller.window?.title, identity.root.lastPathComponent)
        XCTAssertTrue(
            controller.window?.styleMask.contains(.fullSizeContentView) == true
        )
        XCTAssertTrue(controller.window?.delegate === controller)
        XCTAssertEqual(
            controller.window?.backgroundColor,
            ThemeColorAppKitBridge.nsColor(
                fixture.environment.appearanceCenter.snapshot.theme
                    .surface.windowBackground
            )
        )
    }

    func testConcurrentShutdownJoinsInjectedGate() async throws {
        let fixture = try KodAppTestEnvironment.make(in: self)
        let identity = try makeIdentity()
        let session = fixture.environment.makeWorkspaceSession(
            identity: identity
        )
        let gate = WindowControllerGate()
        var shutdownCount = 0
        let services = WorkspaceWindowController.Services(
            makeWindow: Self.makeWindow,
            present: { _ in },
            focus: { _ in },
            activate: {},
            beginSession: { _ in },
            shutdownSession: { _ in
                shutdownCount += 1
                await gate.wait()
            }
        )
        let controller = WorkspaceWindowController(
            identity: identity,
            session: session,
            services: services
        )

        let first = Task { @MainActor in await controller.shutdown() }
        let second = Task { @MainActor in await controller.shutdown() }
        await gate.waitUntilEntered()
        XCTAssertEqual(shutdownCount, 1)
        gate.open()
        _ = await (first.value, second.value)
        XCTAssertEqual(shutdownCount, 1)
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
private final class WindowControllerGate {
    private var isOpen = false
    private var isEntered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        isEntered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !isEntered else {
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
