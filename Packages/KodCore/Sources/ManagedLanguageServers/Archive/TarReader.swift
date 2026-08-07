import Foundation

/// The subset of USTAR/POSIX-tar entry type flags Kod's tar reader
/// distinguishes. Anything not a plain file or directory is a security
/// question the extractor must answer explicitly — never something
/// silently written to disk.
public enum TarEntryType: Equatable, Sendable {
    case regularFile
    case directory
    case symbolicLink
    case hardLink
    case characterDevice
    case blockDevice
    case fifo
    /// A typeflag byte this reader doesn't recognize as any of the
    /// above (e.g. a vendor extension). Treated exactly like a device
    /// file by `SecureArchiveExtractor`: rejected outright.
    case other(UInt8)

    init(typeflag: UInt8) {
        switch typeflag {
        case 0, UInt8(ascii: "0"):
            self = .regularFile
        case UInt8(ascii: "5"):
            self = .directory
        case UInt8(ascii: "2"):
            self = .symbolicLink
        case UInt8(ascii: "1"):
            self = .hardLink
        case UInt8(ascii: "3"):
            self = .characterDevice
        case UInt8(ascii: "4"):
            self = .blockDevice
        case UInt8(ascii: "6"):
            self = .fifo
        default:
            self = .other(typeflag)
        }
    }
}

/// One decoded tar header plus its entry body bytes. `name`/`linkName`
/// are exposed verbatim (not yet path-normalized or validated) —
/// `SecureArchiveExtractor` is solely responsible for deciding whether a
/// given entry's raw name/type is safe to write anywhere.
public struct TarEntry: Equatable, Sendable {
    public let name: String
    public let type: TarEntryType
    public let linkName: String
    public let mode: UInt32
    public let size: Int
    public let body: Data

    public init(name: String, type: TarEntryType, linkName: String = "", mode: UInt32 = 0o644, size: Int, body: Data) {
        self.name = name
        self.type = type
        self.linkName = linkName
        self.mode = mode
        self.size = size
        self.body = body
    }
}

public enum TarError: Error, Equatable, Sendable {
    case truncatedHeader
    case badHeaderChecksum
    case truncatedBody
    case unsupportedLongNameExtension
}

/// A minimal, dependency-free reader/writer for the USTAR tar format
/// (POSIX.1-1988), covering exactly the header fields Kod's
/// managed-install artifacts need. Deliberately does **not** implement
/// GNU long-name (`././@LongLink`) or PAX extended-header (`typeflag
/// 'x'/'g'`) entries: both are ways for an entry's *effective* name to
/// live somewhere other than the fixed 100-byte `name` field a naive
/// reader checks, which is exactly the kind of "the validated name
/// wasn't the name actually used" gap `SecureArchiveExtractor` must not
/// have. Encountering either extension type is treated as
/// `unsupportedLongNameExtension` and rejected, rather than silently
/// ignored or (worse) only partially honored.
public enum TarReader {
    private static let blockSize = 512

    public static func readEntries(_ data: Data) throws -> [TarEntry] {
        var entries: [TarEntry] = []
        var offset = data.startIndex
        while offset + blockSize <= data.endIndex {
            let header = data.subdata(in: offset..<(offset + blockSize))
            // Two consecutive all-zero blocks mark the end of the
            // archive; a single all-zero block alone is not a valid
            // header but is also not meaningful content, so treat an
            // all-zero header as "no more entries" instead of throwing.
            if header.allSatisfy({ $0 == 0 }) {
                break
            }

            guard let parsed = try parseHeader(header) else {
                offset += blockSize
                continue
            }

            if parsed.name == "././@LongLink" || parsed.typeflag == UInt8(ascii: "x") || parsed.typeflag == UInt8(ascii: "L")
                || parsed.typeflag == UInt8(ascii: "K") || parsed.typeflag == UInt8(ascii: "g") {
                throw TarError.unsupportedLongNameExtension
            }

            offset += blockSize
            let bodyBlocks = (parsed.size + blockSize - 1) / blockSize
            let bodyLength = bodyBlocks * blockSize
            guard offset + bodyLength <= data.endIndex || parsed.size == 0 else {
                throw TarError.truncatedBody
            }
            let body: Data
            if parsed.size > 0 {
                body = data.subdata(in: offset..<(offset + parsed.size))
                offset += bodyLength
            } else {
                body = Data()
            }

            entries.append(TarEntry(
                name: parsed.name,
                type: TarEntryType(typeflag: parsed.typeflag),
                linkName: parsed.linkName,
                mode: parsed.mode,
                size: parsed.size,
                body: body
            ))
        }
        return entries
    }

    private struct ParsedHeader {
        let name: String
        let mode: UInt32
        let size: Int
        let typeflag: UInt8
        let linkName: String
    }

    private static func parseHeader(_ header: Data) throws -> ParsedHeader? {
        guard header.count == blockSize else {
            throw TarError.truncatedHeader
        }
        let base = header.startIndex

        func field(_ range: Range<Int>) -> Data {
            header.subdata(in: (base + range.lowerBound)..<(base + range.upperBound))
        }

        func cString(_ range: Range<Int>) -> String {
            let bytes = field(range)
            let nullTerminated = bytes.prefix { $0 != 0 }
            return String(decoding: nullTerminated, as: UTF8.self)
        }

        func octal(_ range: Range<Int>) -> Int {
            let string = cString(range).trimmingCharacters(in: .whitespaces)
            guard !string.isEmpty else {
                return 0
            }
            return Int(string, radix: 8) ?? 0
        }

        let checksumField = field(148..<156)
        let storedChecksum = octal(148..<156)
        var computed: Int = 0
        for (index, byte) in header.enumerated() {
            let position = index - base
            if (148..<156).contains(position) {
                computed += Int(UInt8(ascii: " "))
            } else if position < blockSize {
                computed += Int(byte)
            }
        }
        _ = checksumField
        guard computed == storedChecksum else {
            throw TarError.badHeaderChecksum
        }

        let name = cString(0..<100)
        let prefix = cString(345..<500)
        let fullName = prefix.isEmpty ? name : "\(prefix)/\(name)"
        let mode = UInt32(octal(100..<108))
        let size = octal(124..<136)
        let typeflagByte = field(156..<157).first ?? 0
        let linkName = cString(157..<257)

        return ParsedHeader(name: fullName, mode: mode, size: size, typeflag: typeflagByte, linkName: linkName)
    }
}
