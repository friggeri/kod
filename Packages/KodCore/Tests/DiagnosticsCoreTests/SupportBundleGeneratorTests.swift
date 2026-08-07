import XCTest
@testable import DiagnosticsCore

final class SupportBundleGeneratorTests: XCTestCase {
    func testGeneratedBundleContainsRedactedEventsAndAccurateCounts() async throws {
        let log = BoundedEventLog(capacity: 5)
        await log.record(
            DiagnosticEvent(
                subsystem: .git,
                level: .error,
                message: "Failed to diff /Users/adrien/repo/file.swift",
                context: [
                    DiagnosticContextField(name: "src", category: .sourceText, value: "let apiKey = \"sk-live-123\"")
                ]
            )
        )
        for index in 0..<10 {
            await log.record(subsystem: .search, level: .info, message: "search event \(index)")
        }

        let contents = try await SupportBundleGenerator.generate(
            from: log,
            quarantine: [],
            appVersion: "1.0.0",
            osVersion: "macOS 14.0",
            architecture: "arm64"
        )

        XCTAssertEqual(contents.manifest.eventCount, 5, "bundle must reflect the bounded log's actual retained count")
        XCTAssertGreaterThan(contents.manifest.droppedEventCount, 0)
        XCTAssertFalse(contents.redactedEvents.contains { $0.message.contains("adrien") })
        XCTAssertFalse(
            contents.redactedEvents.contains {
                $0.context.contains { $0.value.contains("sk-live-123") }
            }
        )
    }

    func testGeneratedBundleIncludesQuarantineSummary() async throws {
        let log = BoundedEventLog()
        let records = [
            QuarantinedRecord(key: "font-settings", reason: "typeMismatch", quarantinedAt: Date(), byteCount: 12)
        ]

        let contents = try await SupportBundleGenerator.generate(
            from: log,
            quarantine: records,
            appVersion: "1.0.0",
            osVersion: "macOS 14.0",
            architecture: "arm64"
        )

        XCTAssertEqual(contents.manifest.quarantinedRecordCount, 1)
        XCTAssertEqual(contents.quarantinedRecords, records)
    }

    func testWriteProducesValidJSONFileWithNoRawSourceContents() async throws {
        let log = BoundedEventLog()
        await log.record(
            DiagnosticEvent(
                subsystem: .preview,
                level: .warning,
                message: "parse issue",
                context: [
                    DiagnosticContextField(name: "src", category: .sourceText, value: "TOP SECRET SOURCE LINE")
                ]
            )
        )
        let contents = try await SupportBundleGenerator.generate(
            from: log,
            quarantine: [],
            appVersion: "1.0.0",
            osVersion: "macOS 14.0",
            architecture: "arm64"
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kod-support-bundle-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("bundle.json")

        try SupportBundleGenerator.write(contents, to: fileURL)

        let data = try Data(contentsOf: fileURL)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("TOP SECRET SOURCE LINE"))
        // Must be valid, re-decodable JSON, not just "some bytes".
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        _ = try decoder.decode(SupportBundleContents.self, from: data)
    }

    func testAssertFullyRedactedThrowsIfSourceTextFieldWasNotActuallyRedacted() {
        let unredactedEvent = DiagnosticEvent(
            subsystem: .preview,
            level: .error,
            message: "oops",
            context: [
                DiagnosticContextField(name: "src", category: .sourceText, value: "this was never redacted")
            ]
        )

        XCTAssertThrowsError(try SupportBundleGenerator.assertFullyRedacted([unredactedEvent])) { error in
            XCTAssertEqual(error as? SupportBundleError, .unredactedSourceTextDetected)
        }
    }

    func testAssertFullyRedactedAcceptsProperlyRedactedEvents() throws {
        let event = RedactionEngine.redact(
            DiagnosticEvent(
                subsystem: .preview,
                level: .error,
                message: "oops",
                context: [
                    DiagnosticContextField(name: "src", category: .sourceText, value: "secret contents")
                ]
            )
        )

        XCTAssertNoThrow(try SupportBundleGenerator.assertFullyRedacted([event]))
    }
}
