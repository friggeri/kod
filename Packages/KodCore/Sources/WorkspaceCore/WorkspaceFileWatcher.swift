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

public enum WorkspaceFileWatcherError: Error, Equatable, Sendable {
    case streamCreationFailed
    case streamStartFailed
}

/// Injectable FSEvents operations for testing.
struct FSEventsOperations: @unchecked Sendable {
    var create: (
        CFAllocator?,
        @convention(c) (
            ConstFSEventStreamRef,
            UnsafeMutableRawPointer?,
            Int,
            UnsafeMutableRawPointer,
            UnsafePointer<FSEventStreamEventFlags>,
            UnsafePointer<FSEventStreamEventId>
        ) -> Void,
        UnsafeMutablePointer<FSEventStreamContext>?,
        CFArray,
        FSEventStreamEventId,
        CFTimeInterval,
        FSEventStreamCreateFlags
    ) -> FSEventStreamRef?

    var start: (FSEventStreamRef) -> Bool
    var setDispatchQueue: (FSEventStreamRef, DispatchQueue?) -> Void
    var stop: (FSEventStreamRef) -> Void
    var invalidate: (FSEventStreamRef) -> Void
    var release: (FSEventStreamRef) -> Void
}

extension FSEventsOperations {
    static let live = FSEventsOperations(
        create: { alloc, cb, ctx, paths, since, latency, flags in
            FSEventStreamCreate(alloc, cb, ctx, paths, since, latency, flags)
        },
        start: { FSEventStreamStart($0) },
        setDispatchQueue: { FSEventStreamSetDispatchQueue($0, $1) },
        stop: { FSEventStreamStop($0) },
        invalidate: { FSEventStreamInvalidate($0) },
        release: { FSEventStreamRelease($0) }
    )
}

struct TimerToken: Sendable {
    let cancel: @Sendable () -> Void
}

struct TimerOperations: @unchecked Sendable {
    var schedule: @Sendable (
        _ interval: TimeInterval,
        _ queue: DispatchQueue,
        _ handler: @escaping @Sendable () -> Void
    ) -> TimerToken
}

extension TimerOperations {
    static let live = TimerOperations { interval, queue, handler in
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval)
        timer.setEventHandler(handler: handler)
        timer.resume()
        return TimerToken { timer.cancel() }
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
    private let queueKey = DispatchSpecificKey<Void>()

    var fsEvents: FSEventsOperations = .live
    var timerOps: TimerOperations = .live

    private var lifecycle: StreamLifecycle?

    public init(
        root: URL,
        coalescingWindow: TimeInterval = 0.3,
        onBatch: @escaping @Sendable (WorkspaceChangeBatch) -> Void
    ) {
        self.root = root
        self.coalescingWindow = coalescingWindow
        self.onBatch = onBatch
        self.queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        stop()
    }

    private func runOnQueue<T>(_ block: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try block()
        } else {
            return try queue.sync(execute: block)
        }
    }

    /// Starts watching. No-op if already started. Must be balanced with
    /// `stop()` (or deinit) to release the underlying FSEvents stream.
    public func start() throws {
        try runOnQueue {
            guard lifecycle == nil else {
                return
            }

            let newLifecycle = StreamLifecycle(
                queue: queue,
                coalescingWindow: coalescingWindow,
                onBatch: onBatch,
                fsEvents: fsEvents,
                timerOps: timerOps
            )

            let info = Unmanaged.passRetained(newLifecycle)
            var context = FSEventStreamContext(
                version: 0,
                info: info.toOpaque(),
                retain: nil,
                release: { ptr in
                    guard let ptr else { return }
                    Unmanaged<StreamLifecycle>.fromOpaque(ptr).release()
                },
                copyDescription: nil
            )

            let flags = UInt32(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagUseCFTypes
            )

            guard let newStream = fsEvents.create(
                kCFAllocatorDefault,
                { _, infoPtr, count, paths, eventFlags, _ in
                    guard let infoPtr else { return }
                    let lc = Unmanaged<StreamLifecycle>.fromOpaque(infoPtr).takeUnretainedValue()
                    lc.handleRawEvent(count: count, paths: paths, eventFlags: eventFlags)
                },
                &context,
                [root.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0,
                flags
            ) else {
                info.release()
                throw WorkspaceFileWatcherError.streamCreationFailed
            }

            newLifecycle.stream = newStream
            fsEvents.setDispatchQueue(newStream, queue)

            if !fsEvents.start(newStream) {
                // By calling fsEvents.release here, the context's release block is invoked,
                // which balances the `Unmanaged.passRetained(newLifecycle)`.
                fsEvents.invalidate(newStream)
                fsEvents.release(newStream)
                throw WorkspaceFileWatcherError.streamStartFailed
            }

            self.lifecycle = newLifecycle
        }
    }

    /// Stops watching and releases the FSEvents stream. Safe to call more
    /// than once, and safe to never call if the watcher is simply deinited.
    public func stop() {
        runOnQueue {
            lifecycle?.stop()
            lifecycle = nil
        }
    }

    func deliverRawEventForTesting(
        paths: [String],
        flags: [FSEventStreamEventFlags]
    ) {
        runOnQueue {
            guard let lifecycle,
                  !paths.isEmpty,
                  paths.count == flags.count else {
                return
            }
            let pathsArray = paths as CFArray
            flags.withUnsafeBufferPointer { flagBuffer in
                guard let eventFlags = flagBuffer.baseAddress else {
                    return
                }
                lifecycle.handleRawEvent(
                    count: paths.count,
                    paths: Unmanaged.passUnretained(pathsArray).toOpaque(),
                    eventFlags: eventFlags
                )
            }
        }
    }

    private final class StreamLifecycle: @unchecked Sendable {
        let queue: DispatchQueue
        let coalescingWindow: TimeInterval
        let onBatch: @Sendable (WorkspaceChangeBatch) -> Void
        let fsEvents: FSEventsOperations
        let timerOps: TimerOperations

        var stream: FSEventStreamRef?
        var pendingPaths: [String: WorkspaceChangeFlags] = [:]
        var coalescingTimer: TimerToken?
        var isStopped = false

        init(
            queue: DispatchQueue,
            coalescingWindow: TimeInterval,
            onBatch: @escaping @Sendable (WorkspaceChangeBatch) -> Void,
            fsEvents: FSEventsOperations,
            timerOps: TimerOperations
        ) {
            self.queue = queue
            self.coalescingWindow = coalescingWindow
            self.onBatch = onBatch
            self.fsEvents = fsEvents
            self.timerOps = timerOps
        }

        func handleRawEvent(
            count: Int,
            paths: UnsafeMutableRawPointer,
            eventFlags: UnsafePointer<FSEventStreamEventFlags>
        ) {
            guard !isStopped else { return }
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
            coalescingTimer = timerOps.schedule(coalescingWindow, queue) { [weak self] in
                self?.flush()
            }
        }

        private func flush() {
            coalescingTimer = nil
            guard !isStopped, !pendingPaths.isEmpty else { return }
            let batch = WorkspaceChangeBatch(
                paths: pendingPaths.map { WorkspaceChangePath(path: $0.key, flags: $0.value) }
                    .sorted { $0.path < $1.path }
            )
            pendingPaths.removeAll()
            onBatch(batch)
        }

        func stop() {
            guard !isStopped else { return }
            isStopped = true
            coalescingTimer?.cancel()
            coalescingTimer = nil
            pendingPaths.removeAll()
            if let stream {
                fsEvents.stop(stream)
                fsEvents.invalidate(stream)
                fsEvents.release(stream)
                self.stream = nil
            }
        }
    }
}
