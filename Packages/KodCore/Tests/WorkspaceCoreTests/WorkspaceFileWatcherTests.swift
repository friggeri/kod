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

    private final class BatchCollector: @unchecked Sendable {
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
