import CoreFoundation
import Foundation

/// A minimal, order-preserving-for-arrays JSON value tree used to carry
/// arbitrary LSP `params`/`result`/`data` payloads through the JSON-RPC
/// envelope without committing to one concrete Swift type. Typed call
/// sites decode a `JSONValue` into a specific `Decodable` model (or
/// encode one into a `JSONValue`) at the boundary; nothing in the
/// transport itself inspects payload contents.
public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
            return
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

public enum JSONValueError: Error, Equatable {
    case encodingFailed
    case decodingFailed
}

extension JSONValue {
    /// Round-trips `value` through `JSONEncoder`/`JSONDecoder` into a
    /// `JSONValue` tree so it can be embedded in a JSON-RPC envelope
    /// alongside other dynamically-typed fields.
    public static func encoding<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder.lspEncoder.encode(value)
        let object = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        return try JSONValue(jsonObject: object)
    }

    /// Decodes this value into a concrete `Decodable` model.
    public func decoding<T: Decodable>(as type: T.Type = T.self) throws -> T {
        let data = try JSONEncoder.lspEncoder.encode(self)
        return try JSONDecoder.lspDecoder.decode(T.self, from: data)
    }

    private init(jsonObject: Any) throws {
        switch jsonObject {
        case is NSNull:
            self = .null
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(try value.map(JSONValue.init(jsonObject:)))
        case let value as [String: Any]:
            self = .object(try value.mapValues(JSONValue.init(jsonObject:)))
        default:
            throw JSONValueError.decodingFailed
        }
    }
}

extension JSONEncoder {
    static var lspEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var lspDecoder: JSONDecoder {
        JSONDecoder()
    }
}
