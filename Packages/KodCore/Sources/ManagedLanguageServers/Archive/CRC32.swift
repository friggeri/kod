import Foundation

/// Standard CRC-32 (ISO-HDLC / zlib / gzip) checksum, used to write and
/// verify a gzip trailer (`GzipCodec`) without depending on zlib's C API
/// directly for just this one primitive.
enum CRC32 {
    private static let table: [UInt32] = {
        (0...255).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1 == 1) ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
