import Foundation
import SourceModel

public struct SourceFileMetadata: Equatable, Sendable {
    public let url: URL
    public let version: Int
    public let modificationDate: Date?

    public init(url: URL, version: Int = 1, modificationDate: Date? = nil) {
        self.url = url
        self.version = version
        self.modificationDate = modificationDate
    }
}

public struct SourceSnapshotLoader: Sendable {
    private let fileSystem: any ReadOnlyFileSystem
    private let renderingSafetyPolicy: SourceRenderingSafetyPolicy?

    public init(
        fileSystem: any ReadOnlyFileSystem = LocalReadOnlyFileSystem(),
        renderingSafetyPolicy: SourceRenderingSafetyPolicy? = nil
    ) {
        self.fileSystem = fileSystem
        self.renderingSafetyPolicy = renderingSafetyPolicy
    }

    public func load(
        url: URL,
        version: Int = 1,
        fallbackEncodingRawValue: UInt? = nil
    ) throws -> SourceSnapshot {
        let payload = try fileSystem.readFile(at: url)
        return try load(
            data: payload.data,
            metadata: SourceFileMetadata(
                url: url,
                version: version,
                modificationDate: payload.modificationDate
            ),
            fallbackEncodingRawValue: fallbackEncodingRawValue
        )
    }

    public func load(
        data: Data,
        url: URL,
        version: Int = 1,
        modificationDate: Date? = nil,
        fallbackEncodingRawValue: UInt? = nil
    ) throws -> SourceSnapshot {
        try load(
            data: data,
            metadata: SourceFileMetadata(
                url: url,
                version: version,
                modificationDate: modificationDate
            ),
            fallbackEncodingRawValue: fallbackEncodingRawValue
        )
    }

    public func load(
        data: Data,
        metadata: SourceFileMetadata,
        fallbackEncodingRawValue: UInt? = nil
    ) throws -> SourceSnapshot {
        let decoding = try SourceDecoder.decode(
            data,
            url: metadata.url,
            fallbackEncodingRawValue: fallbackEncodingRawValue
        )
        let snapshot = SourceSnapshot(
            url: metadata.url,
            version: metadata.version,
            originalData: data,
            modificationDate: metadata.modificationDate,
            decoding: decoding
        )
        guard let reason = renderingSafetyPolicy?.reason(
            fileByteCount: data.count,
            longestLineUTF8Length: snapshot.longestLineUTF8Length
        ) else {
            return snapshot
        }
        return SourceSnapshot(
            url: metadata.url,
            version: metadata.version,
            originalData: data,
            modificationDate: metadata.modificationDate,
            decoding: decoding,
            safetyModeReason: reason
        )
    }
}

private enum SourceDecoder {
    static func decode(
        _ data: Data,
        url: URL,
        fallbackEncodingRawValue: UInt?
    ) throws -> SourceDecodingResult {
        let bytes = Array(data.prefix(4))

        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return try decodeMarked(
                data,
                markLength: 4,
                stringEncoding: .utf32BigEndian,
                sourceEncoding: .utf32BigEndian
            )
        }
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return try decodeMarked(
                data,
                markLength: 4,
                stringEncoding: .utf32LittleEndian,
                sourceEncoding: .utf32LittleEndian
            )
        }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return try decodeMarked(
                data,
                markLength: 3,
                stringEncoding: .utf8,
                sourceEncoding: .utf8
            )
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return try decodeMarked(
                data,
                markLength: 2,
                stringEncoding: .utf16BigEndian,
                sourceEncoding: .utf16BigEndian
            )
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            return try decodeMarked(
                data,
                markLength: 2,
                stringEncoding: .utf16LittleEndian,
                sourceEncoding: .utf16LittleEndian
            )
        }
        if let text = String(data: data, encoding: .utf8) {
            return SourceDecodingResult(
                encoding: .utf8,
                text: text,
                normalizedUTF8: data,
                hadByteOrderMark: false
            )
        }
        if let fallbackEncodingRawValue {
            let stringEncoding = String.Encoding(rawValue: fallbackEncodingRawValue)
            if let text = String(data: data, encoding: stringEncoding) {
                return SourceDecodingResult(
                    encoding: .fallback(rawValue: fallbackEncodingRawValue),
                    text: text,
                    normalizedUTF8: Data(text.utf8),
                    hadByteOrderMark: false
                )
            }
            throw SourceIOError.fallbackEncodingFailed(fallbackEncodingRawValue)
        }

        throw SourceIOError.unsupportedEncoding(url)
    }

    private static func decodeMarked(
        _ data: Data,
        markLength: Int,
        stringEncoding: String.Encoding,
        sourceEncoding: SourceEncoding
    ) throws -> SourceDecodingResult {
        let content = Data(data.dropFirst(markLength))
        guard let text = String(data: content, encoding: stringEncoding) else {
            throw SourceIOError.fallbackEncodingFailed(stringEncoding.rawValue)
        }
        return SourceDecodingResult(
            encoding: sourceEncoding,
            text: text,
            normalizedUTF8: sourceEncoding == .utf8 ? content : Data(text.utf8),
            hadByteOrderMark: true
        )
    }
}
