import Foundation
import SourceModel
import XCTest
@testable import LanguageClient

/// A continuation gate that suspends the *first* document replay and
/// reports when it has been entered, so a test can observe the exact
/// window in which a relaunched server is running but Kod's documents
/// have not been re-sent yet — with no sleeps anywhere.
private actor DocumentReplayGate {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        guard !released else {
            return
        }
        entered = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

/// Explicit-shutdown, restart-resynchronization, and request-error
/// propagation coverage for `LanguageWorkspaceService` (SPEC 6.2/6.3),
/// driven entirely by the deterministic `FakeLanguageServer` fixture and
/// continuation gates.
final class LanguageWorkspaceServiceLifecycleTests: XCTestCase {
    /// A fresh, isolated workspace root. Launch authorization is an
    /// injected capability now, so no trust store (and no `UserDefaults`
    /// suite) is involved in exercising the service.
    private func makeWorkspaceRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func makeDependencies(
        scenario: String,
        environment: [String: String]? = nil
    ) throws -> LanguageWorkspaceService.Dependencies {
        let executableURL = try FakeLanguageServerLocator.executableURL()
        return LanguageWorkspaceService.Dependencies(
            discoverExecutable: { executableURL },
            connectionFactory: { configuration, onStateChange, onNotification in
                var configuration = configuration
                configuration.arguments = [scenario]
                configuration.environment = environment
                return LanguageServerConnection(
                    configuration: configuration,
                    onStateChange: onStateChange,
                    onNotification: onNotification
                )
            }
        )
    }

    // MARK: - Idempotent shutdown

    @MainActor
    func testStopIsIdempotentAndNeverAdvancesTheGenerationTwice() async throws {
        let root = try makeWorkspaceRoot()
        let service = LanguageWorkspaceService(
            workspaceRoot: root,
            authorization: .authorized,
            configuration: LanguageWorkspaceService.Configuration(languageId: "typescript"),
            dependencies: try makeDependencies(scenario: "normal")
        )
        try await service.start()
        addTeardownBlock { await service.stop() }

        let startedGeneration = await service.currentGeneration
        await service.stop()
        let stoppedGeneration = await service.currentGeneration
        XCTAssertEqual(stoppedGeneration, startedGeneration + 1)

        await service.stop()
        await service.stop()
        let repeatedGeneration = await service.currentGeneration
        XCTAssertEqual(
            repeatedGeneration,
            stoppedGeneration,
            "A stop after a completed stop must be a no-op"
        )
        let state = await service.currentState
        XCTAssertNil(state, "The connection is released exactly once")
        let isStopped = await service.isStoppedForTesting
        XCTAssertTrue(isStopped)
        let pendingDiagnostics = await service.hasPendingWorkspaceDiagnosticsForTesting
        XCTAssertFalse(pendingDiagnostics, "stop() must cancel and await workspace diagnostics")
        let pendingReplay = await service.hasPendingDocumentReplayForTesting
        XCTAssertFalse(pendingReplay)
    }

    @MainActor
    func testConcurrentStopsJoinOneShutdown() async throws {
        let root = try makeWorkspaceRoot()
        let service = LanguageWorkspaceService(
            workspaceRoot: root,
            authorization: .authorized,
            configuration: LanguageWorkspaceService.Configuration(languageId: "typescript"),
            dependencies: try makeDependencies(scenario: "normal")
        )
        try await service.start()
        addTeardownBlock { await service.stop() }
        let startedGeneration = await service.currentGeneration

        async let first: Void = service.stop()
        async let second: Void = service.stop()
        async let third: Void = service.stop()
        _ = await (first, second, third)

        let generation = await service.currentGeneration
        XCTAssertEqual(
            generation,
            startedGeneration + 1,
            "Concurrent stops must join one shutdown rather than each advancing the generation"
        )
    }

    @MainActor
    func testRestartIsStillSupportedAfterAnExplicitStop() async throws {
        let root = try makeWorkspaceRoot()
        let service = LanguageWorkspaceService(
            workspaceRoot: root,
            authorization: .authorized,
            configuration: LanguageWorkspaceService.Configuration(languageId: "typescript"),
            dependencies: try makeDependencies(scenario: "normal")
        )
        try await service.start()
        addTeardownBlock { await service.stop() }
        await service.stop()

        try await service.start()
        let state = await service.currentState
        XCTAssertEqual(state, .ready)

        let snapshot = SourceSnapshot(
            text: "class Greeter {}\n",
            url: root.appendingPathComponent("Restarted.ts"),
            version: 1
        )
        try await service.didOpen(snapshot)
        try await service.restart()
        let restartedState = await service.currentState
        XCTAssertEqual(restartedState, .ready)
    }

    @MainActor
    func testNoFakeLanguageServerChildProcessRemainsAfterStop() async throws {
        let root = try makeWorkspaceRoot()
        let stateFile = root.appendingPathComponent("lifecycle-state")
        FileManager.default.createFile(atPath: stateFile.path, contents: Data())
        let service = LanguageWorkspaceService(
            workspaceRoot: root,
            authorization: .authorized,
            configuration: LanguageWorkspaceService.Configuration(languageId: "typescript"),
            dependencies: try makeDependencies(
                scenario: "normal",
                environment: ["FAKE_LSP_STATE_FILE": stateFile.path]
            )
        )
        try await service.start()
        addTeardownBlock { await service.stop() }

        let serverPID = try await pollForServerPID(stateFile: stateFile)
        XCTAssertTrue(
            isProcessAlive(serverPID),
            "The fixture server must be running before the service is stopped"
        )

        await service.stop()

        let deadline = ContinuousClock.now + .seconds(5)
        while isProcessAlive(serverPID), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(
            isProcessAlive(serverPID),
            "stop() must leave no FakeLanguageServer child process behind"
        )
    }

    // MARK: - Automatic-restart document replay

    @MainActor
    func testReadyIsNotForwardedUntilEveryDocumentHasBeenReplayed() async throws {
        let root = try makeWorkspaceRoot()
        let stateFile = root.appendingPathComponent("replay-state")
        FileManager.default.createFile(atPath: stateFile.path, contents: Data())
        let gate = DocumentReplayGate()
        let states = LockedArray<LanguageServerState>()
        let service = LanguageWorkspaceService(
            workspaceRoot: root,
            authorization: .authorized,
            configuration: LanguageWorkspaceService.Configuration(languageId: "typescript"),
            dependencies: try makeDependencies(
                scenario: "no-diagnostics",
                environment: ["FAKE_LSP_STATE_FILE": stateFile.path]
            ),
            onStateChange: { states.append($0) },
            diagnosticNormalizationYield: {},
            documentReplayYield: { await gate.suspend() }
        )
        try await service.start()
        addTeardownBlock { await service.stop() }

        let snapshot = SourceSnapshot(
            text: "class Greeter {}\n",
            url: root.appendingPathComponent("Replayed.ts"),
            version: 3
        )
        try await service.didOpen(snapshot)
        try await waitForStateFile(stateFile) { $0.contains("didOpen") }
        let readyCountBeforeRestart = states.snapshot().filter { $0 == .ready }.count
        XCTAssertEqual(readyCountBeforeRestart, 1)

        // The crash/auto-restart cycle the connection produces inside one
        // connection instance: .starting, then .ready again.
        await service.handleStateChangeForTesting(.starting)
        let restartReady = Task {
            await service.handleStateChangeForTesting(.ready)
        }
        await gate.waitUntilEntered()

        XCTAssertEqual(
            states.snapshot().filter { $0 == .ready }.count,
            readyCountBeforeRestart,
            "A relaunched server must not be reported ready while documents are unsynchronized"
        )
        XCTAssertEqual(
            try didOpenCount(in: stateFile),
            1,
            "The replay has not been issued yet"
        )

        await gate.release()
        await restartReady.value

        XCTAssertEqual(
            states.snapshot().filter { $0 == .ready }.count,
            readyCountBeforeRestart + 1,
            "Ready is forwarded once the replay has fully succeeded"
        )
        try await waitForStateFile(stateFile) { text in
            text.components(separatedBy: "didOpen").count - 1 >= 2
        }
        let failures = await service.documentReplayFailures
        XCTAssertTrue(failures.isEmpty)
    }

    @MainActor
    func testReplayFailureIsReportedAndReadyIsNeverClaimed() async throws {
        let root = try makeWorkspaceRoot()
        let states = LockedArray<LanguageServerState>()
        let reported = LockedArray<[LanguageDocumentReplayFailure]>()
        let markerClears = LockedArray<URL>()
        let service = LanguageWorkspaceService(
            workspaceRoot: root,
            authorization: .authorized,
            configuration: LanguageWorkspaceService.Configuration(languageId: "typescript"),
            dependencies: try makeDependencies(scenario: "no-diagnostics"),
            onStateChange: { states.append($0) },
            onNormalizedDiagnostics: { url, diagnostics in
                if diagnostics.isEmpty {
                    markerClears.append(url)
                }
            },
            onDocumentReplayFailure: { reported.append($0) }
        )
        try await service.start()
        addTeardownBlock { await service.stop() }

        let secret = "let apiKey = \"super-secret-token\"\n"
        let url = root.appendingPathComponent("Unreplayable.ts")
        let snapshot = SourceSnapshot(text: secret, url: url, version: 9)
        try await service.didOpen(snapshot)
        let readyCountBeforeRestart = states.snapshot().filter { $0 == .ready }.count

        await service.handleStateChangeForTesting(.starting)
        // The transport disappears between "server is ready" and the
        // replay, which is what a second failure inside the restart
        // window looks like from here.
        await service.simulateConnectionLossForTesting()
        await service.handleStateChangeForTesting(.ready)

        XCTAssertEqual(
            states.snapshot().filter { $0 == .ready }.count,
            readyCountBeforeRestart,
            "A failed replay must never be followed by an operational ready"
        )
        let failures = try XCTUnwrap(reported.snapshot().first)
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.url, url)
        XCTAssertEqual(failures.first?.reason, .notConnected)
        let serviceFailures = await service.documentReplayFailures
        XCTAssertEqual(serviceFailures, failures)

        guard case .crashed(let reason)? = states.snapshot().last else {
            return XCTFail("Expected a degraded state, got \(states.snapshot())")
        }
        XCTAssertTrue(reason.contains("Unreplayable.ts"), "Got: \(reason)")
        XCTAssertFalse(
            reason.contains("super-secret-token"),
            "A replay failure must never leak document contents"
        )
        XCTAssertTrue(
            markerClears.snapshot().contains(url.standardizedFileURL),
            "A document the server never received must lose its editor markers"
        )
    }

    // MARK: - Request error propagation

    @MainActor
    func testSignatureHelpTransportErrorPropagatesWhileAValidEmptyResultStaysNil() async throws {
        let root = try makeWorkspaceRoot()
        let malformed = LanguageWorkspaceService(
            workspaceRoot: root,
            authorization: .authorized,
            configuration: LanguageWorkspaceService.Configuration(languageId: "typescript"),
            dependencies: try makeDependencies(scenario: "signature-help-malformed")
        )
        try await malformed.start()
        addTeardownBlock { await malformed.stop() }
        let snapshot = SourceSnapshot(
            text: "greet(1)\n",
            url: root.appendingPathComponent("Signature.ts"),
            version: 1
        )
        try await malformed.didOpen(snapshot)

        do {
            let result = try await malformed.signatureHelp(snapshot: snapshot, utf8Offset: 0)
            XCTFail("Expected a malformed signature-help response to throw, got \(String(describing: result))")
        } catch let error as LanguageClientError {
            guard case .invalidResponse(let method, _) = error else {
                return XCTFail("Expected invalidResponse, got \(error)")
            }
            XCTAssertEqual(method, "textDocument/signatureHelp")
        }

        let empty = LanguageWorkspaceService(
            workspaceRoot: root,
            authorization: .authorized,
            configuration: LanguageWorkspaceService.Configuration(languageId: "typescript"),
            dependencies: try makeDependencies(scenario: "signature-help-empty")
        )
        try await empty.start()
        addTeardownBlock { await empty.stop() }
        try await empty.didOpen(snapshot)
        let emptyResult = try await empty.signatureHelp(snapshot: snapshot, utf8Offset: 0)
        XCTAssertNil(
            emptyResult,
            "nil must mean only that the server answered with a valid empty result"
        )
    }

}

// MARK: - Fixture process helpers

private func pollForServerPID(stateFile: URL) async throws -> pid_t {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        let text = (try? String(contentsOf: stateFile, encoding: .utf8)) ?? ""
        if let line = text
            .components(separatedBy: "\n")
            .first(where: { $0.hasPrefix("pid:") }),
            let value = Int32(line.dropFirst("pid:".count)) {
            return value
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw XCTSkip("The fixture server never reported its process identifier")
}

/// Whether `pid` still names a live (non-reaped, non-zombie) process.
private func isProcessAlive(_ pid: pid_t) -> Bool {
    guard kill(pid, 0) == 0 else {
        return false
    }
    return processState(pid)?.hasPrefix("Z") == false
}

private func processState(_ pid: pid_t) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "stat=", "-p", "\(pid)"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
    } catch {
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return output.isEmpty ? nil : output
}

private func didOpenCount(in stateFile: URL) throws -> Int {
    let text = try String(contentsOf: stateFile, encoding: .utf8)
    return text
        .components(separatedBy: "\n")
        .filter { $0 == "didOpen" }
        .count
}

private func waitForStateFile(
    _ stateFile: URL,
    timeout: Duration = .seconds(5),
    until predicate: @Sendable (String) -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        let text = (try? String(contentsOf: stateFile, encoding: .utf8)) ?? ""
        if predicate(text) {
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("State file never satisfied the expected condition")
}
