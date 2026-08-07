import XCTest
@testable import DiagnosticsCore

final class BoundedEventLogTests: XCTestCase {
    func testRecordsEventsInOrder() async {
        let log = BoundedEventLog(capacity: 10)
        await log.record(subsystem: .git, level: .info, message: "first")
        await log.record(subsystem: .git, level: .error, message: "second")

        let events = await log.events
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].message, "first")
        XCTAssertEqual(events[1].message, "second")
    }

    func testDropsOldestEventsOnceCapacityExceededAndTracksDroppedCount() async {
        let log = BoundedEventLog(capacity: 3)
        for index in 0..<5 {
            await log.record(subsystem: .search, level: .info, message: "event-\(index)")
        }

        let events = await log.events
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.map(\.message), ["event-2", "event-3", "event-4"])
        let dropped = await log.droppedCount
        XCTAssertEqual(dropped, 2)
    }

    func testRedactedSnapshotNeverContainsRawSourceText() async {
        let log = BoundedEventLog()
        await log.record(
            DiagnosticEvent(
                subsystem: .preview,
                level: .warning,
                message: "parse failure",
                context: [
                    DiagnosticContextField(name: "content", category: .sourceText, value: "const password = 'hunter2'")
                ]
            )
        )

        let redacted = await log.redactedSnapshot()
        XCTAssertEqual(redacted.count, 1)
        XCTAssertFalse(redacted[0].context[0].value.contains("hunter2"))
    }

    func testEventsAtLeastLevelFiltersByMinimumLevel() async {
        let log = BoundedEventLog()
        await log.record(subsystem: .app, level: .debug, message: "debug")
        await log.record(subsystem: .app, level: .warning, message: "warning")
        await log.record(subsystem: .app, level: .error, message: "error")

        let atLeastWarning = await log.events(atLeast: .warning)
        XCTAssertEqual(atLeastWarning.map(\.message), ["warning", "error"])
    }

    func testClearResetsEventsAndDroppedCount() async {
        let log = BoundedEventLog(capacity: 1)
        await log.record(subsystem: .app, level: .info, message: "a")
        await log.record(subsystem: .app, level: .info, message: "b")
        let droppedBeforeClear = await log.droppedCount
        XCTAssertEqual(droppedBeforeClear, 1)

        await log.clear()

        let eventsAfterClear = await log.events
        let droppedAfterClear = await log.droppedCount
        XCTAssertEqual(eventsAfterClear.count, 0)
        XCTAssertEqual(droppedAfterClear, 0)
    }
}
