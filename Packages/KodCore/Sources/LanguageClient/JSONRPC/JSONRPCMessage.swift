import Foundation

/// Standard JSON-RPC 2.0 error codes Kod's client surface needs, plus the
/// LSP-specific codes it can receive or must emit itself (SPEC 6: reject
/// mutating requests with a real error, never a silent no-op).
public enum JSONRPCErrorCode {
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603
    public static let serverNotInitialized = -32002
    public static let requestCancelled = -32800
    public static let contentModified = -32801

    /// Not a reserved JSON-RPC/LSP code; Kod's own value for "this is a
    /// mutating or otherwise unsupported operation Kod refuses to
    /// perform," used on both the reject-incoming-request and
    /// reject-outgoing-request paths so the reason is unambiguous in logs.
    public static let operationNotPermitted = -32001
}

public struct JSONRPCResponseError: Error, Equatable, Sendable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static func methodNotFound(_ method: String) -> JSONRPCResponseError {
        JSONRPCResponseError(code: JSONRPCErrorCode.methodNotFound, message: "Method not found: \(method)")
    }

    public static func operationNotPermitted(_ method: String) -> JSONRPCResponseError {
        JSONRPCResponseError(
            code: JSONRPCErrorCode.operationNotPermitted,
            message: "Kod is read-only and refuses to perform '\(method)'."
        )
    }

    public static func requestCancelled(_ method: String) -> JSONRPCResponseError {
        JSONRPCResponseError(code: JSONRPCErrorCode.requestCancelled, message: "Cancelled: \(method)")
    }
}

/// One inbound or outbound JSON-RPC message, after Content-Length framing
/// has been stripped and the bytes parsed as JSON. `id == nil` on a
/// response is only valid for a parse-error reply per the spec; Kod
/// otherwise always expects a matching id.
public struct JSONRPCMessage: Sendable {
    public enum Kind: Sendable {
        /// A request awaiting a response, either one Kod sent (tracked by
        /// id) or one the server sent to Kod (`method`/`params` set).
        case request(id: JSONRPCID, method: String, params: JSONValue?)
        case notification(method: String, params: JSONValue?)
        case response(id: JSONRPCID?, result: JSONValue?, error: JSONRPCResponseError?)
    }

    public let kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }
}

enum JSONRPCCodingKeys: String, CodingKey {
    case jsonrpc
    case id
    case method
    case params
    case result
    case error
}

public enum JSONRPCMessageError: Error, Equatable {
    case unsupportedJSONRPCVersion(String)
}

extension JSONRPCMessage {
    /// Decodes one already-length-delimited JSON payload into a typed
    /// message. Distinguishes a request from a response purely on
    /// structure (`method` present vs. `result`/`error` present), since
    /// both can carry an `id`.
    public static func decode(from data: Data) throws -> JSONRPCMessage {
        let wire = try JSONDecoder.lspDecoder.decode(JSONRPCWireEnvelope.self, from: data)

        if let version = wire.jsonrpc, version != "2.0" {
            throw JSONRPCMessageError.unsupportedJSONRPCVersion(version)
        }

        if let method = wire.method {
            if let id = wire.id {
                return JSONRPCMessage(kind: .request(id: id, method: method, params: wire.params))
            }
            return JSONRPCMessage(kind: .notification(method: method, params: wire.params))
        }

        return JSONRPCMessage(
            kind: .response(id: wire.id, result: wire.result, error: wire.error?.asResponseError)
        )
    }

    public func encoded() throws -> Data {
        try JSONEncoder.lspEncoder.encode(JSONRPCEnvelope(self))
    }
}

/// The concrete `Encodable` shape written to the wire for any
/// `JSONRPCMessage.Kind`. Kept separate from `JSONRPCMessage` itself so
/// the public `Kind` enum stays a plain value type without committing to
/// one field layout.
private struct JSONRPCEnvelope: Encodable {
    let message: JSONRPCMessage

    init(_ message: JSONRPCMessage) {
        self.message = message
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: JSONRPCCodingKeys.self)
        try container.encode("2.0", forKey: .jsonrpc)

        switch message.kind {
        case .request(let id, let method, let params):
            try container.encode(id, forKey: .id)
            try container.encode(method, forKey: .method)
            try container.encodeIfPresent(params, forKey: .params)

        case .notification(let method, let params):
            try container.encode(method, forKey: .method)
            try container.encodeIfPresent(params, forKey: .params)

        case .response(let id, let result, let error):
            try container.encodeIfPresent(id, forKey: .id)
            if let error {
                try container.encode(JSONRPCResponseErrorWire(error), forKey: .error)
            } else {
                try container.encode(result ?? .null, forKey: .result)
            }
        }
    }
}

/// The raw wire shape used only for decoding: every field optional since
/// requests, notifications, and responses share one JSON object shape and
/// are distinguished after the fact by which fields are present.
private struct JSONRPCWireEnvelope: Decodable {
    let jsonrpc: String?
    let id: JSONRPCID?
    let method: String?
    let params: JSONValue?
    let result: JSONValue?
    let error: JSONRPCResponseErrorWire?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: JSONRPCCodingKeys.self)
        jsonrpc = try container.decodeIfPresent(String.self, forKey: .jsonrpc)
        id = try container.decodeIfPresent(JSONRPCID.self, forKey: .id)
        method = try container.decodeIfPresent(String.self, forKey: .method)
        params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
        if container.contains(.result) {
            result = try container.decode(JSONValue.self, forKey: .result)
        } else {
            result = nil
        }
        error = try container.decodeIfPresent(JSONRPCResponseErrorWire.self, forKey: .error)
    }
}

/// The wire shape of a JSON-RPC error object.
private struct JSONRPCResponseErrorWire: Codable {
    let code: Int
    let message: String
    let data: JSONValue?

    init(_ error: JSONRPCResponseError) {
        code = error.code
        message = error.message
        data = error.data
    }

    var asResponseError: JSONRPCResponseError {
        JSONRPCResponseError(code: code, message: message, data: data)
    }
}
