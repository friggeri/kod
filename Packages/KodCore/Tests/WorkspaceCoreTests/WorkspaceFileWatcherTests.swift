import Foundation
import XCTest
@testable import WorkspaceCore

extension FSEventsOperations {
    static let failingCreate = FSEventsOperations(
        create: { _, _, _, _, _, _, _ in nil },
        start: { _ in true },
        setDispatchQueue: { _, _ in },
        stop: { _ in },
        invalidate: { _ in },
        release: { _ in }
    )

    static var failingStart: FSEventsOperations {
        FSEventsOperations(
            create: { alloc, cb, ctx, paths, since, latency, flags in
                FSEventsOperations.live.create(alloc, cb, ctx, paths, since, latency, flags)
            },
            start: { _ in false },
            setDispatchQueue: { stream, queue in
                FSEventsOperations.live.setDispatchQueue(stream, queue)
            },
            stop: { stream in
                FSEventsOperations.live.stop(stream)
            },
            invalidate: { stream in
                FSEventsOperations.live.invalidate(stream)
            },
            release: { stream in
                FSEventsOperations.live.release(stream)
            }
        )
    }
}

final class WorkspaceFileWatcherTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    fileprivate final class BatchCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var batches: [WorkspaceChangeBatch] = []

        func append(_ batch: WorkspaceChangeBatch) {
            lock.lock()
            defer { lock.unlock() }
            batches.append(batch)
        }

        var all: [WorkspaceChangeBatch] {
            lock.lock()
            defer { lock.unlock() }
            return batches
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ predicate: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw XCTSkip("condition not observed within \(timeout)s (FSEvents timing is host-dependent)")
    }

    func testDetectsFileCreation() async throws {
        let collector = BatchCollector()
        let watcher = WorkspaceFileWatcher(root: root, coalescingWindow: 0.1) { batch in
            collector.append(batch)
        }
        try watcher.start()
        defer { watcher.stop() }

        try await Task.sleep(for: .milliseconds(200))
        try Data("hello".utf8).write(to: root.appendingPathComponent("new.txt"))

        try await waitUntil {
            collector.all.contains { batch in
                batch.paths.contains {
                    $0.path.hasSuffix("new.txt") && $0.flags.contains(.created)
                }
            }
        }
    }

    func testDetectsFileRemoval() async throws {
        let fileURL = root.appendingPathComponent("doomed.txt")
        try Data("bye".utf8).write(to: fileURL)

        let collector = BatchCollector()
        let watcher = WorkspaceFileWatcher(root: root, coalescingWindow: 0.1) { batch in
            collector.append(batch)
        }
        try watcher.start()
        defer { watcher.stop() }

        try await Task.sleep(for: .milliseconds(200))
        try FileManager.default.removeItem(at: fileURL)

        try await waitUntil {
            collector.all.contains { batch in
                batch.paths.contains {
                    $0.path.hasSuffix("doomed.txt") && $0.flags.contains(.removed)
                }
            }
        }
    }

    func testDetectsFileModification() async throws {
        let fileURL = root.appendingPathComponent("existing.txt")
        try Data("v1".utf8).write(to: fileURL)

        let collector = BatchCollector()
        let watcher = WorkspaceFileWatcher(root: root, coalescingWindow: 0.1) { batch in
            collector.append(batch)
        }
        try watcher.start()
        defer { watcher.stop() }

        try await Task.sleep(for: .milliseconds(200))
        try Data("v2".utf8).write(to: fileURL)

        try await waitUntil {
            collector.all.contains { batch in
                batch.paths.contains { $0.path.hasSuffix("existing.txt") }
            }
        }
    }

    func testBurstOfWritesCoalescesIntoFewBatches() async throws {
        let collector = BatchCollector()
        let watcher = WorkspaceFileWatcher(root: root, coalescingWindow: 0.5) { batch in
            collector.append(batch)
        }
        try watcher.start()
        defer { watcher.stop() }

        try await Task.sleep(for: .milliseconds(200))
        for index in 0..<25 {
            try Data("v\(index)".utf8).write(to: root.appendingPathComponent("burst\(index).txt"))
        }

        try await waitUntil(timeout: 3) {
            collector.all.contains { batch in
                batch.paths.filter { $0.path.contains("burst") }.count >= 25
            }
        }

        XCTAssertLessThan(collector.all.count, 10)
    }

    func testIgnoreFileChangeIsFlaggedForFullerRecheck() async throws {
        let collector = BatchCollector()
        let watcher = WorkspaceFileWatcher(root: root, coalescingWindow: 0.1) { batch in
            collector.append(batch)
        }
        try watcher.start()
        defer { watcher.stop() }

        try await Task.sleep(for: .milliseconds(200))
        try Data("ignored/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))

        try await waitUntil {
            collector.all.contains { $0.mayHaveChangedIgnoreRules }
        }
    }

    func testOrdinaryBatchDoesNotFlagIgnoreRuleChange() async throws {
        let collector = BatchCollector()
        let watcher = WorkspaceFileWatcher(root: root, coalescingWindow: 0.1) { batch in
            collector.append(batch)
        }
        try watcher.start()
        defer { watcher.stop() }

        try await Task.sleep(for: .milliseconds(200))
        try Data("hello".utf8).write(to: root.appendingPathComponent("plain.txt"))

        try await waitUntil {
            collector.all.contains { batch in
                batch.paths.contains { $0.path.hasSuffix("plain.txt") }
            }
        }
        XCTAssertFalse(collector.all.contains { $0.mayHaveChangedIgnoreRules })
    }

    func testStopSuppressesFurtherBatches() async throws {
        let collector = BatchCollector()
        let watcher = WorkspaceFileWatcher(root: root, coalescingWindow: 0.1) { batch in
            collector.append(batch)
        }
        try watcher.start()

        try await Task.sleep(for: .milliseconds(200))
        try Data("first".utf8).write(to: root.appendingPathComponent("before-stop.txt"))
        try await waitUntil {
            collector.all.contains { batch in
                batch.paths.contains { $0.path.hasSuffix("before-stop.txt") }
            }
        }

        watcher.stop()
        let countAtStop = collector.all.count
        try Data("second".utf8).write(to: root.appendingPathComponent("after-stop.txt"))
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(collector.all.count, countAtStop, "no batches should arrive after stop()")
    }

    func testCreateFailureThrows() {
        let watcher = WorkspaceFileWatcher(root: root, coalescingWindow: 0.1) { _ in }
        watcher.fsEvents = .failingCreate

        XCTAssertThrowsError(try watcher.start()) { error in
            XCTAssertEqual(error as? WorkspaceFileWatcherError, .streamCreationFailed)
        }
    }

    func testStartFailureThrows() {
        let watcher = WorkspaceFileWatcher(root: root, coalescingWindow: 0.1) { _ in }
        watcher.fsEvents = .failingStart

        XCTAssertThrowsError(try watcher.start()) { error in
            XCTAssertEqual(error as? WorkspaceFileWatcherError, .streamStartFailed)
        }
    }

    func testRepeatedStartAndStop() throws {
        let watcher = WorkspaceFileWatcher(root: root, coalescingWindow: 0.1) { _ in }

        try watcher.start()
        // Idempotent start
        try watcher.start()

        watcher.stop()
        // Idempotent stop
        watcher.stop()

        // Can be restarted
        try watcher.start()
        watcher.stop()
    }

    func testStartIsRetryableAfterFailure() throws {
        let watcher = WorkspaceFileWatcher(root: root, coalescingWindow: 0.1) { _ in }
        watcher.fsEvents = .failingStart

        XCTAssertThrowsError(try watcher.start())

        // Switch to live and retry
        watcher.fsEvents = .live
        try watcher.start()
        watcher.stop()
    }

    func testStopRacesWithQueuedDelivery() {
        let collector = BatchCollector()
        let watcher = WorkspaceFileWatcher(root: root, coalescingWindow: 2.0) { batch in
            collector.append(batch)
        }

        let capturedFlush = Locked<(@Sendable () -> Void)?>(nil)
        let timerCancelled = Locked(false)
        let streamReleaseCount = Locked(0)

        watcher.timerOps = TimerOperations { _, _, handler in
            capturedFlush.value = handler
            return TimerToken { timerCancelled.value = true }
        }
        var operations = FSEventsOperations.live
        operations.release = { stream in
            streamReleaseCount.value += 1
            FSEventsOperations.live.release(stream)
        }
        watcher.fsEvents = operations

        XCTAssertNoThrow(try watcher.start())

        watcher.deliverRawEventForTesting(
            paths: [root.appendingPathComponent("race.txt").path],
            flags: [UInt32(kFSEventStreamEventFlagItemCreated)]
        )

        XCTAssertNotNil(capturedFlush.value, "Flush should be scheduled after event delivery")
        XCTAssertFalse(timerCancelled.value, "Timer should not be cancelled yet")

        // Stop now, which should cancel the timer and prevent flush
        watcher.stop()

        XCTAssertTrue(timerCancelled.value, "Stop should cancel the scheduled timer")
        XCTAssertEqual(streamReleaseCount.value, 1)

        // Manually invoke the captured flush closure
        capturedFlush.value?()

        XCTAssertTrue(collector.all.isEmpty, "Batch should not be delivered if watcher is stopped before coalescing timer fires.")
    }

    // MARK: - FSEvents control flags

    func testMapsEveryControlFlagKodActsOn() {
        func mapped(_ raw: Int) -> WorkspaceChangeFlags {
            WorkspaceChangeFlags(fsEventFlags: FSEventStreamEventFlags(raw))
        }

        XCTAssertTrue(mapped(kFSEventStreamEventFlagMustScanSubDirs).contains(.mustScanSubDirectories))
        XCTAssertTrue(mapped(kFSEventStreamEventFlagUserDropped).contains(.userDropped))
        XCTAssertTrue(mapped(kFSEventStreamEventFlagKernelDropped).contains(.kernelDropped))
        XCTAssertTrue(mapped(kFSEventStreamEventFlagRootChanged).contains(.rootChanged))

        // Item-level flags stay exactly as they were.
        XCTAssertTrue(mapped(kFSEventStreamEventFlagItemCreated).contains(.created))
        XCTAssertTrue(mapped(kFSEventStreamEventFlagItemRemoved).contains(.removed))
        XCTAssertTrue(mapped(kFSEventStreamEventFlagItemRenamed).contains(.renamed))
        XCTAssertTrue(mapped(kFSEventStreamEventFlagItemModified).contains(.modified))
        XCTAssertTrue(mapped(kFSEventStreamEventFlagItemIsDir).contains(.isDirectory))

        // A dropped-events notice never masquerades as an ordinary change.
        let dropped = mapped(
            kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagMustScanSubDirs
        )
        XCTAssertFalse(dropped.contains(.created))
        XCTAssertFalse(dropped.contains(.modified))
    }

    func testKernelDroppedEventsProduceARescanRequiredBatch() {
        let harness = ControlledWatcher(root: root, coalescingWindow: 5)
        XCTAssertNoThrow(try harness.start())
        defer { harness.watcher.stop() }

        harness.watcher.deliverRawEventForTesting(
            paths: [root.path],
            flags: [
                FSEventStreamEventFlags(
                    kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagMustScanSubDirs
                )
            ]
        )
        harness.fireTimer()

        let batch = try? XCTUnwrap(harness.collector.all.first)
        XCTAssertEqual(
            batch?.scope,
            .rescanRequired(reasons: [.kernelDropped, .mustScanSubDirectories])
        )
        XCTAssertEqual(batch?.requiresRescan, true)
        XCTAssertEqual(batch?.isRootInvalidated, false)
        XCTAssertEqual(batch?.subtreesRequiringScan, [root.path])
    }

    func testUserDroppedEventsProduceARescanRequiredBatch() {
        let harness = ControlledWatcher(root: root, coalescingWindow: 5)
        XCTAssertNoThrow(try harness.start())
        defer { harness.watcher.stop() }

        harness.watcher.deliverRawEventForTesting(
            paths: [root.appendingPathComponent("sub").path],
            flags: [
                FSEventStreamEventFlags(
                    kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagMustScanSubDirs
                )
            ]
        )
        harness.fireTimer()

        XCTAssertEqual(harness.collector.all.first?.rescanReasons, [.userDropped, .mustScanSubDirectories])
    }

    func testOrdinaryChangesStayIncremental() {
        let harness = ControlledWatcher(root: root, coalescingWindow: 5)
        XCTAssertNoThrow(try harness.start())
        defer { harness.watcher.stop() }

        harness.watcher.deliverRawEventForTesting(
            paths: [root.appendingPathComponent("a.txt").path],
            flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)]
        )
        harness.fireTimer()

        let batch = harness.collector.all.first
        XCTAssertEqual(batch?.scope, .incremental)
        XCTAssertEqual(batch?.requiresRescan, false)
        XCTAssertEqual(batch?.subtreesRequiringScan, [])
    }

    // MARK: - Root invalidation

    func testRootChangedFlagInvalidatesTheWholeRoot() {
        let harness = ControlledWatcher(root: root, coalescingWindow: 5)
        XCTAssertNoThrow(try harness.start())
        defer { harness.watcher.stop() }

        harness.watcher.deliverRawEventForTesting(
            paths: [root.path],
            flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)]
        )
        harness.fireTimer()

        let batch = harness.collector.all.first
        XCTAssertEqual(batch?.scope, .rootInvalidated)
        XCTAssertEqual(batch?.isRootInvalidated, true)
        XCTAssertEqual(batch?.requiresRescan, true)
    }

    func testRemovingTheWatchedRootItselfInvalidatesTheRoot() {
        let harness = ControlledWatcher(root: root, coalescingWindow: 5)
        XCTAssertNoThrow(try harness.start())
        defer { harness.watcher.stop() }

        harness.watcher.deliverRawEventForTesting(
            paths: [root.path],
            flags: [
                FSEventStreamEventFlags(
                    kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsDir
                )
            ]
        )
        harness.fireTimer()

        XCTAssertEqual(harness.collector.all.first?.isRootInvalidated, true)
    }

    func testRootInvalidationOutranksARescanNoticeInTheSameBurst() {        let harness = ControlledWatcher(root: root, coalescingWindow: 5)
        XCTAssertNoThrow(try harness.start())
        defer { harness.watcher.stop() }

        harness.watcher.deliverRawEventForTesting(
            paths: [root.appendingPathComponent("sub").path, root.path],
            flags: [
                FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs),
                FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
            ]
        )
        harness.fireTimer()

        XCTAssertEqual(harness.collector.all.first?.scope, .rootInvalidated)
    }

    /// FSEvents reports `/private/var/…` for a root whose `URL` spells
    /// itself `/var/…`, and the standard path APIs only reconcile the two
    /// while the path still exists — which a just-deleted root does not.
    func testDeletedRootMatchesEvenWhenFSEventsReportsThePrivatePrefix() {
        let privateRoot = URL(
            fileURLWithPath: "/var/folders/kod-test-root-\(UUID().uuidString)",
            isDirectory: true
        )
        let harness = ControlledWatcher(root: privateRoot, coalescingWindow: 5)
        XCTAssertNoThrow(try harness.start())
        defer { harness.watcher.stop() }

        harness.watcher.deliverRawEventForTesting(
            paths: ["/private" + privateRoot.path],
            flags: [
                FSEventStreamEventFlags(
                    kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsDir
                )
            ]
        )
        harness.fireTimer()

        XCTAssertEqual(harness.collector.all.first?.isRootInvalidated, true)
    }

    func testAnUnrelatedPrivatePathIsNotMistakenForTheRoot() {
        let harness = ControlledWatcher(root: root, coalescingWindow: 5)
        XCTAssertNoThrow(try harness.start())
        defer { harness.watcher.stop() }

        harness.watcher.deliverRawEventForTesting(
            paths: [root.appendingPathComponent("child").path],
            flags: [
                FSEventStreamEventFlags(
                    kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsDir
                )
            ]
        )
        harness.fireTimer()

        XCTAssertEqual(harness.collector.all.first?.isRootInvalidated, false)
        XCTAssertEqual(harness.collector.all.first?.scope, .incremental)
    }

    // MARK: - Bounded pending paths
    func testPendingPathsAreBoundedAndDegradeToARescanBatch() {
        let limit = 8
        let harness = ControlledWatcher(
            root: root,
            coalescingWindow: 5,
            maximumPendingPaths: limit
        )
        XCTAssertNoThrow(try harness.start())
        defer { harness.watcher.stop() }

        let paths = (0..<200).map { root.appendingPathComponent("f\($0).txt").path }
        harness.watcher.deliverRawEventForTesting(
            paths: paths,
            flags: Array(
                repeating: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated),
                count: paths.count
            )
        )
        harness.fireTimer()

        let batch = try? XCTUnwrap(harness.collector.all.first)
        XCTAssertEqual(batch?.paths.count, limit, "pending paths must stay bounded")
        XCTAssertEqual(batch?.requiresRescan, true)
        XCTAssertEqual(
            batch?.rescanReasons,
            [.pendingPathLimitExceeded(limit: limit)]
        )
    }

    func testRepeatedEventsForAlreadyPendingPathsDoNotCountTowardTheBound() {
        let limit = 4
        let harness = ControlledWatcher(
            root: root,
            coalescingWindow: 5,
            maximumPendingPaths: limit
        )
        XCTAssertNoThrow(try harness.start())
        defer { harness.watcher.stop() }

        let paths = (0..<limit).map { root.appendingPathComponent("f\($0).txt").path }
        for _ in 0..<50 {
            harness.watcher.deliverRawEventForTesting(
                paths: paths,
                flags: Array(
                    repeating: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified),
                    count: paths.count
                )
            )
        }
        harness.fireTimer()

        let batch = harness.collector.all.first
        XCTAssertEqual(batch?.paths.count, limit)
        XCTAssertEqual(batch?.scope, .incremental, "re-touching known paths is not an overflow")
    }

    // MARK: - Maximum delivery deadline

    func testSustainedEventStreamCannotStarveDelivery() {
        let harness = ControlledWatcher(
            root: root,
            coalescingWindow: 0.3,
            maximumCoalescingDelay: 1
        )
        XCTAssertNoThrow(try harness.start())
        defer { harness.watcher.stop() }

        // An event every 0.1s: the 0.3s quiet window never elapses, so
        // without a hard deadline nothing would ever be delivered.
        for step in 0..<12 {
            harness.now.value = Double(step) * 0.1
            harness.watcher.deliverRawEventForTesting(
                paths: [root.appendingPathComponent("busy.txt").path],
                flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)]
            )
        }

        let intervals = harness.scheduledIntervals.value
        XCTAssertEqual(intervals.count, 12)
        XCTAssertEqual(intervals.first ?? -1, 0.3, accuracy: 1e-9)
        XCTAssertTrue(
            intervals.allSatisfy { $0 <= 0.3 + 1e-9 },
            "a rescheduled flush may never be pushed past the quiet window"
        )
        XCTAssertEqual(
            intervals.last ?? -1,
            0,
            accuracy: 1e-9,
            "once the burst deadline is reached the flush must be scheduled immediately"
        )

        harness.fireTimer()
        XCTAssertEqual(harness.collector.all.count, 1)
        XCTAssertEqual(harness.collector.all.first?.paths.count, 1)
    }

    func testANewBurstGetsAFreshDeadlineAfterDelivery() {
        let harness = ControlledWatcher(
            root: root,
            coalescingWindow: 0.3,
            maximumCoalescingDelay: 1
        )
        XCTAssertNoThrow(try harness.start())
        defer { harness.watcher.stop() }

        harness.now.value = 0
        harness.watcher.deliverRawEventForTesting(
            paths: [root.appendingPathComponent("a.txt").path],
            flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)]
        )
        harness.now.value = 1.2
        harness.fireTimer()

        harness.watcher.deliverRawEventForTesting(
            paths: [root.appendingPathComponent("b.txt").path],
            flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)]
        )

        XCTAssertEqual(harness.collector.all.count, 1)
        XCTAssertEqual(
            harness.scheduledIntervals.value.last ?? -1,
            0.3,
            accuracy: 1e-9,
            "a burst that starts after a delivery gets the full quiet window again"
        )
    }

    /// End-to-end with the real dispatch timer: a stream of events that
    /// never goes quiet still produces a batch.
    func testSustainedEventStreamDeliversWithLiveTimers() async throws {
        let collector = BatchCollector()
        let watcher = WorkspaceFileWatcher(
            root: root,
            coalescingWindow: 0.25,
            maximumCoalescingDelay: 0.5
        ) { batch in
            collector.append(batch)
        }
        try watcher.start()
        defer { watcher.stop() }

        let deadline = Date().addingTimeInterval(3)
        while collector.all.isEmpty, Date() < deadline {
            watcher.deliverRawEventForTesting(
                paths: [root.appendingPathComponent("busy.txt").path],
                flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)]
            )
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertFalse(
            collector.all.isEmpty,
            "a sustained event stream must still deliver within the maximum coalescing delay"
        )
    }
}

/// A watcher wired to a controllable clock and timer so coalescing,
/// bounding, and deadline behavior can be asserted without sleeping.
private final class ControlledWatcher {
    let watcher: WorkspaceFileWatcher
    let collector: WorkspaceFileWatcherTests.BatchCollector
    let now = Locked<TimeInterval>(0)
    let scheduledIntervals = Locked<[TimeInterval]>([])
    private let pendingHandler = Locked<(@Sendable () -> Void)?>(nil)

    init(
        root: URL,
        coalescingWindow: TimeInterval,
        maximumCoalescingDelay: TimeInterval = 60,
        maximumPendingPaths: Int = 8_192
    ) {
        let collector = WorkspaceFileWatcherTests.BatchCollector()
        self.collector = collector
        watcher = WorkspaceFileWatcher(
            root: root,
            coalescingWindow: coalescingWindow,
            maximumCoalescingDelay: maximumCoalescingDelay,
            maximumPendingPaths: maximumPendingPaths
        ) { batch in
            collector.append(batch)
        }
        let now = self.now
        let scheduledIntervals = self.scheduledIntervals
        let pendingHandler = self.pendingHandler
        watcher.clockOps = ClockOperations { now.value }
        watcher.timerOps = TimerOperations { interval, _, handler in
            scheduledIntervals.value.append(interval)
            pendingHandler.value = handler
            return TimerToken {}
        }
    }

    func start() throws {
        try watcher.start()
    }

    /// Runs the most recently scheduled flush, as the dispatch timer would.
    func fireTimer() {
        pendingHandler.value?()
    }
}

private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T

    init(_ value: T) {
        self._value = value
    }

    var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _value = newValue
        }
    }
}
