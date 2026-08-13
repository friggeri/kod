import Foundation
import LanguageClient

// A deterministic, scenario-driven stdio LSP fixture used only by
// `LanguageClientTests`. It speaks the exact same `Content-Length`-framed
// JSON-RPC base protocol `LanguageClient` implements (imported directly,
// not reimplemented) so tests exercise the real framing/encoding paths
// end-to-end against a real child process, not just in-process mocks.
//
// Scenario is selected by argv[1]; unrecognized/missing selects "normal".
// An optional `FAKE_LSP_STATE_FILE` environment variable, if set, gets
// one appended line per observed event used by fixture tests (currently
// `didOpen` and `cancel`) to inspect process behavior across stdio.

let scenario = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "normal"

let stdin = FileHandle.standardInput
let stdout = FileHandle.standardOutput
let stderr = FileHandle.standardError
let writeLock = NSLock()

func writeFramed(_ data: Data) {
    let framed = JSONRPCFramingEncoder.frame(data)
    writeLock.lock()
    stdout.write(framed)
    writeLock.unlock()
}

func send(_ message: JSONRPCMessage) {
    guard let data = try? message.encoded() else {
        return
    }
    writeFramed(data)
}

func respond(id: JSONRPCID, result: JSONValue) {
    send(JSONRPCMessage(kind: .response(id: id, result: result, error: nil)))
}

func respondError(id: JSONRPCID, code: Int, message: String) {
    send(JSONRPCMessage(kind: .response(id: id, result: nil, error: JSONRPCResponseError(code: code, message: message))))
}

func notify(_ method: String, _ params: JSONValue) {
    send(JSONRPCMessage(kind: .notification(method: method, params: params)))
}

func requestClient(id: JSONRPCID, method: String, params: JSONValue) {
    send(JSONRPCMessage(kind: .request(id: id, method: method, params: params)))
}

/// Thread-safe registry of `$/cancelRequest` ids seen so far, used by the
/// "cancel" scenario's polling responder.
final class CancelledIDRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String> = []

    private func key(_ id: JSONRPCID) -> String {
        switch id {
        case .number(let value): return "n:\(value)"
        case .string(let value): return "s:\(value)"
        }
    }

    func markCancelled(_ id: JSONRPCID) {
        lock.lock()
        ids.insert(key(id))
        lock.unlock()
    }

    func isCancelled(_ id: JSONRPCID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ids.contains(key(id))
    }
}

final class RequestCountRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func increment(_ method: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        counts[method, default: 0] += 1
        return counts[method, default: 0]
    }
}

let cancelledIDs = CancelledIDRegistry()
let requestCounts = RequestCountRegistry()
let initializationOptionsAccepted = LockedFlag()
let stateFilePath = ProcessInfo.processInfo.environment["FAKE_LSP_STATE_FILE"]
let stateFileLock = NSLock()

func appendStateFileLine(_ line: String) {
    guard let stateFilePath else {
        return
    }
    stateFileLock.lock()
    defer { stateFileLock.unlock() }
    let entry = line + "\n"
    if let handle = FileHandle(forWritingAtPath: stateFilePath) {
        handle.seekToEndOfFile()
        handle.write(Data(entry.utf8))
        handle.closeFile()
    } else {
        try? entry.write(toFile: stateFilePath, atomically: true, encoding: .utf8)
    }
}

let legendTokenTypes = ["namespace", "type", "class", "enum", "function", "variable"]
let legendTokenModifiers = ["declaration", "readonly"]

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

func initializeResult() -> JSONValue {
    var capabilities: [String: JSONValue] = [
        "hoverProvider": .bool(true),
        "definitionProvider": .bool(true),
        "referencesProvider": .bool(true),
        "documentSymbolProvider": .bool(true),
        "workspaceSymbolProvider": .bool(true),
        "semanticTokensProvider": .object([
            "legend": .object([
                "tokenTypes": .array(legendTokenTypes.map(JSONValue.string)),
                "tokenModifiers": .array(legendTokenModifiers.map(JSONValue.string))
            ]),
            "full": .bool(true)
        ]),
        "diagnosticProvider": .object([
            "interFileDependencies": .bool(false),
            "workspaceDiagnostics": .bool(false)
        ])
    ]
    if scenario != "normal-utf16" {
        capabilities["positionEncoding"] = .string("utf-8")
    }
    // "capability-absent" leaves every Phase 7 extended capability
    // unadvertised (both statically and never dynamically registered),
    // so a client under test must hide/disable those features rather
    // than erroring when it tries to use them.
    if scenario != "capability-absent" {
        capabilities["declarationProvider"] = .bool(true)
        capabilities["typeDefinitionProvider"] = .bool(true)
        capabilities["implementationProvider"] = .bool(true)
        capabilities["documentHighlightProvider"] = .bool(true)
        capabilities["foldingRangeProvider"] = .bool(true)
        capabilities["selectionRangeProvider"] = .bool(true)
        capabilities["documentLinkProvider"] = .bool(true)
        capabilities["inlayHintProvider"] = .bool(true)
        capabilities["signatureHelpProvider"] = .bool(true)
        capabilities["callHierarchyProvider"] = .bool(true)
        capabilities["typeHierarchyProvider"] = .bool(true)
    }
    return .object(["capabilities": .object(capabilities)])
}

func handleInitialize(id: JSONRPCID, params: JSONValue?) {
    if scenario == "initialize-error" {
        respondError(
            id: id,
            code: JSONRPCErrorCode.internalError,
            message: "No compatible language runtime was found."
        )
        return
    }
    if scenario == "workspace-configuration",
       case .object(let fields)? = params,
       fields["initializationOptions"] == .object(["safe": .bool(true)]),
       case .object(let capabilities)? = fields["capabilities"],
       case .object(let workspace)? = capabilities["workspace"],
       workspace["configuration"] == .bool(true) {
        initializationOptionsAccepted.set(true)
    }
    respond(id: id, result: initializeResult())
}

func handleInitialized() {
    switch scenario {
    case "mutation-attempt":
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            requestClient(
                id: .string("mutate-register"),
                method: "client/registerCapability",
                params: .object([
                    "registrations": .array([
                        .object([
                            "id": .string("1"),
                            "method": .string("textDocument/rename")
                        ])
                    ])
                ])
            )
            requestClient(
                id: .string("mutate-apply-edit"),
                method: "workspace/applyEdit",
                params: .object([
                    "label": .string("test edit"),
                    "edit": .object(["changes": .object([:])])
                ])
            )
        }

    // A batch containing only methods Kod already treats as read-only
    // (SPEC 6.1's dynamic-registration handling) must be accepted.
    case "dynamic-registration-read-only":
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            requestClient(
                id: .string("register-read-only"),
                method: "client/registerCapability",
                params: .object([
                    "registrations": .array([
                        .object(["id": .string("1"), "method": .string("textDocument/inlayHint")]),
                        .object(["id": .string("2"), "method": .string("textDocument/foldingRange")])
                    ])
                ])
            )
        }

    // A batch mixing one legitimate read-only method with one mutating
    // method must be rejected in full — no partial acceptance.
    case "dynamic-registration-mixed-batch":
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            requestClient(
                id: .string("register-mixed"),
                method: "client/registerCapability",
                params: .object([
                    "registrations": .array([
                        .object(["id": .string("1"), "method": .string("textDocument/inlayHint")]),
                        .object(["id": .string("2"), "method": .string("textDocument/codeAction")])
                    ])
                ])
            )
        }

    case "dynamic-registration-then-unregister":
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            requestClient(
                id: .string("register-then-unregister"),
                method: "client/registerCapability",
                params: .object([
                    "registrations": .array([
                        .object(["id": .string("1"), "method": .string("textDocument/inlayHint")])
                    ])
                ])
            )
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                requestClient(
                    id: .string("unregister"),
                    method: "client/unregisterCapability",
                    params: .object([
                        "unregisterations": .array([
                            .object(["id": .string("1"), "method": .string("textDocument/inlayHint")])
                        ])
                    ])
                )
            }
        }

    case "progress":
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            requestClient(
                id: .string("create-progress"),
                method: "window/workDoneProgress/create",
                params: .object(["token": .string("indexing")])
            )
            notify("$/progress", .object([
                "token": .string("indexing"),
                "value": .object(["kind": .string("begin"), "title": .string("Indexing"), "percentage": .number(0)])
            ]))
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                notify("$/progress", .object([
                    "token": .string("indexing"),
                    "value": .object(["kind": .string("report"), "percentage": .number(50)])
                ]))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                notify("$/progress", .object([
                    "token": .string("indexing"),
                    "value": .object(["kind": .string("end"), "message": .string("Done")])
                ]))
            }
        }

    case "workspace-configuration":
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            requestClient(
                id: .string("workspace-configuration"),
                method: "workspace/configuration",
                params: .object([
                    "items": .array([
                        .object(["section": .string("yaml")]),
                        .object(["section": .string("missing")])
                    ])
                ])
            )
        }

    case "crash-immediately":
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            exit(1)
        }

    case "framing-error-header":
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            writeLock.lock()
            stdout.write(Data("Content-Length: notanumber\r\n\r\n".utf8))
            writeLock.unlock()
        }

    case "framing-error-oversized":
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            writeLock.lock()
            stdout.write(Data("Content-Length: 200000000\r\n\r\n".utf8))
            writeLock.unlock()
        }

    case "stderr-noisy":
        DispatchQueue.global().async {
            let chunk = Data(String(repeating: "E", count: 4_096).utf8)
            for _ in 0..<256 {
                stderr.write(chunk)
            }
        }

    default:
        break
    }
}

func lspRange(startLine: Int, startChar: Int, endLine: Int, endChar: Int) -> JSONValue {
    .object([
        "start": .object(["line": .number(Double(startLine)), "character": .number(Double(startChar))]),
        "end": .object(["line": .number(Double(endLine)), "character": .number(Double(endChar))])
    ])
}

func handleHover(id: JSONRPCID, params: JSONValue?) {
    switch scenario {
    case "timeout":
        return // never respond; client-side timeout should fire.

    case "cancel":
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if cancelledIDs.isCancelled(id) {
                    respondError(id: id, code: JSONRPCErrorCode.requestCancelled, message: "cancelled")
                    return
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            respond(id: id, result: .object(["contents": .object(["kind": .string("plaintext"), "value": .string("late")])]))
        }

    case "malformed-json-body":
        let body = Data("not json at all".utf8)
        writeFramed(Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body)

    case "invalid-range":
        respond(id: id, result: .object([
            "contents": .object(["kind": .string("plaintext"), "value": .string("stale hover")]),
            "range": lspRange(startLine: 999_999, startChar: 0, endLine: 999_999, endChar: 5)
        ]))

    case "oversized":
        writeLock.lock()
        stdout.write(Data("Content-Length: 200000000\r\n\r\n".utf8))
        writeLock.unlock()

    default:
        respond(id: id, result: .object([
            "contents": .object(["kind": .string("plaintext"), "value": .string("Fake hover")]),
            "range": lspRange(startLine: 0, startChar: 0, endLine: 0, endChar: 4)
        ]))
    }
}

func extractURI(_ params: JSONValue?) -> String {
    guard case .object(let fields)? = params,
          case .object(let textDocument)? = fields["textDocument"],
          case .string(let uri)? = textDocument["uri"] else {
        return "file:///unknown"
    }
    return uri
}

func handleDefinition(id: JSONRPCID, params: JSONValue?) {
    if scenario == "invalid-range" {
        respond(id: id, result: .object([
            "uri": .string(extractURI(params)),
            "range": lspRange(startLine: -1, startChar: 0, endLine: -1, endChar: 3)
        ]))
        return
    }
    respond(id: id, result: .object([
        "uri": .string(extractURI(params)),
        "range": lspRange(startLine: 0, startChar: 0, endLine: 0, endChar: 4)
    ]))
}

func handleReferences(id: JSONRPCID, params: JSONValue?) {
    let uri = extractURI(params)
    respond(id: id, result: .array([
        .object(["uri": .string(uri), "range": lspRange(startLine: 0, startChar: 0, endLine: 0, endChar: 4)])
    ]))
}

func handleDocumentSymbol(id: JSONRPCID) {
    respond(id: id, result: .array([
        .object([
            "name": .string("FakeSymbol"),
            "kind": .number(12),
            "range": lspRange(startLine: 0, startChar: 0, endLine: 0, endChar: 10),
            "selectionRange": lspRange(startLine: 0, startChar: 0, endLine: 0, endChar: 10),
            "children": .array([])
        ])
    ]))
}

func handleWorkspaceSymbol(id: JSONRPCID, params: JSONValue?) {
    var uri = "file:///unknown"
    if case .object(let fields)? = params, case .string(let query)? = fields["query"], !query.isEmpty {
        uri = "file:///workspace-symbol-target"
    }
    respond(id: id, result: .array([
        .object([
            "name": .string("FakeWorkspaceSymbol"),
            "kind": .number(12),
            "location": .object(["uri": .string(uri), "range": lspRange(startLine: 0, startChar: 0, endLine: 0, endChar: 4)])
        ])
    ]))
}

func handleDiagnostic(id: JSONRPCID) {
    respond(id: id, result: .object([
        "kind": .string("full"),
        "items": .array([
            .object([
                "range": lspRange(startLine: 0, startChar: 0, endLine: 0, endChar: 4),
                "severity": .number(2),
                "message": .string("Fake pulled diagnostic")
            ])
        ])
    ]))
}

func handleDeclaration(id: JSONRPCID, params: JSONValue?) {
    respond(id: id, result: .object([
        "uri": .string(extractURI(params)),
        "range": lspRange(startLine: 0, startChar: 0, endLine: 0, endChar: 4)
    ]))
}

func handleTypeDefinition(id: JSONRPCID, params: JSONValue?) {
    respond(id: id, result: .object([
        "uri": .string(extractURI(params)),
        "range": lspRange(startLine: 0, startChar: 0, endLine: 0, endChar: 4)
    ]))
}

func handleImplementation(id: JSONRPCID, params: JSONValue?) {
    respond(id: id, result: .object([
        "uri": .string(extractURI(params)),
        "range": lspRange(startLine: 0, startChar: 0, endLine: 0, endChar: 4)
    ]))
}

func handleDocumentHighlight(id: JSONRPCID) {
    if scenario == "invalid-range" {
        respond(id: id, result: .array([
            .object(["range": lspRange(startLine: 999_999, startChar: 0, endLine: 999_999, endChar: 4), "kind": .number(1)])
        ]))
        return
    }
    respond(id: id, result: .array([
        .object(["range": lspRange(startLine: 0, startChar: 0, endLine: 0, endChar: 4), "kind": .number(1)])
    ]))
}

func handleFoldingRange(id: JSONRPCID) {
    if scenario == "invalid-range" {
        respond(id: id, result: .array([
            .object(["startLine": .number(999_999), "endLine": .number(999_999)])
        ]))
        return
    }
    respond(id: id, result: .array([
        .object(["startLine": .number(0), "endLine": .number(0), "kind": .string("region")])
    ]))
}

func handleSelectionRange(id: JSONRPCID) {
    respond(id: id, result: .array([
        .object([
            "range": lspRange(startLine: 0, startChar: 0, endLine: 0, endChar: 4),
            "parent": .object([
                "range": lspRange(startLine: 0, startChar: 0, endLine: 0, endChar: 10)
            ])
        ])
    ]))
}

func handleDocumentLink(id: JSONRPCID) {
    switch scenario {
    case "unsafe-document-link":
        // A server-provided `command:` URI must never be surfaced or
        // navigated to (SPEC 13.2) — this scenario proves Kod discards
        // it rather than treating it as clickable.
        respond(id: id, result: .array([
            .object([
                "range": lspRange(startLine: 0, startChar: 0, endLine: 0, endChar: 4),
                "target": .string("command:kod.doSomethingMutating")
            ]),
            .object([
                "range": lspRange(startLine: 1, startChar: 0, endLine: 1, endChar: 4),
                "target": .string("https://example.com/docs")
            ])
        ]))
    default:
        respond(id: id, result: .array([
            .object([
                "range": lspRange(startLine: 0, startChar: 0, endLine: 0, endChar: 4),
                "target": .string("https://example.com/docs"),
                "tooltip": .string("Docs")
            ])
        ]))
    }
}

func handleInlayHint(id: JSONRPCID) {
    respond(id: id, result: .array([
        .object([
            "position": .object(["line": .number(0), "character": .number(4)]),
            "label": .string(": Int"),
            "kind": .number(1)
        ])
    ]))
}

func handleSignatureHelp(id: JSONRPCID) {
    respond(id: id, result: .object([
        "signatures": .array([
            .object([
                "label": .string("fake(x: Int) -> Int"),
                "parameters": .array([.object(["label": .string("x: Int")])])
            ])
        ]),
        "activeSignature": .number(0),
        "activeParameter": .number(0)
    ]))
}

func fakeHierarchyItem(uri: String, name: String = "FakeSymbol") -> JSONValue {
    .object([
        "name": .string(name),
        "kind": .number(12),
        "uri": .string(uri),
        "range": lspRange(startLine: 0, startChar: 0, endLine: 0, endChar: 10),
        "selectionRange": lspRange(startLine: 0, startChar: 0, endLine: 0, endChar: 10),
        "data": .object(["opaque": .string("fake-hierarchy-data")])
    ])
}

func handlePrepareCallHierarchy(id: JSONRPCID, params: JSONValue?) {
    respond(id: id, result: .array([fakeHierarchyItem(uri: extractURI(params))]))
}

func handleCallHierarchyIncomingCalls(id: JSONRPCID, params: JSONValue?) {
    var uri = "file:///unknown"
    if case .object(let fields)? = params, case .object(let item)? = fields["item"], case .string(let itemURI)? = item["uri"] {
        uri = itemURI
    }
    respond(id: id, result: .array([
        .object([
            "from": fakeHierarchyItem(uri: uri, name: "Caller"),
            "fromRanges": .array([lspRange(startLine: 1, startChar: 0, endLine: 1, endChar: 4)])
        ])
    ]))
}

func handleCallHierarchyOutgoingCalls(id: JSONRPCID, params: JSONValue?) {
    var uri = "file:///unknown"
    if case .object(let fields)? = params, case .object(let item)? = fields["item"], case .string(let itemURI)? = item["uri"] {
        uri = itemURI
    }
    respond(id: id, result: .array([
        .object([
            "to": fakeHierarchyItem(uri: uri, name: "Callee"),
            "fromRanges": .array([lspRange(startLine: 2, startChar: 0, endLine: 2, endChar: 4)])
        ])
    ]))
}

func handlePrepareTypeHierarchy(id: JSONRPCID, params: JSONValue?) {
    respond(id: id, result: .array([fakeHierarchyItem(uri: extractURI(params))]))
}

func handleTypeHierarchySupertypes(id: JSONRPCID, params: JSONValue?) {
    var uri = "file:///unknown"
    if case .object(let fields)? = params, case .object(let item)? = fields["item"], case .string(let itemURI)? = item["uri"] {
        uri = itemURI
    }
    respond(id: id, result: .array([fakeHierarchyItem(uri: uri, name: "Supertype")]))
}

func handleTypeHierarchySubtypes(id: JSONRPCID, params: JSONValue?) {
    var uri = "file:///unknown"
    if case .object(let fields)? = params, case .object(let item)? = fields["item"], case .string(let itemURI)? = item["uri"] {
        uri = itemURI
    }
    respond(id: id, result: .array([fakeHierarchyItem(uri: uri, name: "Subtype")]))
}

func handleSemanticTokens(id: JSONRPCID) {
    if scenario == "priority",
       requestCounts.increment("textDocument/semanticTokens/full") == 1 {
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if cancelledIDs.isCancelled(id) {
                    respondError(
                        id: id,
                        code: JSONRPCErrorCode.requestCancelled,
                        message: "cancelled"
                    )
                    return
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            respondError(id: id, code: JSONRPCErrorCode.internalError, message: "not preempted")
        }
        return
    }
    respond(id: id, result: .object([
        "resultId": .string("1"),
        "data": .array([.number(0), .number(0), .number(4), .number(3), .number(0)])
    ]))
}

func handleShutdown(id: JSONRPCID) {
    respond(id: id, result: .null)
}

func handleRequest(id: JSONRPCID, method: String, params: JSONValue?) {
    appendStateFileLine("request:\(method)")
    switch method {
    case "initialize":
        handleInitialize(id: id, params: params)
    case "shutdown":
        handleShutdown(id: id)
    case "textDocument/hover":
        handleHover(id: id, params: params)
    case "textDocument/definition":
        handleDefinition(id: id, params: params)
    case "textDocument/references":
        handleReferences(id: id, params: params)
    case "textDocument/documentSymbol":
        handleDocumentSymbol(id: id)
    case "workspace/symbol":
        handleWorkspaceSymbol(id: id, params: params)
    case "textDocument/diagnostic":
        handleDiagnostic(id: id)
    case "textDocument/semanticTokens/full":
        handleSemanticTokens(id: id)
    case "textDocument/declaration":
        handleDeclaration(id: id, params: params)
    case "textDocument/typeDefinition":
        handleTypeDefinition(id: id, params: params)
    case "textDocument/implementation":
        handleImplementation(id: id, params: params)
    case "textDocument/documentHighlight":
        handleDocumentHighlight(id: id)
    case "textDocument/foldingRange":
        handleFoldingRange(id: id)
    case "textDocument/selectionRange":
        handleSelectionRange(id: id)
    case "textDocument/documentLink":
        handleDocumentLink(id: id)
    case "textDocument/inlayHint":
        handleInlayHint(id: id)
    case "textDocument/signatureHelp":
        handleSignatureHelp(id: id)
    case "textDocument/prepareCallHierarchy":
        handlePrepareCallHierarchy(id: id, params: params)
    case "callHierarchy/incomingCalls":
        handleCallHierarchyIncomingCalls(id: id, params: params)
    case "callHierarchy/outgoingCalls":
        handleCallHierarchyOutgoingCalls(id: id, params: params)
    case "textDocument/prepareTypeHierarchy":
        handlePrepareTypeHierarchy(id: id, params: params)
    case "typeHierarchy/supertypes":
        handleTypeHierarchySupertypes(id: id, params: params)
    case "typeHierarchy/subtypes":
        handleTypeHierarchySubtypes(id: id, params: params)
    default:
        respondError(id: id, code: JSONRPCErrorCode.methodNotFound, message: "Unhandled method: \(method)")
    }
}

func handleResponseFromClient(id: JSONRPCID?, result: JSONValue?, error: JSONRPCResponseError?) {
    guard case .string(let idString)? = id else {
        return
    }
    let outcome = error.map { "rejected:\($0.code)" } ?? "accepted"
    switch idString {
    case "mutate-register":
        notify("window/logMessage", .object(["type": .number(3), "message": .string("registerCapability:\(outcome)")]))
    case "mutate-apply-edit":
        notify("window/logMessage", .object(["type": .number(3), "message": .string("applyEdit:\(outcome)")]))
    case "register-read-only":
        notify("window/logMessage", .object(["type": .number(3), "message": .string("registerReadOnly:\(outcome)")]))
    case "register-mixed":
        notify("window/logMessage", .object(["type": .number(3), "message": .string("registerMixed:\(outcome)")]))
    case "register-then-unregister":
        notify("window/logMessage", .object(["type": .number(3), "message": .string("registerThenUnregister:\(outcome)")]))
    case "unregister":
        notify("window/logMessage", .object(["type": .number(3), "message": .string("unregister:\(outcome)")]))
    case "workspace-configuration":
        let expected: JSONValue = .array([
            .object(["validate": .bool(true)]),
            .null
        ])
        let accepted = error == nil && result == expected && initializationOptionsAccepted.get()
        notify(
            "window/logMessage",
            .object([
                "type": .number(3),
                "message": .string("workspaceConfiguration:\(accepted ? "accepted" : "rejected")")
            ])
        )
    default:
        break
    }
}

func handleNotification(method: String, params: JSONValue?) {
    switch method {
    case "initialized":
        handleInitialized()

    case "exit":
        exit(0)

    case "$/cancelRequest":
        appendStateFileLine("cancel")
        if case .object(let fields)? = params {
            if case .number(let number)? = fields["id"] {
                cancelledIDs.markCancelled(.number(Int(number)))
            } else if case .string(let string)? = fields["id"] {
                cancelledIDs.markCancelled(.string(string))
            }
        }

    case "textDocument/didOpen":
        guard case .object(let fields)? = params, case .object(let textDocument)? = fields["textDocument"] else {
            return
        }
        appendStateFileLine("didOpen")
        guard case .string(let uri)? = textDocument["uri"], scenario != "no-diagnostics" else {
            return
        }
        var version = 1
        if case .number(let versionNumber)? = textDocument["version"] {
            version = Int(versionNumber)
        }
        let diagnosticMessage: String
        if scenario == "profile-config" {
            let languageID: String
            if case .string(let value)? = textDocument["languageId"] {
                languageID = value
            } else {
                languageID = ""
            }
            let accepted = languageID == "widget-lsp"
                && CommandLine.arguments.dropFirst(2).contains("--profile-marker")
            diagnosticMessage =
                accepted
                    ? "Profile configuration accepted"
                    : "Profile configuration rejected"
        } else {
            diagnosticMessage = "Fake published diagnostic"
        }
        var publishedDiagnostics: [JSONValue] = [
            .object([
                "range": lspRange(startLine: 0, startChar: 0, endLine: 0, endChar: 4),
                "severity": .number(2),
                "message": .string(diagnosticMessage)
            ])
        ]
        if scenario == "invalid-publish" {
            publishedDiagnostics.insert(
                .object([
                    "range": lspRange(startLine: 999, startChar: 0, endLine: 999, endChar: 1),
                    "severity": .number(1),
                    "message": .string("Invalid diagnostic")
                ]),
                at: 0
            )
        }
        notify("textDocument/publishDiagnostics", .object([
            "uri": .string(uri),
            "version": .number(Double(version)),
            "diagnostics": .array(publishedDiagnostics)
        ]))

    default:
        break
    }
}

// MARK: - Read loop

final class FramingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var decoder = JSONRPCFramingDecoder()

    func consume(_ data: Data) throws -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return try decoder.consume(data)
    }
}

let framingBox = FramingBox()
stdin.readabilityHandler = { handle in
    let data = handle.availableData
    guard !data.isEmpty else {
        handle.readabilityHandler = nil
        exit(0)
    }
    guard let bodies = try? framingBox.consume(data) else {
        exit(1)
    }
    for body in bodies {
        guard let message = try? JSONRPCMessage.decode(from: body) else {
            continue
        }
        switch message.kind {
        case .request(let id, let method, let params):
            handleRequest(id: id, method: method, params: params)
        case .notification(let method, let params):
            handleNotification(method: method, params: params)
        case .response(let id, let result, let error):
            handleResponseFromClient(id: id, result: result, error: error)
        }
    }
}

// Echoes this process's own argv back to the client as a
// `window/logMessage`, prefixed `argv:`, immediately on launch (before
// any request arrives). Used by `ProcessInvocationAssertionTests` to
// prove the launcher passed Kod's fixed argument array through verbatim
// — with any shell metacharacters intact as literal bytes — rather than
// evaluating it as shell text.
notify("window/logMessage", .object([
    "type": .number(4),
    "message": .string("argv:" + CommandLine.arguments.dropFirst().joined(separator: "\u{1}"))
]))

RunLoop.main.run()
