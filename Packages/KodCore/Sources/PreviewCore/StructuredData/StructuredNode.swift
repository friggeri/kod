import Foundation

/// One key/value member of a `StructuredNode.object`. Property lists and
/// JSON objects are both ordered by source position, never resorted, so a
/// tree view can show members in the exact order they appeared on disk
/// (SPEC 10.3: "stable key ordering where appropriate").
public struct StructuredMember: Equatable, Sendable {
    public let key: String
    public let value: StructuredNode

    public init(key: String, value: StructuredNode) {
        self.key = key
        self.value = value
    }
}

/// A parsed, read-only JSON or property-list value tree.
///
/// This is a single shared model for both formats: JSON has no `date` or
/// `data` (binary blob) scalar, but property lists do, so both cases exist
/// here and JSON parsing simply never produces them. Everything is a value
/// type built once by a parser and never mutated, matching Kod's
/// read-only-by-construction principle (SPEC 1.2).
public indirect enum StructuredNode: Equatable, Sendable {
    case object([StructuredMember])
    case array([StructuredNode])
    case string(String)
    case number(String)
    case bool(Bool)
    case null
    /// A property-list `<date>` element (ISO 8601 UTC in XML plists; an
    /// 8-byte CFAbsoluteTime `NSDate` object in binary plists).
    case date(Date)
    /// A property-list `<data>` element (base64 in XML plists; a `data`
    /// object in binary plists). Rendered as size + hex/base64 preview,
    /// never decoded/executed as anything else.
    case data(Data)

    /// True for `object`/`array`, the two node kinds a tree view can
    /// expand or collapse.
    public var isContainer: Bool {
        switch self {
        case .object, .array:
            true
        case .string, .number, .bool, .null, .date, .data:
            false
        }
    }

    /// A short, single-line description of this node's value for a tree
    /// row, independent of any expand/collapse state. Containers show a
    /// member/element count rather than their content.
    public var previewText: String {
        switch self {
        case .object(let members):
            members.count == 1 ? "{1 key}" : "{\(members.count) keys}"
        case .array(let elements):
            elements.count == 1 ? "[1 item]" : "[\(elements.count) items]"
        case .string(let value):
            value
        case .number(let literal):
            literal
        case .bool(let value):
            value ? "true" : "false"
        case .null:
            "null"
        case .date(let value):
            ISO8601DateFormatter().string(from: value)
        case .data(let value):
            "\(value.count) bytes"
        }
    }
}
