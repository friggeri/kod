import Foundation

/// A hand-rolled, strict JSON parser (RFC 8259) used instead of
/// `JSONSerialization` for three reasons specific to a safe preview:
///
/// 1. `JSONSerialization` does not preserve object member order (it
///    produces an unordered `NSDictionary`), which breaks SPEC 10.3's
///    "stable key ordering" and "copy key path" requirements.
/// 2. `JSONSerialization` silently keeps only the last value for a
///    duplicate key; this parser reports `.duplicateKey` as a real
///    diagnostic instead of hiding data loss.
/// 3. `JSONSerialization` has no caller-controlled depth/size limits, so a
///    hostile document can only be bounded by pre-flight byte-count
///    checks, not by the parser itself refusing to recurse further. This
///    parser enforces `StructuredDataLimits` while parsing, failing fast
///    the moment a limit is hit rather than after fully materializing the
///    hostile structure.
public enum JSONParser {
    /// Parses `data` as JSON text, enforcing `limits`. Returns `.invalid`
    /// with a precise diagnostic for anything from truncated input to a
    /// limit violation — never a fallback empty/success value.
    public static func parse(_ data: Data, limits: StructuredDataLimits = .default) -> StructuredParseResult {
        guard data.count <= limits.maximumSourceLength else {
            return .invalid(.sourceTooLarge(byteCount: data.count, limit: limits.maximumSourceLength))
        }
        var scanner = Scanner(bytes: Array(data), limits: limits)
        scanner.skipWhitespace()
        do {
            let node = try scanner.parseValue(depth: 0)
            scanner.skipWhitespace()
            if scanner.index != scanner.bytes.count {
                return .invalid(.trailingContent(atByteOffset: scanner.index))
            }
            return .valid(node)
        } catch let error as StructuredDataDiagnostic {
            return .invalid(error)
        } catch {
            return .invalid(.unexpectedEndOfInput(atByteOffset: scanner.index))
        }
    }

    private struct Scanner {
        let bytes: [UInt8]
        let limits: StructuredDataLimits
        var index = 0
        var nodeCount = 0

        init(bytes: [UInt8], limits: StructuredDataLimits) {
            self.bytes = bytes
            self.limits = limits
        }

        mutating func skipWhitespace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D:
                    index += 1
                default:
                    return
                }
            }
        }

        mutating func countNode() throws {
            nodeCount += 1
            if nodeCount > limits.maximumNodeCount {
                throw StructuredDataDiagnostic.nodeCountLimitExceeded(limit: limits.maximumNodeCount)
            }
        }

        mutating func parseValue(depth: Int) throws -> StructuredNode {
            try countNode()
            guard index < bytes.count else {
                throw StructuredDataDiagnostic.unexpectedEndOfInput(atByteOffset: index)
            }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                return try parseObject(depth: depth)
            case UInt8(ascii: "["):
                return try parseArray(depth: depth)
            case UInt8(ascii: "\""):
                return .string(try parseString())
            case UInt8(ascii: "t"):
                try expectLiteral("true")
                return .bool(true)
            case UInt8(ascii: "f"):
                try expectLiteral("false")
                return .bool(false)
            case UInt8(ascii: "n"):
                try expectLiteral("null")
                return .null
            case UInt8(ascii: "-"), 0x30...0x39:
                return .number(try parseNumber())
            default:
                throw StructuredDataDiagnostic.unexpectedCharacter(atByteOffset: index, expected: "a JSON value")
            }
        }

        mutating func parseObject(depth: Int) throws -> StructuredNode {
            guard depth < limits.maximumDepth else {
                throw StructuredDataDiagnostic.depthLimitExceeded(limit: limits.maximumDepth, atByteOffset: index)
            }
            index += 1 // consume '{'
            var members: [StructuredMember] = []
            var seenKeys = Set<String>()
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
                    throw StructuredDataDiagnostic.unexpectedCharacter(atByteOffset: index, expected: "a string key")
                }
                let keyOffset = index
                let key = try parseString()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
                    throw StructuredDataDiagnostic.unexpectedCharacter(atByteOffset: index, expected: "':'")
                }
                index += 1
                skipWhitespace()
                let value = try parseValue(depth: depth + 1)
                if !seenKeys.insert(key).inserted {
                    throw StructuredDataDiagnostic.duplicateKey(key, atByteOffset: keyOffset)
                }
                members.append(StructuredMember(key: key, value: value))
                skipWhitespace()
                guard index < bytes.count else {
                    throw StructuredDataDiagnostic.unexpectedEndOfInput(atByteOffset: index)
                }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                if bytes[index] == UInt8(ascii: "}") {
                    index += 1
                    return .object(members)
                }
                throw StructuredDataDiagnostic.unexpectedCharacter(atByteOffset: index, expected: "',' or '}'")
            }
        }

        mutating func parseArray(depth: Int) throws -> StructuredNode {
            guard depth < limits.maximumDepth else {
                throw StructuredDataDiagnostic.depthLimitExceeded(limit: limits.maximumDepth, atByteOffset: index)
            }
            index += 1 // consume '['
            var elements: [StructuredNode] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(elements)
            }
            while true {
                skipWhitespace()
                elements.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else {
                    throw StructuredDataDiagnostic.unexpectedEndOfInput(atByteOffset: index)
                }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                if bytes[index] == UInt8(ascii: "]") {
                    index += 1
                    return .array(elements)
                }
                throw StructuredDataDiagnostic.unexpectedCharacter(atByteOffset: index, expected: "',' or ']'")
            }
        }

        mutating func parseString() throws -> String {
            let startOffset = index
            index += 1 // consume opening quote
            var scalars: [UInt8] = []
            while true {
                guard index < bytes.count else {
                    throw StructuredDataDiagnostic.unexpectedEndOfInput(atByteOffset: index)
                }
                if scalars.count > limits.maximumStringLength {
                    throw StructuredDataDiagnostic.stringTooLong(limit: limits.maximumStringLength, atByteOffset: startOffset)
                }
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    index += 1
                    guard let string = String(bytes: scalars, encoding: .utf8) else {
                        throw StructuredDataDiagnostic.invalidUTF8(atByteOffset: startOffset)
                    }
                    return string
                }
                if byte == UInt8(ascii: "\\") {
                    index += 1
                    guard index < bytes.count else {
                        throw StructuredDataDiagnostic.unexpectedEndOfInput(atByteOffset: index)
                    }
                    switch bytes[index] {
                    case UInt8(ascii: "\""): scalars.append(UInt8(ascii: "\"")); index += 1
                    case UInt8(ascii: "\\"): scalars.append(UInt8(ascii: "\\")); index += 1
                    case UInt8(ascii: "/"): scalars.append(UInt8(ascii: "/")); index += 1
                    case UInt8(ascii: "b"): scalars.append(0x08); index += 1
                    case UInt8(ascii: "f"): scalars.append(0x0C); index += 1
                    case UInt8(ascii: "n"): scalars.append(0x0A); index += 1
                    case UInt8(ascii: "r"): scalars.append(0x0D); index += 1
                    case UInt8(ascii: "t"): scalars.append(0x09); index += 1
                    case UInt8(ascii: "u"):
                        index += 1
                        let codeUnit = try parseHex4()
                        var scalarValue = UInt32(codeUnit)
                        if (0xD800...0xDBFF).contains(codeUnit) {
                            // High surrogate: a valid escape requires an
                            // immediately following low-surrogate escape.
                            guard index + 1 < bytes.count,
                                  bytes[index] == UInt8(ascii: "\\"),
                                  bytes[index + 1] == UInt8(ascii: "u") else {
                                throw StructuredDataDiagnostic.invalidEscapeSequence(atByteOffset: startOffset)
                            }
                            index += 2
                            let lowSurrogate = try parseHex4()
                            guard (0xDC00...0xDFFF).contains(lowSurrogate) else {
                                throw StructuredDataDiagnostic.invalidEscapeSequence(atByteOffset: startOffset)
                            }
                            scalarValue = 0x10000
                                + (UInt32(codeUnit) - 0xD800) * 0x400
                                + (UInt32(lowSurrogate) - 0xDC00)
                        } else if (0xDC00...0xDFFF).contains(codeUnit) {
                            throw StructuredDataDiagnostic.invalidEscapeSequence(atByteOffset: startOffset)
                        }
                        guard let scalar = Unicode.Scalar(scalarValue) else {
                            throw StructuredDataDiagnostic.invalidEscapeSequence(atByteOffset: startOffset)
                        }
                        scalars.append(contentsOf: Array(String(scalar).utf8))
                    default:
                        throw StructuredDataDiagnostic.invalidEscapeSequence(atByteOffset: index)
                    }
                    continue
                }
                if byte < 0x20 {
                    throw StructuredDataDiagnostic.unexpectedCharacter(atByteOffset: index, expected: "an escaped control character")
                }
                scalars.append(byte)
                index += 1
            }
        }

        mutating func parseHex4() throws -> UInt16 {
            guard index + 4 <= bytes.count else {
                throw StructuredDataDiagnostic.invalidEscapeSequence(atByteOffset: index)
            }
            var value: UInt16 = 0
            for _ in 0..<4 {
                guard let digit = hexDigitValue(bytes[index]) else {
                    throw StructuredDataDiagnostic.invalidEscapeSequence(atByteOffset: index)
                }
                value = value * 16 + UInt16(digit)
                index += 1
            }
            return value
        }

        mutating func parseNumber() throws -> String {
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") {
                index += 1
            }
            guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else {
                throw StructuredDataDiagnostic.invalidNumberLiteral(atByteOffset: start)
            }
            if bytes[index] == UInt8(ascii: "0") {
                index += 1
            } else {
                while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                    index += 1
                }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else {
                    throw StructuredDataDiagnostic.invalidNumberLiteral(atByteOffset: start)
                }
                while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                    index += 1
                }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                    index += 1
                }
                guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else {
                    throw StructuredDataDiagnostic.invalidNumberLiteral(atByteOffset: start)
                }
                while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                    index += 1
                }
            }
            guard index - start <= limits.maximumNumberLength else {
                throw StructuredDataDiagnostic.numberLiteralTooLong(limit: limits.maximumNumberLength, atByteOffset: start)
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        mutating func expectLiteral(_ literal: String) throws {
            let literalBytes = Array(literal.utf8)
            guard index + literalBytes.count <= bytes.count,
                  Array(bytes[index..<(index + literalBytes.count)]) == literalBytes else {
                throw StructuredDataDiagnostic.unexpectedCharacter(atByteOffset: index, expected: "'\(literal)'")
            }
            index += literalBytes.count
        }

        func hexDigitValue(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: return byte - 0x30
            case 0x41...0x46: return byte - 0x41 + 10
            case 0x61...0x66: return byte - 0x61 + 10
            default: return nil
            }
        }
    }
}
