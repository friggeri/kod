import Foundation

public enum InstallLockError: Error, Equatable, Sendable {
    case couldNotOpenLockFile(String)
    case couldNotAcquireLock(String)
}

/// An acquired `InstallLock`, holding the raw open file descriptor that
/// is actually flock'd. Must be passed back to `InstallLock.release` —
/// there is deliberately no `deinit`-based auto-release, so a lock's
/// lifetime is always visible at the call site (typically a `defer`)
/// rather than tied to Swift's non-deterministic object deallocation
/// timing.
struct InstallLockHandle: Sendable {
    fileprivate let descriptor: Int32
}

/// A cross-process exclusive lock backed by `flock(2)` on a fixed file
/// under `ManagedInstallPaths.locksDirectory`, one per `serverID`. This
/// is the outermost guard around every filesystem mutation an install/
/// upgrade/rollback/remove operation performs (stage → activate,
/// pointer swap, removal) — even if two separate Kod processes (or, in
/// tests, two concurrent in-process operations that both fall through
/// to the filesystem layer) both attempt to mutate the same server's
/// install state at once, only one ever holds this lock at a time.
///
/// `ManagedInstallController` layers this under its own in-process
/// per-`serverID` task-coalescing (two concurrent `install()` calls for
/// the same server share one `Task`, so they don't even both reach this
/// lock in the common case) — this type is the deeper, OS-level
/// guarantee that holds even if that in-process coalescing were ever
/// bypassed.
///
/// `acquire()`/`release()` are async-friendly: the actual blocking
/// `flock` syscall always runs on a dedicated `DispatchQueue` (never
/// directly on a Swift-concurrency cooperative-pool thread, and never
/// while `ManagedInstallController`'s actor executor is itself
/// blocked), so a caller can hold the lock across `await`ed download/
/// extraction work without starving other unrelated actors or tasks.
final class InstallLock: @unchecked Sendable {
    private let fileURL: URL
    private let queue: DispatchQueue

    init(fileURL: URL, fileManager: FileManager = .default) throws {
        self.fileURL = fileURL
        self.queue = DispatchQueue(label: "kod.managed-install-lock.\(fileURL.lastPathComponent)")
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    func acquire() async throws -> InstallLockHandle {
        let path = fileURL.path
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<InstallLockHandle, Error>) in
            queue.async {
                let descriptor = open(path, O_RDWR | O_CREAT, 0o600)
                guard descriptor >= 0 else {
                    continuation.resume(throwing: InstallLockError.couldNotOpenLockFile(path))
                    return
                }
                guard flock(descriptor, LOCK_EX) == 0 else {
                    close(descriptor)
                    continuation.resume(throwing: InstallLockError.couldNotAcquireLock(path))
                    return
                }
                continuation.resume(returning: InstallLockHandle(descriptor: descriptor))
            }
        }
    }

    func release(_ handle: InstallLockHandle) {
        queue.async {
            flock(handle.descriptor, LOCK_UN)
            close(handle.descriptor)
        }
    }
}

