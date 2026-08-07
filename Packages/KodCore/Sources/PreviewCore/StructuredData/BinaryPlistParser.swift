import Foundation

/// A from-scratch `bplist00` (Apple binary property list) decoder.
///
/// `PropertyListSerialization` can decode binary plists, but it gives Kod
/// no control over nesting depth, node count, or string/data size while
/// decoding — exactly the knobs a safe preview needs against a hostile
/// file (SPEC 10.3's size limits; a binary plist's compact, offset-table
/// design also makes classic decompression-bomb-style tricks easy: a tiny
/// file can declare a dictionary with billions of entries all pointing at
/// the same one small string). This decoder walks the format by hand so
/// every count and offset is bounds-checked against the actual buffer
/// before it is ever used, cyclic object graphs are rejected instead of
/// looped forever, and `StructuredDataLimits` apply exactly as they do for
/// JSON and XML plists.
enum BinaryPlistParser {
    private static let trailerLength = 32
    private static let headerLength = 8
    private static let header = Array("bplist00".utf8)

    static func parse(_ data: Data, limits: StructuredDataLimits) -> StructuredParseResult {
        let bytes = Array(data)
        guard bytes.count >= headerLength + trailerLength, Array(bytes.prefix(headerLength)) == header else {
            return .invalid(.notAPropertyList)
        }
        guard bytes.count <= limits.maximumSourceLength else {
            return .invalid(.sourceTooLarge(byteCount: bytes.count, limit: limits.maximumSourceLength))
        }

        let trailer = bytes.suffix(trailerLength)
        let offsetIntSize = Int(trailer[trailer.startIndex + 6])
        let objectRefSize = Int(trailer[trailer.startIndex + 7])
        let numObjects = readBigEndianUInt(trailer, offset: 8, length: 8)
        let topObject = readBigEndianUInt(trailer, offset: 16, length: 8)
        let offsetTableOffset = readBigEndianUInt(trailer, offset: 24, length: 8)

        guard offsetIntSize > 0, offsetIntSize <= 8, objectRefSize > 0, objectRefSize <= 8 else {
            return .invalid(.malformedBinaryPlist(reason: "invalid offset/reference integer size in trailer"))
        }
        guard let numObjects, let topObject, let offsetTableOffset else {
            return .invalid(.malformedBinaryPlist(reason: "trailer integer overflow"))
        }
        guard numObjects > 0, numObjects <= UInt64(limits.maximumNodeCount) else {
            return .invalid(.malformedBinaryPlist(reason: "object count \(numObjects) exceeds preview limit"))
        }
        let offsetTableByteLength = numObjects * UInt64(offsetIntSize)
        guard offsetTableOffset <= UInt64(bytes.count),
              offsetTableByteLength <= UInt64(bytes.count) - offsetTableOffset else {
            return .invalid(.malformedBinaryPlist(reason: "offset table out of bounds"))
        }
        guard topObject < numObjects else {
            return .invalid(.malformedBinaryPlist(reason: "top object index out of range"))
        }

        var decoder = Decoder(
            bytes: bytes,
            offsetIntSize: offsetIntSize,
            objectRefSize: objectRefSize,
            numObjects: Int(numObjects),
            offsetTableOffset: Int(offsetTableOffset),
            limits: limits
        )
        do {
            let node = try decoder.decodeObject(atIndex: Int(topObject), depth: 0)
            return .valid(node)
        } catch let diagnostic as StructuredDataDiagnostic {
            return .invalid(diagnostic)
        } catch {
            return .invalid(.malformedBinaryPlist(reason: "unexpected decode failure"))
        }
    }

    private static func readBigEndianUInt<C: Collection>(_ bytes: C, offset: Int, length: Int) -> UInt64?
    where C.Element == UInt8, C.Index == Int {
        guard offset >= 0, length > 0, length <= 8 else {
            return nil
        }
        let start = bytes.startIndex + offset
        guard start >= bytes.startIndex, start + length <= bytes.endIndex else {
            return nil
        }
        var value: UInt64 = 0
        for i in 0..<length {
            value = (value << 8) | UInt64(bytes[start + i])
        }
        return value
    }

    private struct Decoder {
        let bytes: [UInt8]
        let offsetIntSize: Int
        let objectRefSize: Int
        let numObjects: Int
        let offsetTableOffset: Int
        let limits: StructuredDataLimits

        var offsetCache: [Int: Int] = [:]
        var nodeCount = 0
        var inProgress = Set<Int>()

        mutating func objectOffset(at index: Int) throws -> Int {
            if let cached = offsetCache[index] {
                return cached
            }
            guard index >= 0, index < numObjects else {
                throw StructuredDataDiagnostic.malformedBinaryPlist(reason: "object reference \(index) out of range")
            }
            let entryStart = offsetTableOffset + index * offsetIntSize
            guard let value = BinaryPlistParser.readBigEndianUInt(bytes, offset: entryStart, length: offsetIntSize),
                  value <= UInt64(bytes.count) else {
                throw StructuredDataDiagnostic.malformedBinaryPlist(reason: "object offset for index \(index) out of range")
            }
            let offset = Int(value)
            offsetCache[index] = offset
            return offset
        }

        mutating func countNode() throws {
            nodeCount += 1
            if nodeCount > limits.maximumNodeCount {
                throw StructuredDataDiagnostic.nodeCountLimitExceeded(limit: limits.maximumNodeCount)
            }
        }

        mutating func decodeObject(atIndex index: Int, depth: Int) throws -> StructuredNode {
            guard depth <= limits.maximumDepth else {
                throw StructuredDataDiagnostic.depthLimitExceeded(limit: limits.maximumDepth, atByteOffset: 0)
            }
            guard !inProgress.contains(index) else {
                throw StructuredDataDiagnostic.malformedBinaryPlist(reason: "cyclic object reference at index \(index)")
            }
            try countNode()

            let offset = try objectOffset(at: index)
            guard offset < bytes.count else {
                throw StructuredDataDiagnostic.malformedBinaryPlist(reason: "object at index \(index) starts out of bounds")
            }
            let marker = bytes[offset]
            let typeNibble = marker >> 4
            let infoNibble = marker & 0x0F

            switch typeNibble {
            case 0x0:
                switch marker {
                case 0x00: return .null
                case 0x08: return .bool(false)
                case 0x09: return .bool(true)
                default: return .null
                }

            case 0x1: // int
                let byteCount = 1 << Int(infoNibble)
                let literal = try readSignedInteger(at: offset + 1, byteCount: byteCount)
                return .number(String(literal))

            case 0x2: // real
                let byteCount = 1 << Int(infoNibble)
                return .number(try readReal(at: offset + 1, byteCount: byteCount))

            case 0x3: // date
                guard offset + 9 <= bytes.count else {
                    throw StructuredDataDiagnostic.malformedBinaryPlist(reason: "truncated date at offset \(offset)")
                }
                let bits = readBigEndianUInt64(at: offset + 1)
                let seconds = Double(bitPattern: bits)
                return .date(Date(timeIntervalSinceReferenceDate: seconds))

            case 0x4: // data
                let (count, dataStart) = try readCount(infoNibble: infoNibble, after: offset)
                guard count <= limits.maximumStringLength else {
                    throw StructuredDataDiagnostic.stringTooLong(limit: limits.maximumStringLength, atByteOffset: offset)
                }
                guard dataStart + count <= bytes.count else {
                    throw StructuredDataDiagnostic.malformedBinaryPlist(reason: "data value out of bounds at offset \(offset)")
                }
                return .data(Data(bytes[dataStart..<(dataStart + count)]))

            case 0x5: // ASCII string
                let (count, dataStart) = try readCount(infoNibble: infoNibble, after: offset)
                guard count <= limits.maximumStringLength else {
                    throw StructuredDataDiagnostic.stringTooLong(limit: limits.maximumStringLength, atByteOffset: offset)
                }
                guard dataStart + count <= bytes.count else {
                    throw StructuredDataDiagnostic.malformedBinaryPlist(reason: "string value out of bounds at offset \(offset)")
                }
                return .string(String(decoding: bytes[dataStart..<(dataStart + count)], as: UTF8.self))

            case 0x6: // UTF-16BE string
                let (count, dataStart) = try readCount(infoNibble: infoNibble, after: offset)
                guard count <= limits.maximumStringLength else {
                    throw StructuredDataDiagnostic.stringTooLong(limit: limits.maximumStringLength, atByteOffset: offset)
                }
                let byteLength = count * 2
                guard dataStart + byteLength <= bytes.count else {
                    throw StructuredDataDiagnostic.malformedBinaryPlist(reason: "string value out of bounds at offset \(offset)")
                }
                var units: [UInt16] = []
                units.reserveCapacity(count)
                for i in 0..<count {
                    let hi = UInt16(bytes[dataStart + i * 2])
                    let lo = UInt16(bytes[dataStart + i * 2 + 1])
                    units.append((hi << 8) | lo)
                }
                return .string(String(decoding: units, as: UTF16.self))

            case 0x8: // UID — rendered as its integer value; not a JSON/plist scalar Kod otherwise surfaces.
                let byteCount = Int(infoNibble) + 1
                let literal = try readUnsignedInteger(at: offset + 1, byteCount: byteCount)
                return .string("UID(\(literal))")

            case 0xA: // array
                let (count, refsStart) = try readCount(infoNibble: infoNibble, after: offset)
                guard count >= 0, refsStart + count * objectRefSize <= bytes.count else {
                    throw StructuredDataDiagnostic.malformedBinaryPlist(reason: "array reference table out of bounds at offset \(offset)")
                }
                inProgress.insert(index)
                defer { inProgress.remove(index) }
                var elements: [StructuredNode] = []
                elements.reserveCapacity(min(count, 1024))
                for i in 0..<count {
                    let refIndex = readRef(at: refsStart + i * objectRefSize)
                    elements.append(try decodeObject(atIndex: refIndex, depth: depth + 1))
                }
                return .array(elements)

            case 0xD: // dict
                let (count, keyRefsStart) = try readCount(infoNibble: infoNibble, after: offset)
                let valueRefsStart = keyRefsStart + count * objectRefSize
                guard count >= 0, valueRefsStart + count * objectRefSize <= bytes.count else {
                    throw StructuredDataDiagnostic.malformedBinaryPlist(reason: "dictionary reference table out of bounds at offset \(offset)")
                }
                inProgress.insert(index)
                defer { inProgress.remove(index) }
                var members: [StructuredMember] = []
                members.reserveCapacity(min(count, 1024))
                var seenKeys = Set<String>()
                for i in 0..<count {
                    let keyRefIndex = readRef(at: keyRefsStart + i * objectRefSize)
                    let valueRefIndex = readRef(at: valueRefsStart + i * objectRefSize)
                    let keyNode = try decodeObject(atIndex: keyRefIndex, depth: depth + 1)
                    guard case .string(let key) = keyNode else {
                        throw StructuredDataDiagnostic.malformedBinaryPlist(reason: "non-string dictionary key at offset \(offset)")
                    }
                    let value = try decodeObject(atIndex: valueRefIndex, depth: depth + 1)
                    if !seenKeys.insert(key).inserted {
                        throw StructuredDataDiagnostic.duplicateKey(key, atByteOffset: offset)
                    }
                    members.append(StructuredMember(key: key, value: value))
                }
                return .object(members)

            default:
                throw StructuredDataDiagnostic.malformedBinaryPlist(reason: "unsupported object type marker 0x\(String(marker, radix: 16)) at offset \(offset)")
            }
        }

        /// Reads a collection's element/member count, following the
        /// format's rule that a nibble of `0xF` means "read a separate
        /// int object for the real count" immediately after the marker
        /// byte. Returns the count and the byte offset immediately after
        /// whatever was consumed to determine it.
        mutating func readCount(infoNibble: UInt8, after markerOffset: Int) throws -> (count: Int, dataStart: Int) {
            if infoNibble != 0x0F {
                return (Int(infoNibble), markerOffset + 1)
            }
            guard markerOffset + 1 < bytes.count else {
                throw StructuredDataDiagnostic.malformedBinaryPlist(reason: "truncated count marker at offset \(markerOffset)")
            }
            let countMarker = bytes[markerOffset + 1]
            guard countMarker >> 4 == 0x1 else {
                throw StructuredDataDiagnostic.malformedBinaryPlist(reason: "invalid count-size marker at offset \(markerOffset)")
            }
            let byteCount = 1 << Int(countMarker & 0x0F)
            let value = try readUnsignedInteger(at: markerOffset + 2, byteCount: byteCount)
            guard value >= 0, value <= UInt64(limits.maximumNodeCount) else {
                throw StructuredDataDiagnostic.nodeCountLimitExceeded(limit: limits.maximumNodeCount)
            }
            return (Int(value), markerOffset + 2 + byteCount)
        }

        func readRef(at offset: Int) -> Int {
            guard offset >= 0, offset + objectRefSize <= bytes.count else {
                return -1
            }
            var value: UInt64 = 0
            for i in 0..<objectRefSize {
                value = (value << 8) | UInt64(bytes[offset + i])
            }
            return Int(value)
        }

        func readUnsignedInteger(at offset: Int, byteCount: Int) throws -> UInt64 {
            guard byteCount > 0, byteCount <= 8, offset >= 0, offset + byteCount <= bytes.count else {
                throw StructuredDataDiagnostic.malformedBinaryPlist(reason: "integer out of bounds at offset \(offset)")
            }
            var value: UInt64 = 0
            for i in 0..<byteCount {
                value = (value << 8) | UInt64(bytes[offset + i])
            }
            return value
        }

        func readSignedInteger(at offset: Int, byteCount: Int) throws -> Int64 {
            let raw = try readUnsignedInteger(at: offset, byteCount: byteCount)
            // Binary plist integers of the smaller widths are unsigned;
            // an 8-byte (or larger, non-standard) integer is sign-extended
            // per Apple's own encoder/decoder behavior.
            if byteCount >= 8 {
                return Int64(bitPattern: raw)
            }
            return Int64(raw)
        }

        func readReal(at offset: Int, byteCount: Int) throws -> String {
            guard offset >= 0, offset + byteCount <= bytes.count else {
                throw StructuredDataDiagnostic.malformedBinaryPlist(reason: "real out of bounds at offset \(offset)")
            }
            switch byteCount {
            case 4:
                let bits = (0..<4).reduce(UInt32(0)) { partial, i in (partial << 8) | UInt32(bytes[offset + i]) }
                return String(Float(bitPattern: bits))
            case 8:
                let bits = readBigEndianUInt64(at: offset)
                return String(Double(bitPattern: bits))
            default:
                throw StructuredDataDiagnostic.malformedBinaryPlist(reason: "unsupported real width \(byteCount) at offset \(offset)")
            }
        }

        func readBigEndianUInt64(at offset: Int) -> UInt64 {
            var value: UInt64 = 0
            for i in 0..<8 {
                value = (value << 8) | UInt64(bytes[offset + i])
            }
            return value
        }
    }
}
