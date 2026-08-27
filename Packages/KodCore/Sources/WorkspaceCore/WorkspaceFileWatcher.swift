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
    /// `kFSEventStreamEventFlagMustScanSubDirs`: FSEvents could not
    /// describe the individual changes under this path, so everything
    /// below it must be re-enumerated. The path is a subtree root, not a
    /// changed file.
    public static let mustScanSubDirectories = WorkspaceChangeFlags(rawValue: 1 << 5)
    /// `kFSEventStreamEventFlagUserDropped`: events were dropped because
    /// this process could not keep up. Always accompanied by
    /// `mustScanSubDirectories`.
    public static let userDropped = WorkspaceChangeFlags(rawValue: 1 << 6)
    /// `kFSEventStreamEventFlagKernelDropped`: events were dropped inside
    /// the kernel. Always accompanied by `mustScanSubDirectories`.
    public static let kernelDropped = WorkspaceChangeFlags(rawValue: 1 << 7)
    /// `kFSEventStreamEventFlagRootChanged`: the watched root itself (or
    /// a directory on the path to it) was created, deleted, renamed, or
    /// moved. Nothing below it can be trusted, and the root has to be
    /// re-resolved before any path under it means anything again.
    public static let rootChanged = WorkspaceChangeFlags(rawValue: 1 << 8)

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
        if fsEventFlags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
            flags.insert(.mustScanSubDirectories)
        }
        if fsEventFlags & UInt32(kFSEventStreamEventFlagUserDropped) != 0 {
            flags.insert(.userDropped)
        }
        if fsEventFlags & UInt32(kFSEventStreamEventFlagKernelDropped) != 0 {
            flags.insert(.kernelDropped)
        }
        if fsEventFlags & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
            flags.insert(.rootChanged)
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

/// Why a batch cannot be applied as a list of individual changes.
public enum WorkspaceRescanReason: Hashable, Sendable {
    /// FSEvents itself said it could not describe every change under a
    /// path (`kFSEventStreamEventFlagMustScanSubDirs`).
    case mustScanSubDirectories
    /// Events were dropped because this process fell behind
    /// (`kFSEventStreamEventFlagUserDropped`).
    case userDropped
    /// Events were dropped inside the kernel
    /// (`kFSEventStreamEventFlagKernelDropped`).
    case kernelDropped
    /// Kod's own bound on how many distinct paths one coalesced batch may
    /// hold was reached, so the batch stopped recording new paths rather
    /// than growing without limit.
    case pendingPathLimitExceeded(limit: Int)
}

/// What a batch actually tells its consumer to do. Distinguishing these
/// is the whole point: a dropped-events notice looks exactly like an
/// ordinary batch if only `paths` is read, so treating one as the other
/// silently leaves the workspace showing stale state.
public enum WorkspaceChangeScope: Equatable, Sendable {
    /// `paths` enumerates every change; apply them directly.
    case incremental
    /// Some changes are missing from `paths`. Whatever `paths` does list
    /// is a hint (each entry carrying `.mustScanSubDirectories` is a
    /// subtree root), and the consumer must re-enumerate to catch up.
    case rescanRequired(reasons: Set<WorkspaceRescanReason>)
    /// The watched root itself moved, was replaced, or disappeared.
    /// Nothing under the old root is meaningful; the workspace has to be
    /// re-resolved rather than re-scanned in place.
    case rootInvalidated
}

/// One coalesced burst of filesystem changes under a watched root.
public struct WorkspaceChangeBatch: Sendable {
    public let paths: [WorkspaceChangePath]
    /// How this batch must be interpreted. Defaults to `.incremental` so
    /// an explicitly-constructed batch of known paths behaves exactly as
    /// it always has.
    public let scope: WorkspaceChangeScope

    public init(
        paths: [WorkspaceChangePath],
        scope: WorkspaceChangeScope = .incremental
    ) {
        self.paths = paths
        self.scope = scope
    }

    /// `true` when `paths` is incomplete and the consumer must
    /// re-enumerate the affected subtrees (or the whole root) to catch up.
    public var requiresRescan: Bool {
        switch scope {
        case .incremental:
            return false
        case .rescanRequired, .rootInvalidated:
            return true
        }
    }

    /// `true` when the watched root itself is no longer valid.
    public var isRootInvalidated: Bool {
        scope == .rootInvalidated
    }

    public var rescanReasons: Set<WorkspaceRescanReason> {
        guard case .rescanRequired(let reasons) = scope else {
            return []
        }
        return reasons
    }

    /// The subtree roots FSEvents explicitly asked to be re-scanned. Empty
    /// for an incremental batch, and possibly empty for a rescan batch
    /// whose only reason is Kod's own pending-path bound — in which case
    /// the whole watched root is the affected subtree.
    public var subtreesRequiringScan: [String] {
        guard requiresRescan else {
            return []
        }
        return paths
            .filter { $0.flags.contains(.mustScanSubDirectories) }
            .map(\.path)
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

/// Compares filesystem paths for *identity* rather than for spelling.
///
/// FSEvents reports the firmlinked form of paths under `/var`, `/tmp`,
/// and `/etc` (`/private/var/…`), while the `URL` a workspace root was
/// opened from almost never carries that prefix. `standardizingPath`
/// removes `/private` only when the resulting path still exists — which
/// is exactly not the case for a root that was just deleted or renamed,
/// the one event this comparison has to catch. Normalizing the prefix
/// unconditionally (for the three firmlinked system directories only)
/// makes the comparison independent of whether the path still resolves.
enum WorkspacePathIdentity {
    private static let firmlinkedRoots = ["/var/", "/tmp/", "/etc/"]

    static func normalized(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        guard standardized.hasPrefix("/private/") else {
            return standardized
        }
        let withoutPrivate = String(standardized.dropFirst("/private".count))
        guard firmlinkedRoots.contains(where: { withoutPrivate.hasPrefix($0) }) else {
            return standardized
        }
        return withoutPrivate
    }
}

/// Injectable monotonic clock, so the maximum-delivery-deadline logic is
/// testable without sleeping.
struct ClockOperations: @unchecked Sendable {
    var now: @Sendable () -> TimeInterval
}

extension ClockOperations {
    static let live = ClockOperations {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

/// Watches one workspace root for filesystem changes via FSEvents,
/// coalescing bursts of individual events (e.g. many files touched by a
/// single `git checkout` or build) into a single batch delivered after a
/// short quiet window, per SPEC 5.6 ("Repeated write bursts are
/// coalesced").
///
/// Coalescing is bounded in both directions. A burst that never goes
/// quiet (a long build, a big clone) would otherwise reset the quiet
/// window forever and deliver nothing at all, so every batch is also
/// delivered no later than `maximumCoalescingDelay` after its first
/// event. And a burst that touches an unbounded number of distinct paths
/// would otherwise grow the pending map without limit, so at
/// `maximumPendingPaths` the batch stops recording new paths and is
/// marked `.rescanRequired` instead — degrading to "re-enumerate" rather
/// than to "silently forget" or "allocate without bound" (SPEC 12.3).
///
/// FSEvents itself requires a `CFRunLoop` or dispatch queue to deliver
/// callbacks; this wraps that C API behind a `final class` confined to one
/// private serial dispatch queue (`@unchecked Sendable` is safe here
/// because every mutable stored property is only ever touched while
/// executing on that queue, including from the FSEvents callback itself).
public final class WorkspaceFileWatcher: @unchecked Sendable {
    private let root: URL
    private let coalescingWindow: TimeInterval
    private let maximumCoalescingDelay: TimeInterval
    private let maximumPendingPaths: Int
    private let onBatch: @Sendable (WorkspaceChangeBatch) -> Void
    private let queue = DispatchQueue(label: "com.kod.WorkspaceFileWatcher")
    private let queueKey = DispatchSpecificKey<Void>()

    var fsEvents: FSEventsOperations = .live
    var timerOps: TimerOperations = .live
    var clockOps: ClockOperations = .live

    private var lifecycle: StreamLifecycle?

    public init(
        root: URL,
        coalescingWindow: TimeInterval = 0.3,
        maximumCoalescingDelay: TimeInterval = 2,
        maximumPendingPaths: Int = 8_192,
        onBatch: @escaping @Sendable (WorkspaceChangeBatch) -> Void
    ) {
        self.root = root
        self.coalescingWindow = coalescingWindow
        self.maximumCoalescingDelay = max(coalescingWindow, maximumCoalescingDelay)
        self.maximumPendingPaths = max(1, maximumPendingPaths)
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
                rootPath: WorkspacePathIdentity.normalized(root.path),
                coalescingWindow: coalescingWindow,
                maximumCoalescingDelay: maximumCoalescingDelay,
                maximumPendingPaths: maximumPendingPaths,
                onBatch: onBatch,
                fsEvents: fsEvents,
                timerOps: timerOps,
                clockOps: clockOps
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
                    // Required for `kFSEventStreamEventFlagRootChanged`:
                    // without it, a workspace root that is renamed or
                    // deleted out from under Kod produces silence rather
                    // than a root-invalidated batch.
                    | kFSEventStreamCreateFlagWatchRoot
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
        let rootPath: String
        let coalescingWindow: TimeInterval
        let maximumCoalescingDelay: TimeInterval
        let maximumPendingPaths: Int
        let onBatch: @Sendable (WorkspaceChangeBatch) -> Void
        let fsEvents: FSEventsOperations
        let timerOps: TimerOperations
        let clockOps: ClockOperations

        var stream: FSEventStreamRef?
        var pendingPaths: [String: WorkspaceChangeFlags] = [:]
        var pendingRescanReasons: Set<WorkspaceRescanReason> = []
        var pendingRootInvalidation = false
        /// The instant by which the current burst must be delivered no
        /// matter how many further events arrive. `nil` when no burst is
        /// in flight.
        var burstDeadline: TimeInterval?
        var coalescingTimer: TimerToken?
        var isStopped = false

        init(
            queue: DispatchQueue,
            rootPath: String,
            coalescingWindow: TimeInterval,
            maximumCoalescingDelay: TimeInterval,
            maximumPendingPaths: Int,
            onBatch: @escaping @Sendable (WorkspaceChangeBatch) -> Void,
            fsEvents: FSEventsOperations,
            timerOps: TimerOperations,
            clockOps: ClockOperations
        ) {
            self.queue = queue
            self.rootPath = rootPath
            self.coalescingWindow = coalescingWindow
            self.maximumCoalescingDelay = maximumCoalescingDelay
            self.maximumPendingPaths = maximumPendingPaths
            self.onBatch = onBatch
            self.fsEvents = fsEvents
            self.timerOps = timerOps
            self.clockOps = clockOps
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
                record(path: path, flags: flags)
            }

            scheduleFlush()
        }

        private func record(path: String, flags: WorkspaceChangeFlags) {
            if flags.contains(.rootChanged) || isRootItself(path, flags: flags) {
                pendingRootInvalidation = true
            }
            if flags.contains(.mustScanSubDirectories) {
                pendingRescanReasons.insert(.mustScanSubDirectories)
            }
            if flags.contains(.userDropped) {
                pendingRescanReasons.insert(.userDropped)
            }
            if flags.contains(.kernelDropped) {
                pendingRescanReasons.insert(.kernelDropped)
            }

            if pendingPaths[path] != nil || pendingPaths.count < maximumPendingPaths {
                pendingPaths[path, default: []].formUnion(flags)
            } else {
                // Refuse to grow further. The batch can no longer claim to
                // enumerate every change, so it says so instead.
                pendingRescanReasons.insert(
                    .pendingPathLimitExceeded(limit: maximumPendingPaths)
                )
            }
        }

        /// The watched root disappearing or being renamed is a root
        /// invalidation even when it arrives as an ordinary item event
        /// (which is what happens when the deletion is observed from
        /// inside the watched tree rather than as a `RootChanged` notice).
        private func isRootItself(_ path: String, flags: WorkspaceChangeFlags) -> Bool {
            guard flags.contains(.removed) || flags.contains(.renamed) else {
                return false
            }
            return WorkspacePathIdentity.normalized(path) == rootPath
        }

        private func scheduleFlush() {
            let now = clockOps.now()
            let deadline: TimeInterval
            if let burstDeadline {
                deadline = burstDeadline
            } else {
                deadline = now + maximumCoalescingDelay
                burstDeadline = deadline
            }
            // Never longer than the quiet window, and never past the
            // burst's hard deadline: a sustained stream of events keeps
            // shortening this interval instead of pushing delivery back
            // indefinitely.
            let interval = max(0, min(coalescingWindow, deadline - now))
            coalescingTimer?.cancel()
            coalescingTimer = timerOps.schedule(interval, queue) { [weak self] in
                self?.flush()
            }
        }

        private func flush() {
            coalescingTimer = nil
            burstDeadline = nil
            guard !isStopped else { return }

            let scope: WorkspaceChangeScope
            if pendingRootInvalidation {
                scope = .rootInvalidated
            } else if !pendingRescanReasons.isEmpty {
                scope = .rescanRequired(reasons: pendingRescanReasons)
            } else {
                scope = .incremental
            }

            guard !pendingPaths.isEmpty || scope != .incremental else { return }

            let batch = WorkspaceChangeBatch(
                paths: pendingPaths.map { WorkspaceChangePath(path: $0.key, flags: $0.value) }
                    .sorted { $0.path < $1.path },
                scope: scope
            )
            pendingPaths.removeAll()
            pendingRescanReasons.removeAll()
            pendingRootInvalidation = false
            onBatch(batch)
        }

        func stop() {
            guard !isStopped else { return }
            isStopped = true
            coalescingTimer?.cancel()
            coalescingTimer = nil
            burstDeadline = nil
            pendingPaths.removeAll()
            pendingRescanReasons.removeAll()
            pendingRootInvalidation = false
            if let stream {
                fsEvents.stop(stream)
                fsEvents.invalidate(stream)
                fsEvents.release(stream)
                self.stream = nil
            }
        }
    }
}
