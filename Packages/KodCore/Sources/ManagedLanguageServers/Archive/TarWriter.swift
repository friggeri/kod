import Foundation

/// Writes a minimal valid USTAR tar archive — used only by fixture/tool
/// code (`ManagedCatalogTool`, `ManagedLanguageServersTests`) to build
/// reproducible test artifacts and hostile-entry fixtures byte-for-byte
/// under this repository's own control, never by the installer itself
/// (which only ever *reads* tar archives it downloaded).
public enum TarWriter {
    private static let blockSize = 512

    public struct RawEntry {
        public let name: String
        public let type: TarEntryType
        public let linkName: String
        public let mode: UInt32
        public let body: Data

        public init(name: String, type: TarEntryType = .regularFile, linkName: String = "", mode: UInt32 = 0o644, body: Data = Data()) {
            self.name = name
            self.type = type
            self.linkName = linkName
            self.mode = mode
            self.body = body
        }
    }

    public static func write(_ entries: [RawEntry]) -> Data {
        var output = Data()
        for entry in entries {
            output.append(header(for: entry))
            output.append(entry.body)
            let padding = paddingLength(entry.body.count)
            if padding > 0 {
                output.append(Data(repeating: 0, count: padding))
            }
        }
        // Two all-zero trailing blocks mark end-of-archive.
        output.append(Data(repeating: 0, count: blockSize * 2))
        return output
    }

    private static func paddingLength(_ size: Int) -> Int {
        let remainder = size % blockSize
        return remainder == 0 ? 0 : (blockSize - remainder)
    }

    private static func typeflagByte(_ type: TarEntryType) -> UInt8 {
        switch type {
        case .regularFile:
            return UInt8(ascii: "0")
        case .directory:
            return UInt8(ascii: "5")
        case .symbolicLink:
            return UInt8(ascii: "2")
        case .hardLink:
            return UInt8(ascii: "1")
        case .characterDevice:
            return UInt8(ascii: "3")
        case .blockDevice:
            return UInt8(ascii: "4")
        case .fifo:
            return UInt8(ascii: "6")
        case .other(let raw):
            return raw
        }
    }

    private static func header(for entry: RawEntry) -> Data {
        var block = [UInt8](repeating: 0, count: blockSize)

        func writeString(_ string: String, at offset: Int, length: Int) {
            let bytes = Array(string.utf8.prefix(length))
            for (index, byte) in bytes.enumerated() {
                block[offset + index] = byte
            }
        }

        func writeOctal(_ value: Int, at offset: Int, length: Int) {
            let octalString = String(value, radix: 8)
            let padded = String(repeating: "0", count: max(0, length - 1 - octalString.count)) + octalString
            writeString(padded, at: offset, length: length - 1)
            block[offset + length - 1] = 0
        }

        // Allow the fixture generator itself to name entries with an
        // absolute path or `..` traversal on purpose (hostile-entry
        // tests build these) — this writer never validates `name`; only
        // `SecureArchiveExtractor`'s reader-side checks are a security
        // boundary.
        writeString(entry.name, at: 0, length: 100)
        writeOctal(Int(entry.mode), at: 100, length: 8)
        writeOctal(0, at: 108, length: 8)
        writeOctal(0, at: 116, length: 8)
        writeOctal(entry.body.count, at: 124, length: 12)
        writeOctal(0, at: 136, length: 12)
        for index in 148..<156 {
            block[index] = UInt8(ascii: " ")
        }
        block[156] = typeflagByte(entry.type)
        writeString(entry.linkName, at: 157, length: 100)
        writeString("ustar", at: 257, length: 6)
        writeString("00", at: 263, length: 2)

        var checksum = 0
        for byte in block {
            checksum += Int(byte)
        }
        writeOctal(checksum, at: 148, length: 8)
        block[155] = 0

        return Data(block)
    }
}
