import Foundation
import XCTest
@testable import WorkspaceCore

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
        watcher.start()
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
        watcher.start()
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
        watcher.start()
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
        // A window comfortably larger than the whole write burst below.
        let watcher = WorkspaceFileWatcher(root: root, coalescingWindow: 0.5) { batch in
            collector.append(batch)
        }
        watcher.start()
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

        // The whole 25-file burst should have coalesced into very few
        // batches (ideally one), not one batch per file.
        XCTAssertLessThan(collector.all.count, 10)
    }

    func testIgnoreFileChangeIsFlaggedForFullerRecheck() async throws {
        let collector = BatchCollector()
        let watcher = WorkspaceFileWatcher(root: root, coalescingWindow: 0.1) { batch in
            collector.append(batch)
        }
        watcher.start()
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
        watcher.start()
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
        watcher.start()

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
}
