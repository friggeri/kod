import Compression
import Foundation

/// Errors from gzip container parsing/decoding — distinct from tar-level
/// or catalog-level errors so a caller can tell exactly which stage of
/// "download → digest-check → gunzip → untar → validate layout" failed.
public enum GzipError: Error, Equatable, Sendable {
    case notGzip
    case unsupportedCompressionMethod(UInt8)
    case truncatedHeader
    case truncatedTrailer
    case decompressedSizeExceeded(limit: Int)
    case streamFailure
    case crcMismatch
    case sizeMismatch
}

/// A minimal, dependency-free gzip (RFC 1952) reader/writer built on top
/// of Apple's `Compression` framework, whose `COMPRESSION_ZLIB`
/// algorithm implements raw DEFLATE (RFC 1951) with no zlib or gzip
/// framing of its own — so the 10-byte gzip header and 8-byte
/// CRC32+ISIZE trailer are handled by this type directly. Both real
/// upstream artifacts Kod's catalog can reference (Node.js's official
/// `.tar.gz` releases, `rust-analyzer`'s standalone `.tar.gz` releases)
/// use exactly this container, so this is production decode logic, not
/// test-only scaffolding.
///
/// `decompress` is the security-relevant half: it streams through
/// `compression_stream` in fixed-size chunks and aborts the instant
/// `maxDecompressedBytes` is exceeded, which is what actually stops a
/// decompression bomb — checking the final size only after fully
/// inflating would already have exhausted memory by the time that check
/// ran.
public enum GzipCodec {
    private static let magicByte0: UInt8 = 0x1F
    private static let magicByte1: UInt8 = 0x8B
    private static let deflateMethod: UInt8 = 8
    private static let chunkSize = 64 * 1024

    public static func compress(_ data: Data) throws -> Data {
        var destinationSize = max(data.count / 2, 64)
        var compressedBody: Data?
        for _ in 0..<8 {
            var destination = [UInt8](repeating: 0, count: destinationSize)
            let writtenCount = data.withUnsafeBytes { rawBuffer -> Int in
                guard let sourcePointer = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_encode_buffer(
                    &destination,
                    destination.count,
                    sourcePointer,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
            if writtenCount > 0 {
                compressedBody = Data(destination.prefix(writtenCount))
                break
            }
            destinationSize *= 2
        }
        guard let compressedBody else {
            throw GzipError.streamFailure
        }

        var output = Data([magicByte0, magicByte1, deflateMethod, 0, 0, 0, 0, 0, 0, 0xFF])
        output.append(compressedBody)
        let crc = CRC32.checksum(data)
        var isize = UInt32(truncatingIfNeeded: data.count)
        var crcValue = crc
        withUnsafeBytes(of: &crcValue) { output.append(contentsOf: $0) }
        withUnsafeBytes(of: &isize) { output.append(contentsOf: $0) }
        return output
    }

    /// Decompresses `data` as a gzip stream, refusing to produce more
    /// than `maxDecompressedBytes` of output and verifying the trailer's
    /// CRC32 and (mod 2^32) size against what was actually produced.
    public static func decompress(_ data: Data, maxDecompressedBytes: Int) throws -> Data {
        guard data.count >= 18 else {
            throw GzipError.truncatedHeader
        }
        guard data[data.startIndex] == magicByte0, data[data.startIndex + 1] == magicByte1 else {
            throw GzipError.notGzip
        }
        let method = data[data.startIndex + 2]
        guard method == deflateMethod else {
            throw GzipError.unsupportedCompressionMethod(method)
        }
        let flags = data[data.startIndex + 3]
        var cursor = data.startIndex + 10

        // FEXTRA
        if flags & 0x04 != 0 {
            guard cursor + 2 <= data.endIndex else {
                throw GzipError.truncatedHeader
            }
            let extraLength = Int(data[cursor]) | (Int(data[cursor + 1]) << 8)
            cursor += 2 + extraLength
        }
        // FNAME
        if flags & 0x08 != 0 {
            cursor = try skipNullTerminated(data, from: cursor)
        }
        // FCOMMENT
        if flags & 0x10 != 0 {
            cursor = try skipNullTerminated(data, from: cursor)
        }
        // FHCRC
        if flags & 0x02 != 0 {
            cursor += 2
        }
        guard cursor <= data.endIndex, data.endIndex - cursor >= 8 else {
            throw GzipError.truncatedTrailer
        }

        let trailerStart = data.endIndex - 8
        let bodyRange = cursor..<trailerStart
        let expectedCRC = readLittleEndianUInt32(data, at: trailerStart)
        let expectedSize = readLittleEndianUInt32(data, at: trailerStart + 4)

        let output = try inflate(Data(data[bodyRange]), maxDecompressedBytes: maxDecompressedBytes)

        guard UInt32(truncatingIfNeeded: output.count) == expectedSize else {
            throw GzipError.sizeMismatch
        }
        guard CRC32.checksum(output) == expectedCRC else {
            throw GzipError.crcMismatch
        }
        return output
    }

    private static func skipNullTerminated(_ data: Data, from start: Int) throws -> Int {
        var index = start
        while index < data.endIndex, data[index] != 0 {
            index += 1
        }
        guard index < data.endIndex else {
            throw GzipError.truncatedHeader
        }
        return index + 1
    }

    private static func readLittleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func inflate(_ body: Data, maxDecompressedBytes: Int) throws -> Data {
        // `compression_stream`'s `dst_ptr`/`src_ptr` are non-optional
        // pointers, but the real pointers are only assigned right
        // before each `compression_stream_process` call below; these
        // placeholders exist only so `compression_stream_init` has a
        // legally-typed (never dereferenced) value to start from, and
        // must outlive the whole stream's lifetime rather than being a
        // transient `&localVar` (whose validity is not guaranteed past
        // the single call it's passed into).
        let placeholder = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { placeholder.deallocate() }

        var stream = compression_stream(dst_ptr: placeholder, dst_size: 0, src_ptr: UnsafePointer(placeholder), src_size: 0, state: nil)
        var status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard status == COMPRESSION_STATUS_OK else {
            throw GzipError.streamFailure
        }
        defer { compression_stream_destroy(&stream) }

        var output = Data()
        var sourceBuffer = [UInt8](body)
        var destinationBuffer = [UInt8](repeating: 0, count: chunkSize)

        let result: Result<Void, Error> = sourceBuffer.withUnsafeMutableBufferPointer { sourcePointer -> Result<Void, Error> in
            stream.src_ptr = sourcePointer.baseAddress.map { UnsafePointer($0) } ?? UnsafePointer(placeholder)
            stream.src_size = sourcePointer.count

            while true {
                let stepResult: Result<Bool, Error> = destinationBuffer.withUnsafeMutableBufferPointer { destinationPointer -> Result<Bool, Error> in
                    guard let destinationBaseAddress = destinationPointer.baseAddress else {
                        return .failure(GzipError.streamFailure)
                    }
                    stream.dst_ptr = destinationBaseAddress
                    stream.dst_size = destinationPointer.count
                    // The entire compressed body is already provided as
                    // `stream.src_size` from the very first call (this
                    // decodes a complete in-memory gzip member, never a
                    // live network stream), so FINALIZE is always
                    // correct here — per Apple's own guidance, *not*
                    // setting it on a stream's last (or only) input can
                    // leave a truncated/corrupt input looping forever
                    // rather than failing.
                    status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))

                    let producedCount = destinationPointer.count - stream.dst_size
                    if producedCount > 0 {
                        if output.count + producedCount > maxDecompressedBytes {
                            return .failure(GzipError.decompressedSizeExceeded(limit: maxDecompressedBytes))
                        }
                        output.append(contentsOf: destinationPointer.prefix(producedCount))
                    }

                    switch status {
                    case COMPRESSION_STATUS_OK:
                        return .success(true)
                    case COMPRESSION_STATUS_END:
                        return .success(false)
                    default:
                        return .failure(GzipError.streamFailure)
                    }
                }

                switch stepResult {
                case .success(let shouldContinue):
                    if !shouldContinue {
                        return .success(())
                    }
                case .failure(let error):
                    return .failure(error)
                }
            }
        }

        switch result {
        case .success:
            return output
        case .failure(let error):
            throw error
        }
    }
}
