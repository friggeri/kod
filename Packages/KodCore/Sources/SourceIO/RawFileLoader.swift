import Foundation

/// Runs a blocking read off the caller's actor while keeping the caller's
/// cancellation attached to it.
///
/// A bare `Task.detached { … }.value` is the shape this exists to
/// replace: a detached task has no parent, so cancelling the caller —
/// closing the tab, superseding the load, shutting the window down —
/// leaves the read running to completion against a file that may be
/// arbitrarily large. `withTaskCancellationHandler` hands the
/// cancellation across the isolation boundary, where the chunked read
/// observes it.
func detachedRead<T: Sendable>(
    _ operation: @escaping @Sendable () throws -> T
) async throws -> T {
    let task = Task.detached(priority: .userInitiated) {
        try Task.checkCancellation()
        return try operation()
    }
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}

/// How large a file may be before Kod refuses to pull its raw bytes into
/// memory.
///
/// Separate from `SourceRenderingSafetyPolicy` on purpose. That policy
/// bounds *text* Kod is about to decode, tokenize, and lay out, which is
/// why its default is a deliberately conservative 10 MB. Raw reads feed
/// image and binary-plist previews, where the work is one decode and no
/// layout, and where perfectly ordinary files — a screenshot from a 6K
/// display, a large asset catalog, a device-support plist — routinely sit
/// above that text limit. Sharing one number would either make previews
/// refuse files they can trivially handle or raise the text limit to
/// somewhere it does not belong.
public struct RawFileReadPolicy: Equatable, Sendable {
    public let byteLimit: Int

    public init(byteLimit: Int) {
        self.byteLimit = max(0, byteLimit)
    }

    /// 64 MiB: comfortably above every image and property list a preview
    /// is expected to open, and still a bound rather than "whatever is on
    /// disk".
    public static let previewDefault = RawFileReadPolicy(
        byteLimit: 64 * 1_024 * 1_024
    )
}

/// Reads a file's exact bytes, bounded by an explicit policy and
/// cancellable by the caller.
///
/// `SourceSnapshotLoader` is the wrong tool for image and binary-plist
/// previews: they need the bytes *undecoded*, and forcing them through
/// text decoding is what made previews fall back to an unbounded
/// `Task.detached` read in the first place. This is that read, with the
/// two properties the ad-hoc version lacked — a size limit that fails with
/// a typed error instead of an out-of-memory crash, and cancellation that
/// actually reaches the file handle.
public struct RawFileLoader: Sendable {
    private let fileSystem: any ReadOnlyFileSystem
    private let policy: RawFileReadPolicy

    public init(
        fileSystem: any ReadOnlyFileSystem = LocalReadOnlyFileSystem(),
        policy: RawFileReadPolicy = .previewDefault
    ) {
        self.fileSystem = fileSystem
        self.policy = policy
    }

    /// Reads `url`, refusing *before reading any content* when the file
    /// is above the policy's limit.
    public func load(url: URL) throws -> Data {
        let limit = policy.byteLimit
        let payload = try fileSystem.readFile(at: url) { metadata in
            guard metadata.byteCount > limit else {
                return
            }
            throw SourceIOError.fileExceedsRawReadByteLimit(
                url: url,
                byteCount: metadata.byteCount,
                limit: limit
            )
        }
        // A file system that cannot report a size before reading still
        // must not hand back an unbounded buffer.
        guard payload.data.count <= limit else {
            throw SourceIOError.fileExceedsRawReadByteLimit(
                url: url,
                byteCount: payload.data.count,
                limit: limit
            )
        }
        return payload.data
    }

    /// `load(url:)` run off the caller's actor, with the caller's
    /// cancellation chained onto the read.
    public func loadDetached(url: URL) async throws -> Data {
        try await detachedRead { [self] in
            try load(url: url)
        }
    }
}
