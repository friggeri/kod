import CoreServices
import Foundation

/// The subset of FSEvents flags Kod needs to classify a changed path.
public struct WorkspaceChangeFlags: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let created = WorkspaceChangeFlags(rawValue: 1 << 0)
    public static let removed = WorkspaceChangeFlags(rawValue: 1 << 1)
    public static let renamed = WorkspaceChangeFlags(rawValue: 1 << 2)
    public static let modified = WorkspaceChangeFlags(rawValue: 1 << 3)
    public static let isDirectory = WorkspaceChangeFlags(rawValue: 1 << 4)

    init(fsEventFlags: FSEventStreamEventFlags) {
        var flags: WorkspaceChangeFlags = []
        if fsEventFlags & UInt32(kFSEventStreamEventFlagItemCreated) != 0 {
            flags.insert(.created)
        }
        if fsEventFlags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 {
            flags.insert(.removed)
        }
        if fsEventFlags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 {
            flags.insert(.renamed)
        }
        if fsEventFlags & UInt32(kFSEventStreamEventFlagItemModified) != 0
            || fsEventFlags & UInt32(kFSEventStreamEventFlagItemInodeMetaMod) != 0 {
            flags.insert(.modified)
        }
        if fsEventFlags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 {
            flags.insert(.isDirectory)
        }
        self = flags
    }
}

/// One changed absolute path reported within a coalesced burst.
public struct WorkspaceChangePath: Equatable, Sendable {
    public let path: String
    public let flags: WorkspaceChangeFlags

    public init(path: String, flags: WorkspaceChangeFlags) {
        self.path = path
        self.flags = flags
    }
}

/// One coalesced burst of filesystem changes under a watched root.
public struct WorkspaceChangeBatch: Sendable {
    public let paths: [WorkspaceChangePath]

    public init(paths: [WorkspaceChangePath]) {
        self.paths = paths
    }

    /// `true` when any changed path is (or is inside) an ignore-defining
    /// file Kod knows about, meaning ignore state for the whole subtree
    /// under it may now be stale and worth a fuller re-check.
    public var mayHaveChangedIgnoreRules: Bool {
        paths.contains { changed in
            let name = (changed.path as NSString).lastPathComponent
            return name == ".gitignore" || name == ".ignore" || name == "info/exclude"
        }
    }
}

/// Watches one workspace root for filesystem changes via FSEvents,
/// coalescing bursts of individual events (e.g. many files touched by a
/// single `git checkout` or build) into a single batch delivered after a
/// short quiet window, per SPEC 5.6 ("Repeated write bursts are
/// coalesced").
///
/// FSEvents itself requires a `CFRunLoop` or dispatch queue to deliver
/// callbacks; this wraps that C API behind a `final class` confined to one
/// private serial dispatch queue (`@unchecked Sendable` is safe here
/// because every mutable stored property is only ever touched while
/// executing on that queue, including from the FSEvents callback itself).
public final class WorkspaceFileWatcher: @unchecked Sendable {
    private let root: URL
    private let coalescingWindow: TimeInterval
    private let onBatch: @Sendable (WorkspaceChangeBatch) -> Void
    private let queue = DispatchQueue(label: "com.kod.WorkspaceFileWatcher")

    private var stream: FSEventStreamRef?
    private var pendingPaths: [String: WorkspaceChangeFlags] = [:]
    private var coalescingTimer: DispatchSourceTimer?

    public init(
        root: URL,
        coalescingWindow: TimeInterval = 0.3,
        onBatch: @escaping @Sendable (WorkspaceChangeBatch) -> Void
    ) {
        self.root = root
        self.coalescingWindow = coalescingWindow
        self.onBatch = onBatch
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// Starts watching. No-op if already started. Must be balanced with
    /// `stop()` (or deinit) to release the underlying FSEvents stream.
    public func start() {
        queue.sync {
            guard stream == nil else {
                return
            }

            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )

            let flags = UInt32(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagUseCFTypes
            )

            guard let newStream = FSEventStreamCreate(
                kCFAllocatorDefault,
                { _, info, count, paths, eventFlags, _ in
                    guard let info else {
                        return
                    }
                    let watcher = Unmanaged<WorkspaceFileWatcher>.fromOpaque(info).takeUnretainedValue()
                    watcher.handleRawEvent(count: count, paths: paths, eventFlags: eventFlags)
                },
                &context,
                [root.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0,
                flags
            ) else {
                return
            }

            FSEventStreamSetDispatchQueue(newStream, queue)
            FSEventStreamStart(newStream)
            stream = newStream
        }
    }

    /// Stops watching and releases the FSEvents stream. Safe to call more
    /// than once, and safe to never call if the watcher is simply deinited.
    public func stop() {
        queue.sync {
            coalescingTimer?.cancel()
            coalescingTimer = nil
            pendingPaths.removeAll()
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            stream = nil
        }
    }

    /// Always invoked on `queue` (the same queue FSEvents delivers the C
    /// callback on, via `FSEventStreamSetDispatchQueue`), so mutating
    /// `pendingPaths`/`coalescingTimer` here needs no additional locking.
    private func handleRawEvent(
        count: Int,
        paths: UnsafeMutableRawPointer,
        eventFlags: UnsafePointer<FSEventStreamEventFlags>
    ) {
        guard let cfArray = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] else {
            return
        }

        for index in 0..<count {
            let path = cfArray[index]
            let flags = WorkspaceChangeFlags(fsEventFlags: eventFlags[index])
            pendingPaths[path, default: []].formUnion(flags)
        }

        scheduleFlush()
    }

    private func scheduleFlush() {
        coalescingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + coalescingWindow)
        timer.setEventHandler { [weak self] in
            self?.flush()
        }
        coalescingTimer = timer
        timer.resume()
    }

    private func flush() {
        coalescingTimer = nil
        guard !pendingPaths.isEmpty else {
            return
        }
        let batch = WorkspaceChangeBatch(
            paths: pendingPaths.map { WorkspaceChangePath(path: $0.key, flags: $0.value) }
                .sorted { $0.path < $1.path }
        )
        pendingPaths.removeAll()
        onBatch(batch)
    }
}
