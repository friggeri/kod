import Foundation

/// Why a JSON or property-list source failed to parse into a
/// `StructuredNode` tree, or was rejected before parsing began. Every case
/// carries enough detail (a byte offset, a limit that was hit, or both) to
/// show a real, specific diagnostic — never a generic "invalid file"
/// message and never a silently-empty tree standing in for failure.
public enum StructuredDataDiagnostic: Error, Equatable, Sendable {
    case sourceTooLarge(byteCount: Int, limit: Int)
    case unexpectedEndOfInput(atByteOffset: Int)
    case unexpectedCharacter(atByteOffset: Int, expected: String)
    case invalidNumberLiteral(atByteOffset: Int)
    case invalidEscapeSequence(atByteOffset: Int)
    case invalidUTF8(atByteOffset: Int)
    case trailingContent(atByteOffset: Int)
    case duplicateKey(String, atByteOffset: Int)
    case depthLimitExceeded(limit: Int, atByteOffset: Int)
    case nodeCountLimitExceeded(limit: Int)
    case stringTooLong(limit: Int, atByteOffset: Int)
    case numberLiteralTooLong(limit: Int, atByteOffset: Int)
    /// The bytes are not a plist at all (no `bplist00` magic and no `<?xml`
    /// or `<plist` prologue) — a distinct diagnostic from a plist that
    /// merely fails to parse, so a JSON file misidentified as a plist
    /// candidate reports something meaningful.
    case notAPropertyList
    /// A binary plist's structural framework (trailer, offset table, or
    /// object table) is malformed or out of bounds — reported instead of
    /// reading out-of-bounds memory or guessing.
    case malformedBinaryPlist(reason: String)
    /// An XML plist's document is not well-formed XML, from
    /// `XMLParser`'s own diagnostic.
    case malformedXMLPlist(reason: String, line: Int)

    /// A single-line, human-readable description suitable for the fallback
    /// code-viewer diagnostic banner (SPEC 10.3: "Invalid data falls back
    /// to the source viewer with a parse diagnostic").
    public var message: String {
        switch self {
        case .sourceTooLarge(let byteCount, let limit):
            "Source is \(byteCount) bytes, above the \(limit)-byte preview limit."
        case .unexpectedEndOfInput(let offset):
            "Unexpected end of input at byte \(offset)."
        case .unexpectedCharacter(let offset, let expected):
            "Unexpected character at byte \(offset); expected \(expected)."
        case .invalidNumberLiteral(let offset):
            "Invalid number literal at byte \(offset)."
        case .invalidEscapeSequence(let offset):
            "Invalid escape sequence at byte \(offset)."
        case .invalidUTF8(let offset):
            "Invalid UTF-8 at byte \(offset)."
        case .trailingContent(let offset):
            "Unexpected trailing content at byte \(offset)."
        case .duplicateKey(let key, let offset):
            "Duplicate key \"\(key)\" at byte \(offset)."
        case .depthLimitExceeded(let limit, let offset):
            "Nesting exceeds the \(limit)-level preview limit at byte \(offset)."
        case .nodeCountLimitExceeded(let limit):
            "Document exceeds the \(limit)-node preview limit."
        case .stringTooLong(let limit, let offset):
            "String exceeds the \(limit)-byte preview limit at byte \(offset)."
        case .numberLiteralTooLong(let limit, let offset):
            "Number literal exceeds the \(limit)-byte preview limit at byte \(offset)."
        case .notAPropertyList:
            "Not a recognized property-list format (no bplist00 signature or XML plist prologue)."
        case .malformedBinaryPlist(let reason):
            "Malformed binary property list: \(reason)."
        case .malformedXMLPlist(let reason, let line):
            "Malformed XML property list at line \(line): \(reason)."
        }
    }
}

/// The outcome of parsing a structured-data (JSON/plist) source: either a
/// full tree, or an explicit diagnostic. There is deliberately no
/// "succeeded with empty data" case standing in for failure — an invalid or
/// rejected source is always `.invalid`.
public enum StructuredParseResult: Equatable, Sendable {
    case valid(StructuredNode)
    case invalid(StructuredDataDiagnostic)

    public var node: StructuredNode? {
        if case .valid(let node) = self {
            return node
        }
        return nil
    }

    public var diagnostic: StructuredDataDiagnostic? {
        if case .invalid(let diagnostic) = self {
            return diagnostic
        }
        return nil
    }
}
