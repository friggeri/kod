import Foundation

/// Bounded, rotating capture of a language server process's stderr, kept
/// entirely in memory (never written to an exported log without explicit
/// user action, per SPEC 6.2 "path and source-content redaction in
/// exported diagnostics" — redaction itself is the UI layer's job; this
/// type's job is only to bound memory and keep the most recent bytes).
public actor RotatingLogCapture {
    private var chunks: [String] = []
    private var totalByteCount = 0
    private let maxByteCount: Int

    public init(maxByteCount: Int = 256 * 1_024) {
        self.maxByteCount = maxByteCount
    }

    public func append(_ data: Data) {
        guard !data.isEmpty else {
            return
        }
        let text = String(decoding: data, as: UTF8.self)
        chunks.append(text)
        totalByteCount += data.count
        while totalByteCount > maxByteCount, chunks.count > 1 {
            totalByteCount -= chunks.removeFirst().utf8.count
        }
        // Even a single chunk can exceed the bound (one huge write): trim
        // it from the front so the bound is never exceeded even with one
        // retained chunk, per SPEC's "bounded" requirement.
        if totalByteCount > maxByteCount, let first = chunks.first {
            let overshoot = totalByteCount - maxByteCount
            if overshoot < first.utf8.count {
                let trimmed = String(decoding: Array(first.utf8.dropFirst(overshoot)), as: UTF8.self)
                totalByteCount -= overshoot
                chunks[0] = trimmed
            }
        }
    }

    public func snapshot() -> String {
        chunks.joined()
    }

    public var byteCount: Int {
        totalByteCount
    }
}

/// Launches and owns stdio for exactly one language server process.
/// Never resolves an executable through `PATH`, a shell, or a relative
/// path: `executableURL` must already be an absolute, existing file the
/// caller resolved (e.g. via `SourceKitLSPDiscovery`), and `arguments` is
/// a fixed array — nothing here ever interpolates or evaluates shell
/// text (SPEC 6.5, 13.2).
public actor LanguageServerProcessTransport {
    public enum TransportError: Error, Equatable, Sendable {
        case notRunning
        case writeFailed(String)
    }

    private let process = Process()
    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var stdoutReadTask: Task<Void, Never>?
    private var stderrReadTask: Task<Void, Never>?
    public let stderrCapture = RotatingLogCapture()

    private var decoder: JSONRPCFramingDecoder
    private var messageContinuation: AsyncStream<Data>.Continuation?
    private var terminationContinuation: CheckedContinuation<Int32, Never>?
    private var exitCode: Int32?
    private var framingErrorHandler: (@Sendable (Error) -> Void)?

    public init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        maxHeaderByteCount: Int = 8 * 1_024,
        maxMessageByteCount: Int = 64 * 1_024 * 1_024
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.decoder = JSONRPCFramingDecoder(
            maxHeaderByteCount: maxHeaderByteCount,
            maxMessageByteCount: maxMessageByteCount
        )
    }

    /// Starts the process and returns a stream of de-framed message
    /// bodies (raw JSON, `Content-Length` header already stripped). The
    /// stream finishes when the process's stdout closes; termination
    /// (including exit code, for crash detection) is observed separately
    /// via `waitForTermination()`.
    public func start(onFramingError: @escaping @Sendable (Error) -> Void) throws -> AsyncStream<Data> {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw LanguageClientError.executableNotFound(executableURL.path)
        }
        framingErrorHandler = onFramingError

        process.executableURL = executableURL
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutHandle = stdoutPipe.fileHandleForReading
        stderrHandle = stderrPipe.fileHandleForReading

        let stdoutChunks = AsyncStream<Data> { continuation in
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                continuation.yield(data)
                if data.isEmpty {
                    continuation.finish()
                }
            }
        }
        let stderrChunks = AsyncStream<Data> { continuation in
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                continuation.yield(data)
                if data.isEmpty {
                    continuation.finish()
                }
            }
        }
        stdoutReadTask = Task { [weak self] in
            for await data in stdoutChunks {
                guard let self else {
                    return
                }
                await self.handleStdout(data)
            }
        }
        stderrReadTask = Task { [weak self] in
            for await data in stderrChunks {
                guard let self else {
                    return
                }
                await self.handleStderr(data)
            }
        }
        process.terminationHandler = { process in
            let transport = self
            Task { await transport.handleTermination(exitCode: process.terminationStatus) }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw LanguageClientError.processLaunchFailed(error.localizedDescription)
        }

        return AsyncStream { continuation in
            messageContinuation = continuation
        }
    }

    public func send(_ body: Data) throws {
        guard process.isRunning, let stdinHandle else {
            throw TransportError.notRunning
        }
        let framed = JSONRPCFramingEncoder.frame(body)
        do {
            try stdinHandle.write(contentsOf: framed)
        } catch {
            throw TransportError.writeFailed(error.localizedDescription)
        }
    }

    public var isRunning: Bool {
        process.isRunning
    }

    /// Suspends until the process has exited, returning its exit code.
    /// Safe to call after the process has already exited.
    public func waitForTermination() async -> Int32 {
        if let exitCode {
            return exitCode
        }
        return await withCheckedContinuation { continuation in
            terminationContinuation = continuation
        }
    }

    /// Requests graceful termination (SIGTERM-equivalent `Process.terminate()`).
    public func terminate() {
        guard process.isRunning else {
            return
        }
        process.terminate()
    }

    /// Hard-kill fallback when graceful shutdown doesn't complete within
    /// the caller's timeout.
    public func forceKill() {
        guard process.isRunning else {
            return
        }
        process.interrupt()
        kill(process.processIdentifier, SIGKILL)
    }

    private func handleStdout(_ data: Data) {
        guard !data.isEmpty else {
            stdoutHandle?.readabilityHandler = nil
            messageContinuation?.finish()
            return
        }
        do {
            let messages = try decoder.consume(data)
            for message in messages {
                messageContinuation?.yield(message)
            }
        } catch {
            framingErrorHandler?(error)
            stdoutHandle?.readabilityHandler = nil
            messageContinuation?.finish()
            if process.isRunning {
                process.terminate()
            }
        }
    }

    private func handleStderr(_ data: Data) async {
        guard !data.isEmpty else {
            stderrHandle?.readabilityHandler = nil
            return
        }
        await stderrCapture.append(data)
    }

    private func handleTermination(exitCode: Int32) {
        self.exitCode = exitCode
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        stdoutReadTask?.cancel()
        stdoutReadTask = nil
        stderrReadTask?.cancel()
        stderrReadTask = nil
        messageContinuation?.finish()
        terminationContinuation?.resume(returning: exitCode)
        terminationContinuation = nil
    }
}
