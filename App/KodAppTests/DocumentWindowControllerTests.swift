import AppKit
import SourceModel
import XCTest
@testable import Kod

@MainActor
final class DocumentWindowControllerTests: XCTestCase {
    func testAsyncLoadConstructsStandaloneContentAndPresentsOnce() async throws {
        let fixture = try KodAppTestEnvironment.make(in: self)
        let url = URL(fileURLWithPath: "/documents/example.swift")
        let gate = DocumentLoaderGate()
        var presentations = 0
        var contentConstructions = 0
        let controller = DocumentWindowController(
            url: url,
            services: DocumentWindowController.Services(
                load: { requestedURL in
                    XCTAssertEqual(requestedURL, url.standardizedFileURL)
                    return try await gate.wait()
                },
                makeContentViewController: { snapshot in
                    contentConstructions += 1
                    return StandaloneDocumentViewController(
                        snapshot: snapshot,
                        languageSupportService:
                            fixture.environment.languageSupportService,
                        appearanceCenter: fixture.environment.appearanceCenter
                    )
                },
                makeWindow: Self.makeWindow,
                present: { _ in presentations += 1 },
                focus: { _ in },
                activate: {}
            )
        )

        let load = Task { @MainActor in try await controller.loadAndShow() }
        await gate.waitUntilEntered()
        XCTAssertEqual(presentations, 1)
        XCTAssertNil(controller.contentController)
        gate.succeed(
            SourceSnapshot(text: "let value = 1\n", url: url, version: 1)
        )
        try await load.value

        XCTAssertEqual(contentConstructions, 1)
        XCTAssertNotNil(controller.contentController)
        XCTAssertEqual(controller.window?.title, "example.swift")
    }

    func testCloseShutdownCancelsAndAwaitsOutstandingLoad() async throws {
        let fixture = try KodAppTestEnvironment.make(in: self)
        let url = URL(fileURLWithPath: "/documents/pending.txt")
        let gate = DocumentLoaderGate()
        let controller = DocumentWindowController(
            url: url,
            services: DocumentWindowController.Services(
                load: { _ in try await gate.wait() },
                makeContentViewController: {
                    StandaloneDocumentViewController(
                        snapshot: $0,
                        languageSupportService:
                            fixture.environment.languageSupportService,
                        appearanceCenter: fixture.environment.appearanceCenter
                    )
                },
                makeWindow: Self.makeWindow,
                present: { _ in },
                focus: { _ in },
                activate: {}
            )
        )

        let load = Task { @MainActor in try await controller.loadAndShow() }
        await gate.waitUntilEntered()
        let shutdown = Task { @MainActor in await controller.shutdown() }
        gate.fail(CancellationError())
        await shutdown.value

        do {
            try await load.value
            XCTFail("Expected the cancelled load to fail")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertNil(controller.contentController)
    }

    private static func makeWindow(
        contentViewController: NSViewController
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = contentViewController
        return window
    }
}

@MainActor
private final class DocumentLoaderGate {
    private var continuation:
        CheckedContinuation<SourceSnapshot, any Error>?
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async throws -> SourceSnapshot {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        return try await withCheckedThrowingContinuation {
            continuation = $0
        }
    }

    func waitUntilEntered() async {
        guard !entered else {
            return
        }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func succeed(_ snapshot: SourceSnapshot) {
        continuation?.resume(returning: snapshot)
        continuation = nil
    }

    func fail(_ error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
