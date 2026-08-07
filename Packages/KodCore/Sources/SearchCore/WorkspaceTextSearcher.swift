import Foundation

/// Streams workspace text search results from Kod's bundled ripgrep-
/// compatible engine.
///
/// Every search is launched with `Process.executableURL` set to an absolute
/// `URL` (never resolved through `PATH`, a shell, or a relative path) and a
/// fixed argument array built by `RipgrepArguments`. Starting a new search
/// on the same `WorkspaceTextSearcher` instance cancels and terminates any
/// search already in flight (SPEC 8.2: "Starting a new query terminates or
/// supersedes the prior query"), so at most one engine process ever runs
/// per instance.
public actor WorkspaceTextSearcher {
    private let executableURL: URL
    private var activeSession: RipgrepProcessSession?

    public init(executableURL: URL? = nil) throws {
        if let executableURL {
            self.executableURL = executableURL
        } else {
            do {
                self.executableURL = try SearchEngineLocator.bundledExecutableURL()
            } catch let error as SearchEngineError {
                throw SearchError.engineUnavailable(error)
            }
        }
    }

    /// Starts `query`, superseding (cancelling and terminating) any search
    /// currently in flight on this instance. The returned stream yields one
    /// `.fileResult` per file as its matches become available, followed by
    /// exactly one terminal `.completed` — or throws a `SearchError`.
    public func search(_ query: SearchQuery) async -> AsyncThrowingStream<SearchStreamEvent, Error> {
        await activeSession?.cancel()

        guard !query.pattern.isEmpty else {
            activeSession = nil
            return AsyncThrowingStream { continuation in
                continuation.yield(
                    .completed(
                        SearchCompletion(
                            queryVersion: query.version,
                            matchedFileCount: 0,
                            matchCount: 0,
                            truncated: false
                        )
                    )
                )
                continuation.finish()
            }
        }

        let session = RipgrepProcessSession(
            executableURL: executableURL,
            query: query
        )
        activeSession = session

        return AsyncThrowingStream { continuation in
            let task = Task {
                await session.run(continuation: continuation)
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await session.cancel() }
            }
        }
    }

    /// Cancels and terminates the in-flight search, if any, without
    /// starting a replacement. No-op if nothing is running.
    public func cancelActiveSearch() async {
        await activeSession?.cancel()
    }
}

/// Owns one engine process invocation end-to-end: launching it, streaming
/// and parsing its stdout, capturing bounded stderr for diagnostics,
/// enforcing the explicit result cap, and guaranteeing the process is
/// terminated on cancellation or early completion. Isolated as its own
/// actor so the `FileHandle` readability callbacks (which fire on an
/// arbitrary background queue, not this `Task`'s executor) can safely hop
/// back into serialized, isolated state instead of racing.
private actor RipgrepProcessSession {
    private let executableURL: URL
    private let query: SearchQuery
    private let process = Process()
    private var parser = RipgrepStreamParser()
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?

    private var stderrBuffer = Data()
    private let maxStderrByteCount = 64 * 1_024

    private var currentPath: String?
    private var currentMatches: [SearchMatch] = []
    private var matchedFileCount = 0
    private var matchCount = 0
    private var truncated = false
    private var isFinished = false

    private var stdoutClosed = false
    private var stderrClosed = false
    private var exitCode: Int32?
    private var awaitingCompletionContinuation: CheckedContinuation<Void, Never>?
    private var pendingResult: Result<Void, Error> = .success(())
    private var pendingEvents: [SearchStreamEvent] = []

    init(executableURL: URL, query: SearchQuery) {
        self.executableURL = executableURL
        self.query = query
    }

    func run(continuation: AsyncThrowingStream<SearchStreamEvent, Error>.Continuation) async {
        process.executableURL = executableURL
        process.arguments = RipgrepArguments.build(for: query)
        process.currentDirectoryURL = query.root

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardInput = FileHandle.nullDevice
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
            continuation.finish(throwing: SearchError.processLaunchFailed(error.localizedDescription))
            return
        }

        await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation { (checkedContinuation: CheckedContinuation<Void, Never>) in
                    if isFinished {
                        checkedContinuation.resume()
                        return
                    }
                    awaitingCompletionContinuation = checkedContinuation
                }
            },
            onCancel: {
                Task { await session.cancel() }
            }
        )

        finish(continuation: continuation)
    }

    /// Cancels the in-flight process (query replacement, explicit user
    /// cancellation, or the consuming `Task` being cancelled). Idempotent
    /// and safe to call even if the process already exited.
    func cancel() {
        guard !isFinished else {
            return
        }
        if process.isRunning {
            process.terminate()
        }
    }

    fileprivate func handleStdout(_ data: Data) {
        guard !isFinished else {
            return
        }
        guard !data.isEmpty else {
            // EOF: a readable pipe FD at EOF stays "readable" forever, so
            // the dispatch source behind `readabilityHandler` would keep
            // firing this callback in a tight, CPU-spinning loop unless we
            // detach it here.
            stdoutHandle?.readabilityHandler = nil
            stdoutClosed = true
            checkProcessOutputComplete()
            return
        }

        do {
            let lines = try parser.consume(data)
            for line in lines {
                apply(line)
                if truncated {
                    break
                }
            }
        } catch {
            failWithMalformedOutput(error)
            return
        }

        if truncated, process.isRunning {
            process.terminate()
        }
    }

    fileprivate func handleStderr(_ data: Data) {
        guard !isFinished else {
            return
        }
        guard !data.isEmpty else {
            stderrHandle?.readabilityHandler = nil
            stderrClosed = true
            checkProcessOutputComplete()
            return
        }
        guard stderrBuffer.count < maxStderrByteCount else {
            return
        }
        stderrBuffer.append(data.prefix(maxStderrByteCount - stderrBuffer.count))
    }

    fileprivate func handleTermination(exitCode: Int32) {
        self.exitCode = exitCode
        checkProcessOutputComplete()
    }

    /// Both pipes must report EOF (empty `availableData`) *and* the process
    /// must have reported an exit code before the search is truly settled:
    /// termination can otherwise race ahead of the last buffered chunk of
    /// stdout/stderr still being delivered to the readability handlers.
    private func checkProcessOutputComplete() {
        guard stdoutClosed, stderrClosed, let exitCode, !isFinished else {
            return
        }

        if !truncated {
            do {
                try parser.finish()
            } catch {
                failWithMalformedOutput(error)
                return
            }
        }

        settle(exitCode: exitCode)
    }

    private func settle(exitCode: Int32) {
        flushCurrentFile()

        if exitCode == 0 || exitCode == 1 || truncated {
            pendingEvents.append(
                .completed(
                    SearchCompletion(
                        queryVersion: query.version,
                        matchedFileCount: matchedFileCount,
                        matchCount: matchCount,
                        truncated: truncated
                    )
                )
            )
        } else {
            let message = String(decoding: stderrBuffer, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            pendingResult = .failure(SearchError.engineReported(exitCode: exitCode, message: message))
        }

        markFinished()
    }

    private func failWithMalformedOutput(_ error: Error) {
        let message: String
        switch error {
        case let parseError as RipgrepStreamParser.ParseError:
            switch parseError {
            case .lineExceedsBufferLimit(let byteCount):
                message = "A single output line exceeded the \(byteCount)-byte bound."
            case .invalidJSON(let preview):
                message = "Could not decode engine output: \(preview)"
            case .invalidTextOrBytesPayload(let preview):
                message = "Engine output had an invalid text/bytes payload: \(preview)"
            }
        default:
            message = String(describing: error)
        }
        pendingResult = .failure(SearchError.malformedOutput(message))
        if process.isRunning {
            process.terminate()
        }
        markFinished()
    }

    private func markFinished() {
        guard !isFinished else {
            return
        }
        isFinished = true
        // Unconditional safety net: whichever path reached completion
        // (normal EOF on both pipes, malformed output, or cancellation),
        // any readability handler still registered on either pipe must be
        // detached now. An EOF'd pipe stays level-triggered "readable"
        // forever, so a lingering handler becomes a tight, CPU-spinning
        // callback loop instead of going quiet.
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        awaitingCompletionContinuation?.resume()
        awaitingCompletionContinuation = nil
    }

    private func finish(continuation: AsyncThrowingStream<SearchStreamEvent, Error>.Continuation) {
        for event in pendingEvents {
            continuation.yield(event)
        }
        switch pendingResult {
        case .success:
            continuation.finish()
        case .failure(let error):
            continuation.finish(throwing: error)
        }
    }

    private func apply(_ line: RipgrepLine) {
        switch line {
        case .begin, .summary:
            break

        case .end:
            flushCurrentFile()

        case .match(let path, let lineNumber, let lineText, let lineIsValidUTF8, let ranges):
            guard matchCount < query.resultLimit else {
                truncated = true
                return
            }
            if currentPath != path {
                flushCurrentFile()
                currentPath = path
            }
            currentMatches.append(
                SearchMatch(
                    lineNumber: lineNumber,
                    lineText: lineText,
                    lineIsValidUTF8: lineIsValidUTF8,
                    ranges: ranges
                )
            )
            matchCount += ranges.count
            if matchCount >= query.resultLimit {
                truncated = true
            }
        }
    }

    private func flushCurrentFile() {
        guard let path = currentPath, !currentMatches.isEmpty else {
            currentPath = nil
            currentMatches.removeAll()
            return
        }
        let relativePath = Self.relativePath(of: path, root: query.root)
        pendingEvents.append(
            .fileResult(SearchFileResult(relativePath: relativePath, matches: currentMatches))
        )
        matchedFileCount += 1
        currentPath = nil
        currentMatches.removeAll()
    }

    private static func relativePath(of enginePath: String, root: URL) -> String {
        // `RipgrepArguments` always passes "." as the search target (see
        // its comment for why), with `Process.currentDirectoryURL` set to
        // `root`, so ripgrep reports every match path as "./relative/path"
        // relative to that root — never an absolute path.
        if enginePath.hasPrefix("./") {
            return String(enginePath.dropFirst(2))
        }
        if enginePath == "." {
            return root.lastPathComponent
        }
        return enginePath
    }
}
