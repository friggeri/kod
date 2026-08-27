import Darwin
import Foundation
import SourceModel

/// A file's identity on disk — the volume it lives on plus its inode —
/// which is what actually stays the same across renames and what actually
/// changes when a path is replaced.
///
/// A path is not an identity. Deleting `notes.txt` and writing a new
/// `notes.txt` produces the same URL and a different file, and every
/// decision Kod makes *about a specific file* (most importantly the
/// user's consent to load an oversized one) has to be pinned to the
/// latter.
public struct FileIdentity: Hashable, Sendable {
    public let volumeIdentifier: UInt64
    public let fileIdentifier: UInt64

    public init(volumeIdentifier: UInt64, fileIdentifier: UInt64) {
        self.volumeIdentifier = volumeIdentifier
        self.fileIdentifier = fileIdentifier
    }

    init(_ info: stat) {
        self.init(
            volumeIdentifier: UInt64(bitPattern: Int64(info.st_dev)),
            fileIdentifier: UInt64(info.st_ino)
        )
    }

    /// The identity of whatever `url` resolves to right now, or `nil`
    /// when nothing does.
    public static func current(for url: URL) -> FileIdentity? {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            return nil
        }
        return FileIdentity(info)
    }

    /// The identity of an already-open descriptor, which — unlike a
    /// second `stat` of the path — describes exactly the file that is
    /// about to be read.
    static func current(forDescriptor descriptor: Int32) -> FileIdentity? {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            return nil
        }
        return FileIdentity(info)
    }
}

public struct ReadOnlyFilePayload: Sendable {
    public let data: Data
    public let modificationDate: Date?
    /// Which file these bytes actually came from, when the file system
    /// can tell. `nil` for synthetic file systems.
    public let identity: FileIdentity?

    public init(
        data: Data,
        modificationDate: Date?,
        identity: FileIdentity? = nil
    ) {
        self.data = data
        self.modificationDate = modificationDate
        self.identity = identity
    }
}

/// What a file system can report about a file *without* reading its
/// contents, so a size policy can be applied before any bytes are pulled
/// into memory.
public struct ReadOnlyFileMetadata: Equatable, Sendable {
    public let byteCount: Int
    public let modificationDate: Date?
    /// The file's on-disk identity, when the file system can report one.
    public let identity: FileIdentity?

    public init(
        byteCount: Int,
        modificationDate: Date?,
        identity: FileIdentity? = nil
    ) {
        self.byteCount = byteCount
        self.modificationDate = modificationDate
        self.identity = identity
    }
}

public protocol ReadOnlyFileSystem: Sendable {
    func readFile(at url: URL) throws -> ReadOnlyFilePayload

    /// Size and modification date without reading content. Returning
    /// `nil` means "this file system cannot report a size cheaply", and
    /// callers then fall back to their post-read behavior; it never means
    /// "empty file".
    func metadata(at url: URL) throws -> ReadOnlyFileMetadata?

    /// Reads `url` only if `validate` accepts the metadata observed on
    /// the file that is actually about to be read.
    ///
    /// The separate `metadata(at:)`-then-`readFile(at:)` pair cannot
    /// express "read *this* file": the two calls resolve the path
    /// independently, so a replacement in between is invisible. Callers
    /// that authorised a read for a specific file and a specific size —
    /// oversized-file consent, above all — need the check and the read to
    /// see the same bytes.
    func readFile(
        at url: URL,
        validating validate: @Sendable (ReadOnlyFileMetadata) throws -> Void
    ) throws -> ReadOnlyFilePayload
}

extension ReadOnlyFileSystem {
    /// Default for in-memory/synthetic file systems that have no cheap
    /// stat: no pre-read size is available.
    public func metadata(at url: URL) throws -> ReadOnlyFileMetadata? {
        nil
    }

    /// Best-effort default for file systems that cannot bind a check to
    /// an open handle: validate whatever metadata is available, then
    /// read. Synthetic file systems have no replacement race to lose.
    public func readFile(
        at url: URL,
        validating validate: @Sendable (ReadOnlyFileMetadata) throws -> Void
    ) throws -> ReadOnlyFilePayload {
        if let metadata = try metadata(at: url) {
            try validate(metadata)
        }
        return try readFile(at: url)
    }
}

/// A user's answer to "this file is above the safety limit, load it
/// anyway?", pinned to the file that was actually asked about.
///
/// Consent keyed by URL alone survives everything it should not: the file
/// being replaced, deleted and recreated, or grown from the 11 MB the
/// user agreed to into something far larger. Carrying the identity and
/// the approved byte count makes the approval describe one file at one
/// size, so any of those events simply fails to match and the question is
/// asked again (or, for a non-interactive reload, declined).
public struct OversizedReadApproval: Equatable, Sendable {
    /// The file the user was asked about. `nil` only when the file system
    /// cannot report identities at all, in which case the byte ceiling is
    /// the whole of the guarantee.
    public let identity: FileIdentity?
    /// The size the user agreed to. A file that has grown past this has
    /// not been approved at its new size.
    public let byteCount: Int

    public init(identity: FileIdentity?, byteCount: Int) {
        self.identity = identity
        self.byteCount = byteCount
    }

    /// Whether this approval covers the file `metadata` describes.
    public func covers(_ metadata: ReadOnlyFileMetadata) -> Bool {
        guard metadata.byteCount <= byteCount else {
            return false
        }
        guard let identity else {
            // Nothing to pin to; the byte ceiling is all there is.
            return true
        }
        return metadata.identity == identity
    }
}

public enum SourceIOError: Error, Equatable, Sendable {
    case fileAbsent(URL)
    case permissionDenied(URL)
    case notRegularFile(URL)
    case metadataUnavailable(URL)
    case unreadableFile(URL)
    case unsupportedEncoding(URL)
    case fallbackEncodingFailed(UInt)
    /// The file is larger than the active rendering policy's
    /// full-fidelity byte limit and was therefore *not read at all*.
    ///
    /// This is a question, not a verdict: it carries everything the host
    /// needs to ask the user whether to load the file anyway (which URL,
    /// how large it actually is, and what the limit was), and the host
    /// answers by calling `SourceSnapshotLoader.loadIgnoringByteLimit`.
    /// Kod deliberately refuses to spend 10 MB+ of memory and decode time
    /// on the user's behalf before that question is answered.
    case fileExceedsRenderingByteLimit(url: URL, byteCount: Int, limit: Int)
    /// A raw byte read (an image or binary-plist preview, not decoded
    /// text) was refused *before reading* because the file is above the
    /// active raw-read policy's limit.
    ///
    /// Distinct from `fileExceedsRenderingByteLimit` because the two
    /// limits answer different questions and must be allowed to differ:
    /// the text limit exists because decoding and laying out a huge
    /// *document* is expensive, while a preview only has to decode an
    /// image or a property list, so ordinary large screenshots and asset
    /// catalogs stay previewable. This is the explicit refusal that
    /// replaces reading an arbitrarily large file into memory and hoping.
    case fileExceedsRawReadByteLimit(url: URL, byteCount: Int, limit: Int)
}

public struct LocalReadOnlyFileSystem: ReadOnlyFileSystem {
    /// How many bytes are pulled in between cancellation checks. Big
    /// enough that an ordinary source file is one or two reads, small
    /// enough that abandoning a multi-gigabyte read wastes at most this
    /// much work.
    static let defaultChunkByteCount = 1 << 20

    private let chunkByteCount: Int
    private let didReadChunk: (@Sendable (Int) -> Void)?

    public init() {
        self.init(chunkByteCount: Self.defaultChunkByteCount)
    }

    /// Seam for tests: a small chunk size plus a per-chunk observation
    /// point makes the cancellation boundary deterministic without
    /// needing a file large enough to lose a race against.
    init(
        chunkByteCount: Int,
        didReadChunk: (@Sendable (Int) -> Void)? = nil
    ) {
        self.chunkByteCount = max(1, chunkByteCount)
        self.didReadChunk = didReadChunk
    }

    public func metadata(at url: URL) throws -> ReadOnlyFileMetadata? {
        let values = try resourceValues(at: url)
        guard values.isRegularFile == true else {
            throw SourceIOError.notRegularFile(url)
        }
        guard let fileSize = values.fileSize else {
            throw SourceIOError.metadataUnavailable(url)
        }
        return ReadOnlyFileMetadata(
            byteCount: fileSize,
            modificationDate: values.contentModificationDate,
            identity: FileIdentity.current(for: url)
        )
    }

    public func readFile(at url: URL) throws -> ReadOnlyFilePayload {
        try readFile(at: url, validating: { _ in })
    }

    /// Opens the file first and validates the metadata read back from the
    /// *open descriptor*, so the check and the read cannot be talking
    /// about two different files.
    public func readFile(
        at url: URL,
        validating validate: @Sendable (ReadOnlyFileMetadata) throws -> Void
    ) throws -> ReadOnlyFilePayload {
        let values = try resourceValues(at: url)

        guard values.isRegularFile == true else {
            throw SourceIOError.notRegularFile(url)
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw Self.mappedReadError(error, url: url, metadata: false)
        }
        defer { try? handle.close() }

        var openInfo = stat()
        guard fstat(handle.fileDescriptor, &openInfo) == 0 else {
            throw SourceIOError.metadataUnavailable(url)
        }
        guard openInfo.st_mode & S_IFMT == S_IFREG else {
            throw SourceIOError.notRegularFile(url)
        }
        let identity = FileIdentity(openInfo)
        let modificationDate = values.contentModificationDate
        try validate(
            ReadOnlyFileMetadata(
                byteCount: Int(openInfo.st_size),
                modificationDate: modificationDate,
                identity: identity
            )
        )

        return ReadOnlyFilePayload(
            data: try readAllBytes(
                from: handle,
                url: url,
                expectedByteCount: Int(openInfo.st_size)
            ),
            modificationDate: modificationDate,
            identity: identity
        )
    }

    /// Reads the whole file eagerly, a bounded chunk at a time, checking
    /// for cancellation between chunks.
    ///
    /// Deliberately *not* `Data(contentsOf: url, options: .mappedIfSafe)`:
    /// the returned `Data` becomes a `SourceSnapshot`'s retained
    /// `originalData` and outlives this call by an unbounded amount. A
    /// memory-mapped region is a live window onto a file Kod does not
    /// control — an external truncation or overwrite turns a later read
    /// of an already-"loaded" snapshot into a SIGBUS or silently
    /// different bytes. An eager copy makes a snapshot exactly what it
    /// claims to be: the file's contents at the moment it was read.
    ///
    /// Deliberately *not* a plain `Data(contentsOf:)` either: that is one
    /// uninterruptible call, so a tab closed (or a reload superseded)
    /// while a 2 GB file is being pulled in keeps paying for every
    /// remaining byte. Chunking is what makes `Task.checkCancellation()`
    /// reachable at all; the cost is one `Data.append` per chunk.
    private func readAllBytes(
        from handle: FileHandle,
        url: URL,
        expectedByteCount: Int?
    ) throws -> Data {
        var data = Data()
        if let expectedByteCount, expectedByteCount > 0 {
            data.reserveCapacity(expectedByteCount)
        }
        while true {
            try Task.checkCancellation()
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: chunkByteCount)
            } catch {
                throw Self.mappedReadError(error, url: url, metadata: false)
            }
            guard let chunk, !chunk.isEmpty else {
                break
            }
            data.append(chunk)
            didReadChunk?(data.count)
        }
        try Task.checkCancellation()
        return data
    }

    private func resourceValues(at url: URL) throws -> URLResourceValues {
        do {
            return try url.resourceValues(forKeys: [
                .contentModificationDateKey,
                .isRegularFileKey,
                .fileSizeKey
            ])
        } catch {
            throw Self.mappedReadError(error, url: url, metadata: true)
        }
    }

    private static func mappedReadError(
        _ error: Error,
        url: URL,
        metadata: Bool
    ) -> SourceIOError {
        let cocoaError = error as NSError
        switch cocoaError.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
            return .fileAbsent(url)
        case NSFileReadNoPermissionError:
            return .permissionDenied(url)
        default:
            return metadata ? .metadataUnavailable(url) : .unreadableFile(url)
        }
    }
}
