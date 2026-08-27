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

    /// Loads `url`, refusing *before reading any content* when the file is
    /// larger than the configured rendering policy's full-fidelity byte
    /// limit.
    ///
    /// The refusal is a typed `SourceIOError.fileExceedsRenderingByteLimit`
    /// carrying the URL, the real size, and the limit, so the host can ask
    /// the user whether to load it anyway and then call
    /// `loadIgnoringByteLimit(url:version:fallbackEncodingRawValue:)`.
    /// Without this guard a 2 GB file was fully read and decoded first and
    /// only *then* declared "safety mode", which is the expensive half of
    /// the work the limit exists to avoid.
    ///
    /// `approval` is the user's previously-given answer to exactly that
    /// question. It is honoured only while it still describes the file on
    /// disk: a replaced, deleted-and-recreated, or grown file no longer
    /// matches, and the refusal is raised again rather than silently
    /// loading something nobody agreed to. The match is re-checked
    /// against the open descriptor, not against a second `stat`, so the
    /// file that is read is the file that was approved.
    ///
    /// A file system that cannot report a size without reading (see
    /// `ReadOnlyFileSystem.metadata(at:)`) skips the guard, and the
    /// post-read safety-mode reason applies as before.
    public func load(
        url: URL,
        version: Int = 1,
        fallbackEncodingRawValue: UInt? = nil,
        approval: OversizedReadApproval? = nil
    ) throws -> SourceSnapshot {
        guard let limit = renderingSafetyPolicy?.fullFidelityByteLimit else {
            return try readAndLoad(
                url: url,
                version: version,
                fallbackEncodingRawValue: fallbackEncodingRawValue,
                validate: { _ in }
            )
        }
        if let metadata = try fileSystem.metadata(at: url),
           metadata.byteCount > limit,
           approval?.covers(metadata) != true {
            throw SourceIOError.fileExceedsRenderingByteLimit(
                url: url,
                byteCount: metadata.byteCount,
                limit: limit
            )
        }
        return try readAndLoad(
            url: url,
            version: version,
            fallbackEncodingRawValue: fallbackEncodingRawValue,
            validate: { metadata in
                guard metadata.byteCount > limit else {
                    return
                }
                guard approval?.covers(metadata) == true else {
                    throw SourceIOError.fileExceedsRenderingByteLimit(
                        url: url,
                        byteCount: metadata.byteCount,
                        limit: limit
                    )
                }
            }
        )
    }

    /// Size and on-disk identity of `url` without reading it, so a host
    /// that is about to ask the user for oversized-file consent can pin
    /// that consent to the file it is asking about.
    public func metadata(at url: URL) throws -> ReadOnlyFileMetadata? {
        try fileSystem.metadata(at: url)
    }

    /// `metadata(at:)` run off the caller's actor, with the caller's
    /// cancellation chained onto it.
    public func metadataDetached(at url: URL) async throws -> ReadOnlyFileMetadata? {
        try await detachedRead { [self] in
            try fileSystem.metadata(at: url)
        }
    }

    /// The explicit retry for a file `load(url:…)` refused as oversized:
    /// reads and decodes it in full regardless of the policy's byte limit.
    /// The resulting snapshot still carries the policy's
    /// `safetyModeReason`, so the renderer keeps degrading gracefully —
    /// the only thing waived here is the refusal to read at all.
    ///
    /// Separate entry point rather than a `Bool` parameter so that
    /// "load a file the user was warned about" can never be the result of
    /// a defaulted argument. Hosts that keep consent across loads should
    /// use `load(url:version:fallbackEncodingRawValue:approval:)`
    /// instead, so the consent stays bound to one file at one size; this
    /// entry point is for a host that has *just* asked about *this* read.
    public func loadIgnoringByteLimit(
        url: URL,
        version: Int = 1,
        fallbackEncodingRawValue: UInt? = nil
    ) throws -> SourceSnapshot {
        try readAndLoad(
            url: url,
            version: version,
            fallbackEncodingRawValue: fallbackEncodingRawValue,
            validate: { _ in }
        )
    }

    private func readAndLoad(
        url: URL,
        version: Int,
        fallbackEncodingRawValue: UInt?,
        validate: @escaping @Sendable (ReadOnlyFileMetadata) throws -> Void
    ) throws -> SourceSnapshot {
        let payload = try fileSystem.readFile(at: url, validating: validate)
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

    /// `load(url:version:fallbackEncodingRawValue:approval:)` run off the
    /// caller's actor, with the caller's cancellation chained onto the
    /// read.
    ///
    /// Hosts must not block the main actor on file I/O, but the obvious
    /// `try await Task.detached { loader.load(url:) }.value` is a
    /// cancellation hole: a detached task has no parent, so closing the
    /// tab, superseding the reload, or shutting the window down leaves
    /// the read running to completion. Chaining cancellation through
    /// `withTaskCancellationHandler` hands it to the detached task, where
    /// `LocalReadOnlyFileSystem`'s chunked read observes it.
    public func loadDetached(
        url: URL,
        version: Int = 1,
        fallbackEncodingRawValue: UInt? = nil,
        approval: OversizedReadApproval? = nil
    ) async throws -> SourceSnapshot {
        try await detachedRead { [self] in
            try load(
                url: url,
                version: version,
                fallbackEncodingRawValue: fallbackEncodingRawValue,
                approval: approval
            )
        }
    }

    /// The off-actor, cancellation-chained twin of
    /// `loadIgnoringByteLimit(url:version:fallbackEncodingRawValue:)`.
    /// The unrestricted retry is precisely the read most worth being able
    /// to abandon: it is, by definition, the large one.
    public func loadIgnoringByteLimitDetached(
        url: URL,
        version: Int = 1,
        fallbackEncodingRawValue: UInt? = nil
    ) async throws -> SourceSnapshot {
        try await detachedRead { [self] in
            try loadIgnoringByteLimit(
                url: url,
                version: version,
                fallbackEncodingRawValue: fallbackEncodingRawValue
            )
        }
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
