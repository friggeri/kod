import Foundation
import os

private let connectionLog = Logger(subsystem: "com.kodapp.LanguageClient", category: "connection")

public enum LanguageClientRequestPriority: Equatable, Sendable {
    case interactive
    case normal
    case background
}

/// A server-pushed notification Kod surfaces to callers. Every case here
/// is read-only information; there is no case that could cause Kod to
/// mutate anything.
public enum ServerNotification: Sendable {
    case publishDiagnostics(PublishDiagnosticsParams)
    case workspaceDiagnosticRefresh
    case progress(ProgressToken, WorkDoneProgressValue)
    case logMessage(String)
    case showMessage(String)
    case unknown(method: String)
}

/// One process/connection per language server instance, run entirely on
/// its own actor so the readability-handler callbacks (arbitrary
/// background queue) and caller-driven sends never race (mirrors
/// `WorkspaceTextSearcher`'s `RipgrepProcessSession` isolation pattern).
/// Owns the full request/notification lifecycle: JSON-RPC id bookkeeping,
/// per-request timeouts, `$/cancelRequest`, work-done progress, the
/// explicit state machine, and crash/restart handling (SPEC 6.2).
public actor LanguageServerConnection {
    public struct Configuration: Sendable {
        public var executableURL: URL
        public var arguments: [String]
        public var environment: [String: String]?
        public var rootURL: URL
        public var clientName: String
        public var clientVersion: String
        public var requestTimeout: TimeInterval
        public var shutdownTimeout: TimeInterval
        public var restartBudget: RestartBudget
        public var semanticTokenTypes: [String]
        public var semanticTokenModifiers: [String]
        public var initializationOptions: JSONValue?
        public var workspaceConfiguration: [String: JSONValue]
        public var maxHeaderByteCount: Int
        public var maxMessageByteCount: Int
        /// The trust-before-launch gate (SPEC 6/13), evaluated
        /// immediately before *every* process spawn this connection
        /// performs — the initial `start()` and every automatic
        /// crash-restart alike. Defaults to `.authorized` so callers that
        /// already gate the launch themselves keep working unchanged;
        /// `LanguageWorkspaceService` always passes its own workspace
        /// gate through, so a revoked workspace can never be relaunched
        /// behind the host's back by the restart path.
        public var launchAuthorization: WorkspaceLaunchAuthorization

        public init(
            executableURL: URL,
            arguments: [String],
            environment: [String: String]? = nil,
            rootURL: URL,
            clientName: String = "Kod",
            clientVersion: String = "0.1.0",
            requestTimeout: TimeInterval = 10,
            shutdownTimeout: TimeInterval = 3,
            restartBudget: RestartBudget = RestartBudget(),
            semanticTokenTypes: [String] = [],
            semanticTokenModifiers: [String] = [],
            initializationOptions: JSONValue? = nil,
            workspaceConfiguration: [String: JSONValue] = [:],
            maxHeaderByteCount: Int = 8 * 1_024,
            maxMessageByteCount: Int = 64 * 1_024 * 1_024,
            launchAuthorization: WorkspaceLaunchAuthorization = .authorized
        ) {
            self.executableURL = executableURL
            self.arguments = arguments
            self.environment = environment
            self.rootURL = rootURL
            self.clientName = clientName
            self.clientVersion = clientVersion
            self.requestTimeout = requestTimeout
            self.shutdownTimeout = shutdownTimeout
            self.restartBudget = restartBudget
            self.semanticTokenTypes = semanticTokenTypes
            self.semanticTokenModifiers = semanticTokenModifiers
            self.initializationOptions = initializationOptions
            self.workspaceConfiguration = workspaceConfiguration
            self.maxHeaderByteCount = maxHeaderByteCount
            self.maxMessageByteCount = maxMessageByteCount
            self.launchAuthorization = launchAuthorization
        }
    }

    private struct PendingRequest {
        let method: String
        let priority: LanguageClientRequestPriority
        let continuation: CheckedContinuation<JSONValue?, Error>
        var timeoutTask: Task<Void, Never>?
    }

    private let configuration: Configuration
    private let notificationHandler: @Sendable (ServerNotification) -> Void
    private let stateHandler: @Sendable (LanguageServerState) -> Void

    public private(set) var state: LanguageServerState = .stopped {
        didSet {
            guard state != oldValue else {
                return
            }
            stateHandler(state)
        }
    }
    public private(set) var serverCapabilities: ServerCapabilities?

    /// Methods successfully dynamically registered via
    /// `client/registerCapability` (read-only only; see
    /// `handleRegisterCapability`). A capability check should treat a
    /// method as available if either the static `ServerCapabilities`
    /// says so or it appears here — some servers only advertise certain
    /// read-only capabilities dynamically rather than in `initialize`.
    public private(set) var dynamicallyRegisteredMethods: Set<String> = []

    /// Whether `method` is currently usable against this server, per
    /// either static `initialize` capabilities or a subsequent read-only
    /// dynamic registration. `staticallyAdvertised` should already
    /// reflect whatever `ServerCapabilities` field gates that specific
    /// feature (e.g. `hoverProvider`).
    public func isAvailable(_ method: LanguageClientOutboundMethod, staticallyAdvertised: Bool) -> Bool {
        staticallyAdvertised || dynamicallyRegisteredMethods.contains(method.rawValue)
    }

    private var transport: LanguageServerProcessTransport?
    private var idGenerator = JSONRPCIDGenerator()
    private var pendingRequests: [JSONRPCID: PendingRequest] = [:]
    private var readLoopTask: Task<Void, Never>?
    private var restartBudget: RestartBudget
    private var isShuttingDown = false
    private var indexingProgressTokens: Set<ProgressToken> = []
    /// Monotonic identifier of the most recent process launch. Every
    /// transport, read loop, and stream-end callback is stamped with the
    /// launch it belongs to, so a callback that lands after that launch
    /// was superseded or torn down is identifiable rather than
    /// indistinguishable from the live one.
    private var launchEpoch = 0
    /// The launch whose transport this connection currently owns, i.e.
    /// the only one allowed to deliver messages or drive crash handling.
    /// `nil` whenever no launch is live: before the first `start()`,
    /// after a failed start's cleanup, after a crash has been taken over
    /// by the restart path, and after `shutdown()`.
    private var activeLaunchEpoch: Int?
    /// The launch that completed its `initialize`/`initialized`
    /// handshake. Only such a launch's transport loss is an unexpected
    /// *crash*; a transport that dies before or during the handshake is
    /// reported by the `start()`/restart flow that is awaiting it, which
    /// keeps a failed initialization from being restarted behind that
    /// caller's back.
    private var handshakeCompletedEpoch: Int?

    public init(
        configuration: Configuration,
        onStateChange: @escaping @Sendable (LanguageServerState) -> Void = { _ in },
        onNotification: @escaping @Sendable (ServerNotification) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.restartBudget = configuration.restartBudget
        self.stateHandler = onStateChange
        self.notificationHandler = onNotification
    }

    public var stderrLog: String {
        get async {
            await transport?.stderrCapture.snapshot() ?? ""
        }
    }

    // MARK: - Lifecycle

    /// Launches the process and performs the `initialize`/`initialized`
    /// handshake. Only read-only capabilities are advertised (SPEC 6.1).
    /// Refuses to launch anything for a workspace whose launch
    /// authorization says no, throwing `LanguageClientError.notTrusted`.
    public func start() async throws {
        state = .starting
        do {
            try await launchAndInitialize()
        } catch {
            if case LanguageClientError.notTrusted = error {
                await cleanUpFailedStart()
                state = .disabled(reason: Self.notTrustedReason)
                throw error
            }
            let preservesMissingState: Bool
            if case .missing = state {
                preservesMissingState = true
            } else {
                preservesMissingState = false
            }
            await cleanUpFailedStart()
            if !preservesMissingState {
                state = .crashed(reason: "Language server initialization failed: \(Self.failureReason(error))")
            }
            throw error
        }
    }

    /// The single reason string used wherever a launch was refused,
    /// including after an automatic restart attempt.
    static let notTrustedReason =
        "Workspace is not trusted; no language server process was launched. Manual restart required after granting trust."

    private func cleanUpFailedStart() async {
        // Detach the failed launch first, and synchronously: from here on
        // its transport is being torn down by this flow, so the stream
        // end that tear-down produces must not be mistaken for a crash of
        // a running server and must not initiate an automatic restart.
        activeLaunchEpoch = nil
        handshakeCompletedEpoch = nil
        isShuttingDown = true
        readLoopTask?.cancel()
        readLoopTask = nil
        for (_, pending) in pendingRequests {
            pending.timeoutTask?.cancel()
            pending.continuation.resume(throwing: LanguageClientError.notConnected)
        }
        pendingRequests.removeAll()
        serverCapabilities = nil
        dynamicallyRegisteredMethods.removeAll()
        let failedTransport = transport
        transport = nil
        await failedTransport?.forceKill()
        isShuttingDown = false
    }

    private static func failureReason(_ error: Error) -> String {
        if case LanguageClientError.serverError(let responseError) = error {
            return responseError.message
        }
        return String(describing: error)
    }

    private func launchAndInitialize() async throws {
        // The one and only place this connection creates a transport, so
        // gating here gates every process spawn: the first `start()` and
        // every automatic crash-restart. Evaluated fresh each time and
        // never cached, so a workspace whose trust is revoked between a
        // crash and its restart is refused rather than silently relaunched.
        guard await configuration.launchAuthorization.isAuthorized() else {
            throw LanguageClientError.notTrusted
        }
        dynamicallyRegisteredMethods.removeAll()
        // Stamp this launch. Everything the transport below produces —
        // inbound messages and the eventual stream end — carries this
        // epoch, so callbacks from a superseded or torn-down launch are
        // inert instead of racing the launch that replaced them.
        launchEpoch += 1
        let epoch = launchEpoch
        activeLaunchEpoch = epoch
        handshakeCompletedEpoch = nil
        let transport = LanguageServerProcessTransport(
            executableURL: configuration.executableURL,
            arguments: configuration.arguments,
            environment: configuration.environment,
            maxHeaderByteCount: configuration.maxHeaderByteCount,
            maxMessageByteCount: configuration.maxMessageByteCount
        )
        self.transport = transport

        let stream: AsyncStream<Data>
        do {
            stream = try await transport.start(onFramingError: { [weak self] error in
                guard let self else {
                    return
                }
                Task { await self.handleFramingError(error) }
            })
        } catch {
            state = .missing(reason: "\(error)")
            throw error
        }

        readLoopTask?.cancel()
        readLoopTask = Task { [weak self] in
            for await data in stream {
                await self?.handleIncoming(data, epoch: epoch)
            }
            await self?.handleStreamEnded(epoch: epoch)
        }

        let textDocumentCapabilities = ClientCapabilities.TextDocument(
            semanticTokens: ClientCapabilities.TextDocument.SemanticTokens(
                tokenTypes: configuration.semanticTokenTypes,
                tokenModifiers: configuration.semanticTokenModifiers
            )
        )
        let params = InitializeParams(
            processId: Int(ProcessInfo.processInfo.processIdentifier),
            clientInfo: InitializeParams.ClientInfo(
                name: configuration.clientName,
                version: configuration.clientVersion
            ),
            rootUri: DocumentURI(fileURL: configuration.rootURL),
            capabilities: ClientCapabilities(textDocument: textDocumentCapabilities),
            workspaceFolders: [
                WorkspaceFolder(
                    uri: DocumentURI(fileURL: configuration.rootURL),
                    name: configuration.rootURL.lastPathComponent
                )
            ],
            initializationOptions: configuration.initializationOptions
        )

        let result: InitializeResult = try await sendRequest(.initialize, params: params)
        serverCapabilities = result.capabilities
        try await sendNotificationUnchecked(.initialized, params: EmptyParams())
        // Only a launch that got this far owns a *running* server, and so
        // only its transport loss is an unexpected crash worth restarting
        // automatically.
        handshakeCompletedEpoch = epoch
        state = .ready
    }

    /// Sends `shutdown` then `exit`, waiting up to `shutdownTimeout`
    /// before force-killing the process (SPEC 6.2: "graceful
    /// shutdown/exit, hard timeout fallback").
    public func shutdown() async {
        guard let transport, state != .stopped, !isShuttingDown else {
            return
        }
        isShuttingDown = true
        state = .stopping

        var shutdownSucceeded = false
        do {
            _ = try await sendRawRequest(.shutdown, params: EmptyParams(), timeout: configuration.shutdownTimeout)
            shutdownSucceeded = true
        } catch {
            shutdownSucceeded = false
        }

        if shutdownSucceeded {
            try? await sendNotificationUnchecked(.exit, params: EmptyParams())
        }

        readLoopTask?.cancel()
        // The shutdown round trip is over, so this launch no longer owns
        // anything: the read loop's imminent stream end belongs to this
        // shutdown, not to a crashed server.
        activeLaunchEpoch = nil
        handshakeCompletedEpoch = nil
        for (_, pending) in pendingRequests {
            pending.timeoutTask?.cancel()
            pending.continuation.resume(throwing: LanguageClientError.notConnected)
        }
        pendingRequests.removeAll()

        if shutdownSucceeded {
            let (_, timedOut) = await Self.race(
                operation: { await transport.waitForTermination() },
                timeoutSeconds: configuration.shutdownTimeout
            )
            if timedOut {
                await transport.forceKill()
            } else {
                await transport.terminate()
            }
        } else {
            await transport.forceKill()
        }
        state = .stopped
        isShuttingDown = false
    }

    /// Races `operation` against a timeout without structured
    /// concurrency's implicit "wait for every child task before
    /// returning" behavior (a `TaskGroup` would otherwise block this
    /// call until `operation` itself finishes, even after the timeout
    /// fires and the caller has moved on to force-killing the process).
    /// Both racers are unstructured `Task`s that report into a single
    /// serialized resume-once box; whichever loses simply finishes later
    /// in the background with no observable effect.
    private static func race<T: Sendable>(
        operation: @escaping @Sendable () async -> T,
        timeoutSeconds: TimeInterval
    ) async -> (value: T?, timedOut: Bool) {
        await withCheckedContinuation { (outer: CheckedContinuation<(T?, Bool), Never>) in
            let box = SingleResumeBox(outer)
            Task {
                let result = await operation()
                await box.resume((result, false))
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                await box.resume((nil, true))
            }
        }
    }

    // MARK: - Outbound requests/notifications (allow-listed only)

    public func sendRequest<Params: Encodable, Result: Decodable>(
        _ method: LanguageClientOutboundMethod,
        params: Params,
        priority: LanguageClientRequestPriority = .normal
    ) async throws -> Result {
        let value: JSONValue? = try await sendRawRequest(
            method,
            params: params,
            priority: priority
        )
        guard let value else {
            throw LanguageClientError.invalidResponse(method: method.rawValue, reason: "empty result")
        }
        do {
            return try value.decoding(as: Result.self)
        } catch {
            throw LanguageClientError.invalidResponse(method: method.rawValue, reason: "\(error)")
        }
    }

    private func sendRawRequest<Params: Encodable>(
        _ method: LanguageClientOutboundMethod,
        params: Params,
        timeout: TimeInterval? = nil,
        priority: LanguageClientRequestPriority = .normal
    ) async throws -> JSONValue? {
        guard let transport else {
            throw LanguageClientError.notConnected
        }
        if priority == .background,
           pendingRequests.values.contains(where: { $0.priority == .interactive }) {
            throw CancellationError()
        }
        if priority == .interactive {
            await preemptBackgroundRequests()
        }
        try Task.checkCancellation()
        let id = idGenerator.nextID()
        let paramsValue = try JSONValue.encoding(params)
        let message = JSONRPCMessage(kind: .request(id: id, method: method.rawValue, params: paramsValue))
        let data = try message.encoded()

        if state.isUsable {
            state = .busy
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue?, Error>) in
                let timeoutSeconds = timeout ?? configuration.requestTimeout
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    guard !Task.isCancelled else {
                        return
                    }
                    await self?.timeoutPendingRequest(id: id, method: method.rawValue)
                }
                pendingRequests[id] = PendingRequest(
                    method: method.rawValue,
                    priority: priority,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                Task {
                    do {
                        try await transport.send(data)
                    } catch {
                        self.failPendingRequestOnSendFailure(id: id, error: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelPendingRequest(id: id) }
        }
    }

    private func failPendingRequestOnSendFailure(id: JSONRPCID, error: Error) {
        guard let pending = pendingRequests.removeValue(forKey: id) else {
            return
        }
        pending.timeoutTask?.cancel()
        pending.continuation.resume(throwing: error)
        finishBusyStateIfIdle()
    }

    public func sendNotification<Params: Encodable>(
        _ method: LanguageClientOutboundMethod,
        params: Params
    ) async throws {
        try await sendNotificationUnchecked(method, params: params)
    }

    private func sendNotificationUnchecked<Params: Encodable>(
        _ method: LanguageClientOutboundMethod,
        params: Params
    ) async throws {
        guard let transport else {
            throw LanguageClientError.notConnected
        }
        let paramsValue = try JSONValue.encoding(params)
        let message = JSONRPCMessage(kind: .notification(method: method.rawValue, params: paramsValue))
        let data = try message.encoded()
        try await transport.send(data)
    }

    private func timeoutPendingRequest(id: JSONRPCID, method: String) async {
        guard let pending = pendingRequests.removeValue(forKey: id) else {
            return
        }
        pending.timeoutTask?.cancel()
        try? await sendNotificationUnchecked(.cancelRequest, params: CancelParams(id: id))
        pending.continuation.resume(throwing: LanguageClientError.timedOut(method: method))
        finishBusyStateIfIdle()
    }

    private func cancelPendingRequest(id: JSONRPCID) async {
        guard let pending = pendingRequests.removeValue(forKey: id) else {
            return
        }
        pending.timeoutTask?.cancel()
        pending.continuation.resume(throwing: CancellationError())
        finishBusyStateIfIdle()
        try? await sendNotificationUnchecked(.cancelRequest, params: CancelParams(id: id))
    }

    private func preemptBackgroundRequests() async {
        let ids = pendingRequests.compactMap { id, request in
            request.priority == .background ? id : nil
        }
        guard !ids.isEmpty else {
            return
        }
        for id in ids {
            guard let pending = pendingRequests.removeValue(forKey: id) else {
                continue
            }
            pending.timeoutTask?.cancel()
            pending.continuation.resume(throwing: CancellationError())
        }
        finishBusyStateIfIdle()
        for id in ids {
            try? await sendNotificationUnchecked(
                .cancelRequest,
                params: CancelParams(id: id)
            )
        }
    }

    private func finishBusyStateIfIdle() {
        if pendingRequests.isEmpty, state == .busy {
            state = .ready
        }
    }

    // MARK: - Inbound dispatch

    private func handleIncoming(_ data: Data, epoch: Int) async {
        // A message from a transport this connection no longer owns
        // describes a server that is already gone; resolving anything
        // with it would let a torn-down launch mutate live state.
        guard epoch == activeLaunchEpoch else {
            return
        }
        let message: JSONRPCMessage
        do {
            message = try JSONRPCMessage.decode(from: data)
        } catch {
            connectionLog.error("Failed to decode inbound message: \(String(describing: error), privacy: .public)")
            return
        }

        switch message.kind {
        case .response(let id, let result, let error):
            handleResponse(id: id, result: result, error: error)

        case .notification(let method, let params):
            handleNotification(method: method, params: params)

        case .request(let id, let method, let params):
            await handleInboundRequest(id: id, method: method, params: params)
        }
    }

    private func handleResponse(id: JSONRPCID?, result: JSONValue?, error: JSONRPCResponseError?) {
        guard let id, let pending = pendingRequests.removeValue(forKey: id) else {
            return
        }
        pending.timeoutTask?.cancel()
        if let error {
            pending.continuation.resume(throwing: LanguageClientError.serverError(error))
        } else {
            pending.continuation.resume(returning: result)
        }
        finishBusyStateIfIdle()
    }

    private func handleNotification(method: String, params: JSONValue?) {
        switch method {
        case "textDocument/publishDiagnostics":
            guard let params, let decoded = try? params.decoding(as: PublishDiagnosticsParams.self) else {
                return
            }
            notificationHandler(.publishDiagnostics(decoded))

        case "$/progress":
            guard let params, let decoded = try? params.decoding(as: ProgressParams.self),
                  let value = WorkDoneProgressValue(jsonValue: decoded.value) else {
                return
            }
            applyProgressToState(token: decoded.token, value: value)
            notificationHandler(.progress(decoded.token, value))

        case "window/logMessage", "window/showMessage":
            guard let params, case .object(let fields) = params,
                  case .string(let text)? = fields["message"] else {
                return
            }
            notificationHandler(method == "window/logMessage" ? .logMessage(text) : .showMessage(text))

        case "$/logTrace":
            break

        default:
            notificationHandler(.unknown(method: method))
        }
    }

    /// Correlates `begin`/`end` `$/progress` pairs by `token` (not by
    /// re-inspecting `end`'s own payload, which per LSP 3.17 need not
    /// repeat `title`) so an indexing-titled `begin` reliably drives the
    /// state back to `.ready` once its matching `end` arrives, even if
    /// other unrelated progress tokens are in flight concurrently.
    private func applyProgressToState(token: ProgressToken, value: WorkDoneProgressValue) {
        switch value.kind {
        case .begin:
            let title = (value.title ?? "").lowercased()
            guard title.contains("index") else {
                return
            }
            indexingProgressTokens.insert(token)
            if state == .ready {
                state = .indexing
            }
        case .end:
            guard indexingProgressTokens.remove(token) != nil else {
                return
            }
            if indexingProgressTokens.isEmpty, state == .indexing {
                state = .ready
            }
        case .report:
            break
        }
    }

    /// Every server-to-client request Kod does not explicitly implement a
    /// read-only response for is rejected with a real JSON-RPC error —
    /// most importantly `client/registerCapability` (dynamic registration
    /// for anything, since Kod supports none dynamically) and
    /// `workspace/applyEdit` (Kod never applies an edit), per SPEC 6.1
    /// and 13.2. There is no silent no-op path.
    private func handleInboundRequest(id: JSONRPCID, method: String, params: JSONValue?) async {
        guard let transport else {
            return
        }
        var responseError: JSONRPCResponseError?
        var resultValue: JSONValue = .null

        if let known = LanguageClientInboundMethod(rawValue: method) {
            switch known {
            case .registerCapability:
                responseError = handleRegisterCapability(params: params)
            case .unregisterCapability:
                handleUnregisterCapability(params: params)
                responseError = nil
            case .applyEdit:
                responseError = .operationNotPermitted(method)
            case .workspaceDiagnosticRefresh:
                responseError = nil
                notificationHandler(.workspaceDiagnosticRefresh)
            case .workspaceConfiguration, .workspaceFolders, .createWorkDoneProgress, .showMessageRequest:
                responseError = nil
                resultValue = respondToSupportedInboundRequest(known, params: params)
            }
        } else {
            responseError = .methodNotFound(method)
        }

        let message = JSONRPCMessage(
            kind: .response(id: id, result: responseError == nil ? resultValue : nil, error: responseError)
        )
        guard let data = try? message.encoded() else {
            return
        }
        try? await transport.send(data)
    }

    /// Inspects a `client/registerCapability` request's full batch of
    /// `registrations` and accepts it only if every one of them names a
    /// method in `LanguageClientOutboundMethod.dynamicallyRegistrableReadOnlyMethods`
    /// — i.e. a capability Kod already knows how to use read-only. Any
    /// registration for a mutating or unrecognized method (including a
    /// malformed registration Kod can't even parse a method out of)
    /// rejects the *entire* batch with `operationNotPermitted`; there is
    /// no partial acceptance that could let one mutating registration
    /// slip through alongside legitimate ones (SPEC 6.1).
    private func handleRegisterCapability(params: JSONValue?) -> JSONRPCResponseError? {
        guard case .object(let fields)? = params, case .array(let registrations)? = fields["registrations"] else {
            return .operationNotPermitted(LanguageClientInboundMethod.registerCapability.rawValue)
        }
        var methods: [String] = []
        for registration in registrations {
            guard case .object(let registrationFields) = registration,
                  case .string(let registrationMethod)? = registrationFields["method"] else {
                return .operationNotPermitted(LanguageClientInboundMethod.registerCapability.rawValue)
            }
            methods.append(registrationMethod)
        }
        guard !methods.isEmpty,
              methods.allSatisfy({ LanguageClientOutboundMethod.dynamicallyRegistrableReadOnlyMethods.contains($0) }) else {
            return .operationNotPermitted(LanguageClientInboundMethod.registerCapability.rawValue)
        }
        dynamicallyRegisteredMethods.formUnion(methods)
        return nil
    }

    /// Unregistering a capability only ever removes something Kod might
    /// use — it can never grant a new one — so it is always accepted
    /// regardless of which method it names (LSP's own field name for
    /// this array really is `unregisterations`).
    private func handleUnregisterCapability(params: JSONValue?) {
        guard case .object(let fields)? = params, case .array(let unregistrations)? = fields["unregisterations"] else {
            return
        }
        for unregistration in unregistrations {
            guard case .object(let unregistrationFields) = unregistration,
                  case .string(let unregistrationMethod)? = unregistrationFields["method"] else {
                continue
            }
            dynamicallyRegisteredMethods.remove(unregistrationMethod)
        }
    }

    private func respondToSupportedInboundRequest(
        _ method: LanguageClientInboundMethod,
        params: JSONValue?
    ) -> JSONValue {
        switch method {
        case .workspaceConfiguration:
            if case .object(let fields)? = params, case .array(let items)? = fields["items"] {
                return .array(items.map { item in
                    guard case .object(let itemFields) = item,
                          case .string(let section)? = itemFields["section"] else {
                        return .null
                    }
                    return configuration.workspaceConfiguration[section] ?? .null
                })
            }
            return .array([])
        case .workspaceFolders:
            return .array([
                .object([
                    "uri": .string(DocumentURI(fileURL: configuration.rootURL).stringValue),
                    "name": .string(configuration.rootURL.lastPathComponent)
                ])
            ])
        case .createWorkDoneProgress:
            return .null
        case .showMessageRequest:
            return .null
        case .registerCapability, .unregisterCapability, .applyEdit, .workspaceDiagnosticRefresh:
            return .null
        }
    }

    private func handleFramingError(_ error: Error) async {
        connectionLog.error("Transport framing error: \(String(describing: error), privacy: .public)")
    }

    /// Handles the end of `epoch`'s message stream: the only place an
    /// unexpected server exit turns into crash/restart handling.
    ///
    /// Two ownership checks make that deterministic. The stream must
    /// belong to the launch this connection still owns — a stream that
    /// ended because its launch was torn down (a failed start's cleanup,
    /// an explicit `shutdown()`, or a superseding relaunch) describes
    /// nothing that is running. And that launch must have completed its
    /// `initialize`/`initialized` handshake — a transport that dies
    /// before the server was ever ready is the failure of the
    /// `start()`/restart flow awaiting it, which reports it to its own
    /// caller; restarting it from here would relaunch a server behind
    /// the back of a `start()` that is in the middle of failing.
    private func handleStreamEnded(epoch: Int) async {
        guard epoch == activeLaunchEpoch, !isShuttingDown, state != .stopped else {
            return
        }
        // Claim the loss exactly once: this transport is dead either way,
        // so no later callback may treat it as live.
        activeLaunchEpoch = nil
        // This callback runs inside the read-loop task. Clear its stored
        // handle before relaunching so launchAndInitialize() does not cancel
        // the task that is performing the automatic restart.
        readLoopTask = nil
        // Fail everything the dead transport can no longer answer before
        // deciding what to do, so an in-flight handshake observes the
        // loss immediately instead of waiting out its request timeout.
        for (_, pending) in pendingRequests {
            pending.timeoutTask?.cancel()
            pending.continuation.resume(throwing: LanguageClientError.notConnected)
        }
        pendingRequests.removeAll()
        serverCapabilities = nil
        dynamicallyRegisteredMethods.removeAll()

        guard epoch == handshakeCompletedEpoch else {
            return
        }
        handshakeCompletedEpoch = nil

        let exitCode = await transport?.waitForTermination() ?? -1
        let reason = "Server exited unexpectedly (code \(exitCode))."

        guard restartBudget.recordCrashAndCheckIfRestartAllowed() else {
            state = .disabled(reason: "\(reason) Restart budget exhausted; manual restart required.")
            return
        }

        state = .crashed(reason: reason)
        await restartAfterCrash(reason: reason)
    }

    /// Relaunches a crashed server, re-consulting the launch gate and the
    /// restart budget for every attempt. A failed attempt is retried from
    /// here rather than from the failed attempt's stream end, so the
    /// crash-loop → budget → `.disabled` progression is driven by one
    /// owner instead of by racing teardown callbacks.
    private func restartAfterCrash(reason: String) async {
        while true {
            state = .starting
            do {
                try await launchAndInitialize()
                return
            } catch {
                await cleanUpFailedStart()
                if case LanguageClientError.notTrusted = error {
                    // Trust was revoked while the server was running. No
                    // replacement process is launched, and the connection
                    // stays `.disabled` rather than `.crashed`, so nothing
                    // retries this automatically.
                    state = .disabled(reason: "\(reason) \(Self.notTrustedReason)")
                    return
                }
                guard restartBudget.recordCrashAndCheckIfRestartAllowed() else {
                    state = .disabled(reason: "\(reason) Restart budget exhausted; manual restart required.")
                    return
                }
                state = .crashed(reason: "\(reason) Automatic restart failed: \(error)")
            }
        }
    }
}

/// An empty JSON object, used for requests/notifications with no
/// meaningful body (`initialized`, `shutdown`, `exit`).
struct EmptyParams: Encodable {}

/// Resumes a `CheckedContinuation` at most once, safely from either of
/// two concurrently-racing unstructured `Task`s.
private actor SingleResumeBox<T: Sendable> {
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        guard let continuation else {
            return
        }
        self.continuation = nil
        continuation.resume(returning: value)
    }
}
