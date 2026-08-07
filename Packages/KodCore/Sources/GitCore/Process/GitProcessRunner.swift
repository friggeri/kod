import Foundation

public enum GitProcessError: Error, Equatable, Sendable {
    case executableNotFound(String)
    case launchFailed(String)
    case timedOut
    case cancelled
}

/// Raw result of one Git invocation: exit code plus bounded stdout/stderr.
/// Parsers (`GitStatusParser`, `GitDiffParser`, `GitBlameParser`) consume
/// `standardOutput` directly; nothing here interprets the bytes.
public struct GitProcessResult: Sendable {
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: Data
    public let standardOutputTruncated: Bool

    public init(exitCode: Int32, standardOutput: Data, standardError: Data, standardOutputTruncated: Bool) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.standardOutputTruncated = standardOutputTruncated
    }

    public var standardErrorMessage: String {
        String(decoding: standardError, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One fully-specified, already-hardened Git invocation. Callers build
/// this only through `GitInvocationHardening` + a `GitReadOnlyCommand`
/// case, never by hand-assembling a raw command name.
public struct GitInvocation: Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let currentDirectoryURL: URL
    public let environment: [String: String]
    public let maximumOutputByteCount: Int
    public let timeout: TimeInterval

    public init(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        environment: [String: String],
        maximumOutputByteCount: Int = 128 * 1_024 * 1_024,
        timeout: TimeInterval = 20
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.currentDirectoryURL = currentDirectoryURL
        self.environment = environment
        self.maximumOutputByteCount = maximumOutputByteCount
        self.timeout = timeout
    }
}

/// Runs one Git invocation at a time end-to-end: launching the already-
/// resolved absolute executable with its fixed argument array, capturing
/// bounded stdout/stderr, enforcing a wall-clock timeout, and guaranteeing
/// the child process is terminated on cancellation, on timeout, or once
/// the output cap is reached — never left running. Modeled directly on
/// `SearchCore`'s `RipgrepProcessSession`.
///
/// A fresh `GitProcessRunner` (or a fresh `run` call on a shared one) can
/// be used concurrently for independent invocations; each invocation gets
/// its own `Process` and pipes, so nothing here serializes unrelated Git
/// calls against each other beyond what the OS itself schedules.
public actor GitProcessRunner {
    public init() {}

    /// Runs `invocation`, returning once the process exits (or is
    /// terminated due to cancellation, timeout, or the output cap). Never
    /// throws for a non-zero exit code — that is a normal, parseable
    /// outcome for some Git commands — only for launch failure or
    /// cooperative-cancellation/timeout termination.
    public func run(_ invocation: GitInvocation) async throws -> GitProcessResult {
        try Task.checkCancellation()

        let session = GitProcessSession(invocation: invocation)
        return try await withTaskCancellationHandler(
            operation: {
                try await session.run()
            },
            onCancel: {
                Task { await session.cancel(reason: .cancelled) }
            }
        )
    }
}

/// Owns exactly one child-process invocation. Isolated as its own actor
/// (rather than plain synchronous code) because pipe `readabilityHandler`
/// callbacks fire on an arbitrary background queue, not the calling
/// `Task`'s executor, and must serialize safely against cancellation and
/// termination arriving concurrently.
private actor GitProcessSession {
    fileprivate enum TerminationReason: Sendable, Equatable {
        case cancelled
        case timedOut
        case outputCapReached
    }

    private let invocation: GitInvocation
    private let process = Process()

    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var stdoutTruncated = false

    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var stdoutClosed = false
    private var stderrClosed = false
    private var exitCode: Int32?
    private var terminationReason: TerminationReason?
    private var isFinished = false
    private var timeoutTask: Task<Void, Never>?
    private var awaitingCompletion: CheckedContinuation<Void, Never>?

    init(invocation: GitInvocation) {
        self.invocation = invocation
    }

    func run() async throws -> GitProcessResult {
        guard FileManager.default.isExecutableFile(atPath: invocation.executableURL.path) else {
            throw GitProcessError.executableNotFound(invocation.executableURL.path)
        }

        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.currentDirectoryURL = invocation.currentDirectoryURL
        process.environment = invocation.environment
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stdoutHandle = stdoutPipe.fileHandleForReading
        stderrHandle = stderrPipe.fileHandleForReading

        let session = self
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            Task { await session.handleStdout(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            Task { await session.handleStderr(data) }
        }
        process.terminationHandler = { process in
            Task { await session.handleTermination(exitCode: process.terminationStatus) }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw GitProcessError.launchFailed(error.localizedDescription)
        }

        scheduleTimeout()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if isFinished {
                continuation.resume()
                return
            }
            awaitingCompletion = continuation
        }

        timeoutTask?.cancel()

        if let terminationReason, terminationReason != .outputCapReached {
            switch terminationReason {
            case .cancelled:
                throw GitProcessError.cancelled
            case .timedOut:
                throw GitProcessError.timedOut
            case .outputCapReached:
                break
            }
        }

        return GitProcessResult(
            exitCode: exitCode ?? -1,
            standardOutput: stdoutBuffer,
            standardError: stderrBuffer,
            standardOutputTruncated: stdoutTruncated
        )
    }

    /// Cancels the in-flight process, if any. Idempotent.
    fileprivate func cancel(reason: TerminationReason = .cancelled) {
        guard !isFinished else {
            return
        }
        if terminationReason == nil {
            terminationReason = reason
        }
        if process.isRunning {
            process.terminate()
        }
    }

    private func scheduleTimeout() {
        let timeout = invocation.timeout
        guard timeout > 0 else {
            return
        }
        let session = self
        timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else {
                return
            }
            await session.cancel(reason: .timedOut)
        }
    }

    fileprivate func handleStdout(_ data: Data) {
        guard !isFinished else {
            return
        }
        guard !data.isEmpty else {
            stdoutHandle?.readabilityHandler = nil
            stdoutClosed = true
            checkComplete()
            return
        }
        guard !stdoutTruncated else {
            return
        }
        let remaining = invocation.maximumOutputByteCount - stdoutBuffer.count
        if remaining <= 0 {
            stdoutTruncated = true
            cancel(reason: .outputCapReached)
            return
        }
        if data.count > remaining {
            stdoutBuffer.append(data.prefix(remaining))
            stdoutTruncated = true
            cancel(reason: .outputCapReached)
        } else {
            stdoutBuffer.append(data)
        }
    }

    fileprivate func handleStderr(_ data: Data) {
        guard !isFinished else {
            return
        }
        guard !data.isEmpty else {
            stderrHandle?.readabilityHandler = nil
            stderrClosed = true
            checkComplete()
            return
        }
        let maxStderrByteCount = 64 * 1_024
        guard stderrBuffer.count < maxStderrByteCount else {
            return
        }
        stderrBuffer.append(data.prefix(maxStderrByteCount - stderrBuffer.count))
    }

    fileprivate func handleTermination(exitCode: Int32) {
        self.exitCode = exitCode
        checkComplete()
    }

    private func checkComplete() {
        guard stdoutClosed, stderrClosed, exitCode != nil, !isFinished else {
            return
        }
        isFinished = true
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        awaitingCompletion?.resume()
        awaitingCompletion = nil
    }
}

