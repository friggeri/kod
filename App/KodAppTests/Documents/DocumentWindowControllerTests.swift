import AppKit
import SourceIO
import SourceModel
import XCTest
@testable import Kod

@MainActor
final class DocumentWindowControllerTests: XCTestCase {
    func testLoadingViewShowsAnAccessibleFilenameStatusBesideSpinner() throws {
        let loadingController = DocumentWindowController.makeLoadingViewController(
            filename: "example.swift"
        )
        let status = try XCTUnwrap(
            findView(
                identifier: "document.loadingStatus",
                in: loadingController.view
            ) as? NSTextField
        )
        let spinner = try XCTUnwrap(
            loadingController.view.subviews
                .flatMap(\.subviews)
                .first { $0 is NSProgressIndicator } as? NSProgressIndicator
        )

        XCTAssertEqual(status.stringValue, "Opening example.swift...")
        XCTAssertTrue(status.isAccessibilityElement())
        XCTAssertEqual(status.accessibilityLabel(), "Opening example.swift...")
        XCTAssertFalse(spinner.isAccessibilityElement())
        XCTAssertEqual(spinner.style, .spinning)
        XCTAssertTrue(spinner.isIndeterminate)
    }

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

    func testOversizedFileRequiresConfirmationBeforeRetrying() async throws {
        let fixture = try KodAppTestEnvironment.make(in: self)
        let url = URL(fileURLWithPath: "/documents/large.swift")
            .standardizedFileURL
        var unrestrictedLoads = 0
        let controller = DocumentWindowController(
            url: url,
            services: DocumentWindowController.Services(
                load: { requestedURL in
                    throw SourceIOError.fileExceedsRenderingByteLimit(
                        url: requestedURL,
                        byteCount: 20_000_000,
                        limit: 10_000_000
                    )
                },
                loadIgnoringByteLimit: { requestedURL in
                    unrestrictedLoads += 1
                    return SourceSnapshot(
                        text: "large",
                        url: requestedURL,
                        version: 1
                    )
                },
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
        controller.oversizedFileLoadConfirmation = {
            requestedURL,
            byteCount,
            limit in
            XCTAssertEqual(requestedURL, url)
            XCTAssertEqual(byteCount, 20_000_000)
            XCTAssertEqual(limit, 10_000_000)
            return true
        }

        try await controller.loadAndShow()

        XCTAssertEqual(unrestrictedLoads, 1)
        XCTAssertNotNil(controller.contentController)
    }

    /// The unrestricted retry is part of the same tracked load, so closing
    /// the window cancels it *and* waits for it to finish. Dropping the
    /// task handle before the retry (as this once did) left the largest
    /// read the app ever performs running with nobody holding it.
    func testShutdownCancelsAndAwaitsTheOversizedRetry() async throws {
        let fixture = try KodAppTestEnvironment.make(in: self)
        let url = URL(fileURLWithPath: "/documents/enormous.log")
            .standardizedFileURL
        let gate = DocumentLoaderGate()
        let retry = RetryRecorder()
        let controller = DocumentWindowController(
            url: url,
            services: DocumentWindowController.Services(
                load: { requestedURL in
                    throw SourceIOError.fileExceedsRenderingByteLimit(
                        url: requestedURL,
                        byteCount: 20_000_000,
                        limit: 10_000_000
                    )
                },
                loadIgnoringByteLimit: { _ in
                    retry.didStart = true
                    do {
                        return try await gate.waitRespectingCancellation()
                    } catch is CancellationError {
                        retry.observedCancellation = Task.isCancelled
                        retry.didFinish = true
                        throw CancellationError()
                    }
                },
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
        controller.oversizedFileLoadConfirmation = { _, _, _ in true }

        let load = Task { @MainActor in try await controller.loadAndShow() }
        await gate.waitUntilEntered()
        XCTAssertTrue(retry.didStart)

        await controller.shutdown()

        XCTAssertTrue(
            retry.didFinish,
            "shutdown must not return while the unrestricted retry is still running"
        )
        XCTAssertTrue(
            retry.observedCancellation,
            "shutdown must cancel the unrestricted retry"
        )
        // A no-op once shutdown has cancelled and awaited the retry; it
        // only matters if that contract regresses, so this test reports a
        // failure instead of hanging on a load nobody released.
        gate.fail(CancellationError())
        do {
            try await load.value
            XCTFail("Expected the cancelled load to fail")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertNil(controller.contentController)
    }

    /// A window that is already closing must never put a modal question
    /// on screen for a file nobody is waiting for any more.
    func testShutdownBeforeTheOversizedQuestionNeverAsksTheUser() async throws {
        let fixture = try KodAppTestEnvironment.make(in: self)
        let url = URL(fileURLWithPath: "/documents/late.log").standardizedFileURL
        let gate = DocumentLoaderGate()
        let retry = RetryRecorder()
        var promptCount = 0
        let controller = DocumentWindowController(
            url: url,
            services: DocumentWindowController.Services(
                load: { requestedURL in
                    // The guarded read only discovers the file is
                    // oversized *after* the window started closing.
                    try await gate.waitFailing(
                        onCancellation: SourceIOError
                            .fileExceedsRenderingByteLimit(
                                url: requestedURL,
                                byteCount: 20_000_000,
                                limit: 10_000_000
                            )
                    )
                },
                loadIgnoringByteLimit: { _ in
                    retry.didStart = true
                    throw CancellationError()
                },
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
        controller.oversizedFileLoadConfirmation = { _, _, _ in
            promptCount += 1
            return true
        }

        let load = Task { @MainActor in try await controller.loadAndShow() }
        await gate.waitUntilEntered()
        await controller.shutdown()

        do {
            try await load.value
            XCTFail("Expected the abandoned load to fail")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(promptCount, 0)
        XCTAssertFalse(retry.didStart)
        XCTAssertNil(controller.contentController)
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

    private func findView(identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier {
            return view
        }
        for subview in view.subviews {
            if let match = findView(identifier: identifier, in: subview) {
                return match
            }
        }
        return nil
    }
}

@MainActor
private final class RetryRecorder {
    var didStart = false
    var didFinish = false
    var observedCancellation = false
}

@MainActor
private final class DocumentLoaderGate {
    private var continuation:
        CheckedContinuation<SourceSnapshot, any Error>?
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async throws -> SourceSnapshot {
        noteEntered()
        return try await withCheckedThrowingContinuation {
            continuation = $0
        }
    }

    /// Parks the caller until the load task is cancelled, then fails with
    /// `CancellationError`, the way a cancellation-aware read does.
    func waitRespectingCancellation() async throws -> SourceSnapshot {
        try await waitFailing(onCancellation: CancellationError())
    }

    /// Parks the caller until the load task is cancelled, then fails with
    /// `error` — so a test can drive "the read reported its result only
    /// after the window started closing".
    func waitFailing(onCancellation error: any Error) async throws -> SourceSnapshot {
        noteEntered()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation = $0 }
        } onCancel: {
            Task { @MainActor in
                self.fail(error)
            }
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

    private func noteEntered() {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
    }
}
