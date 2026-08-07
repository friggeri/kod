import Foundation

/// A JSON-RPC 2.0 request/response identifier. LSP servers may echo back
/// either the number or string form Kod sent, so both are modeled
/// explicitly rather than normalized to one representation.
public enum JSONRPCID: Hashable, Sendable {
    case number(Int)
    case string(String)
}

extension JSONRPCID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        throw DecodingError.typeMismatch(
            JSONRPCID.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "JSON-RPC id must be a number or string"
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        }
    }
}

/// Generates strictly increasing, process-unique request identifiers.
/// Isolated to the owning connection actor's executor; no shared mutable
/// state crosses actor boundaries.
struct JSONRPCIDGenerator {
    private var next = 0

    mutating func nextID() -> JSONRPCID {
        defer { next += 1 }
        return .number(next)
    }
}
