import Foundation
import SourceModel
import XCTest
@testable import SourceIO

private struct InMemoryReadOnlyFileSystem: ReadOnlyFileSystem {
    let result: Result<ReadOnlyFilePayload, SourceIOError>
    /// Whether this file system reports a size without reading, the way
    /// `LocalReadOnlyFileSystem` does.
    let reportsMetadata: Bool
    private let readCounter: ReadCounter

    final class ReadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            defer { lock.unlock() }
            value += 1
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    init(data: Data, modificationDate: Date? = nil, reportsMetadata: Bool = false) {
        result = .success(
            ReadOnlyFilePayload(data: data, modificationDate: modificationDate)
        )
        self.reportsMetadata = reportsMetadata
        readCounter = ReadCounter()
    }

    init(error: SourceIOError) {
        result = .failure(error)
        reportsMetadata = false
        readCounter = ReadCounter()
    }

    var readCount: Int {
        readCounter.count
    }

    func metadata(at url: URL) throws -> ReadOnlyFileMetadata? {
        guard reportsMetadata, case .success(let payload) = result else {
            return nil
        }
        return ReadOnlyFileMetadata(
            byteCount: payload.data.count,
            modificationDate: payload.modificationDate
        )
    }

    func readFile(at url: URL) throws -> ReadOnlyFilePayload {
        readCounter.increment()
        return try result.get()
    }
}

final class SourceSnapshotLoaderTests: XCTestCase {
    func testRawDataLoaderUsesFilesystemDecodingSemantics() throws {
        let loader = SourceSnapshotLoader()
        let url = URL(fileURLWithPath: "/virtual/index.swift")
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("one\r\ntwo\r\n".utf8)

        let snapshot = try loader.load(
            data: data,
            url: url,
            version: 42,
            modificationDate: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(snapshot.url, url)
        XCTAssertEqual(snapshot.version, 42)
        XCTAssertEqual(snapshot.originalData, data)
        XCTAssertEqual(snapshot.encoding, .utf8)
        XCTAssertEqual(snapshot.lineEnding, .carriageReturnLineFeed)
        XCTAssertEqual(snapshot.text, "one\r\ntwo\r\n")
        XCTAssertEqual(snapshot.utf8Data, Data("one\r\ntwo\r\n".utf8))
    }

    func testDecodesUTF16LittleEndianAndMapsOriginalBytes() throws {
        let text = "A😀B"
        var data = Data([0xFF, 0xFE])
        data.append(text.data(using: .utf16LittleEndian)!)
        let loader = SourceSnapshotLoader(
            fileSystem: InMemoryReadOnlyFileSystem(data: data)
        )

        let snapshot = try loader.load(url: URL(fileURLWithPath: "/fixture.swift"))

        XCTAssertEqual(snapshot.encoding, .utf16LittleEndian)
        XCTAssertEqual(snapshot.text, text)
        XCTAssertEqual(try snapshot.originalByteOffset(forUTF8Offset: 5), 8)
    }

    func testRejectsUnsupportedEncodingWithTypedError() {
        let loader = SourceSnapshotLoader(
            fileSystem: InMemoryReadOnlyFileSystem(data: Data([0xFF, 0xFF, 0xFF]))
        )
        let url = URL(fileURLWithPath: "/invalid.swift")

        XCTAssertThrowsError(try loader.load(url: url)) { error in
            XCTAssertEqual(error as? SourceIOError, .unsupportedEncoding(url))
        }
    }

    func testPropagatesExplicitReadFailureWithoutWriting() {
        let url = URL(fileURLWithPath: "/missing.swift")
        let loader = SourceSnapshotLoader(
            fileSystem: InMemoryReadOnlyFileSystem(error: .permissionDenied(url))
        )

        XCTAssertThrowsError(try loader.load(url: url)) { error in
            XCTAssertEqual(error as? SourceIOError, .permissionDenied(url))
        }
    }

    func testDefaultSafetyPolicyPreservesPathologicalLineReasonAndMessage() throws {
        let data = Data(String(repeating: "x", count: 100_001).utf8)
        let snapshot = try SourceSnapshotLoader(
            renderingSafetyPolicy: .codeViewportDefault
        ).load(
            data: data,
            url: URL(fileURLWithPath: "/long-line.swift")
        )

        let reason = try XCTUnwrap(snapshot.safetyModeReason)
        XCTAssertEqual(reason, .lineLength(100_001))
        XCTAssertEqual(
            SourceRenderingSafetyPolicy.codeViewportDefault.message(for: reason),
            "Safety mode: this file contains a line longer than 100001 UTF-8 bytes."
        )
    }

    func testSafetyPolicyCanBeDisabledForNonRendererLoading() throws {
        let data = Data(String(repeating: "x", count: 100_001).utf8)
        let snapshot = try SourceSnapshotLoader(
            renderingSafetyPolicy: nil
        ).load(
            data: data,
            url: URL(fileURLWithPath: "/long-line.swift")
        )

        XCTAssertNil(snapshot.safetyModeReason)
    }

    func testDefaultSafetyPolicyPreservesTenMegabyteBoundary() {
        let policy = SourceRenderingSafetyPolicy.codeViewportDefault
        let limit = 10 * 1_024 * 1_024

        XCTAssertNil(policy.reason(fileByteCount: limit, longestLineUTF8Length: 1))
        XCTAssertEqual(
            policy.reason(fileByteCount: limit + 1, longestLineUTF8Length: 1),
            .fileSize(limit + 1)
        )
    }

    func testTenMegabyteSnapshotPerformance() {
        let line = Data("let value = 42\n".utf8)
        var data = Data()
        data.reserveCapacity(10 * 1_024 * 1_024)
        while data.count + line.count <= 10 * 1_024 * 1_024 {
            data.append(line)
        }
        let loader = SourceSnapshotLoader(
            fileSystem: InMemoryReadOnlyFileSystem(data: data),
            renderingSafetyPolicy: .codeViewportDefault
        )

        measure {
            do {
                let snapshot = try loader.load(
                    url: URL(fileURLWithPath: "/ten-megabytes.swift")
                )
                XCTAssertGreaterThan(snapshot.lineCount, 1)
            } catch {
                XCTFail("Loading failed: \(error)")
            }
        }
    }

    // MARK: - Pre-read oversized-file guard

    func testOversizedFileIsRefusedBeforeAnyContentIsRead() {
        let limit = SourceRenderingSafetyPolicy.codeViewportDefault.fullFidelityByteLimit
        let data = Data(repeating: 0x61, count: limit + 1)
        let fileSystem = InMemoryReadOnlyFileSystem(data: data, reportsMetadata: true)
        let loader = SourceSnapshotLoader(
            fileSystem: fileSystem,
            renderingSafetyPolicy: .codeViewportDefault
        )
        let url = URL(fileURLWithPath: "/huge.swift")

        XCTAssertThrowsError(try loader.load(url: url)) { error in
            XCTAssertEqual(
                error as? SourceIOError,
                .fileExceedsRenderingByteLimit(url: url, byteCount: limit + 1, limit: limit)
            )
        }
        XCTAssertEqual(fileSystem.readCount, 0, "content must not be read before the host answers")
    }

    func testFileExactlyAtTheLimitIsStillLoadedWithoutAsking() throws {
        let limit = 64
        let data = Data(repeating: 0x61, count: limit)
        let fileSystem = InMemoryReadOnlyFileSystem(data: data, reportsMetadata: true)
        let loader = SourceSnapshotLoader(
            fileSystem: fileSystem,
            renderingSafetyPolicy: SourceRenderingSafetyPolicy(
                fullFidelityByteLimit: limit,
                maximumLineUTF8Length: 100_000
            )
        )

        let snapshot = try loader.load(url: URL(fileURLWithPath: "/at-limit.swift"))

        XCTAssertEqual(snapshot.originalData.count, limit)
        XCTAssertNil(snapshot.safetyModeReason)
        XCTAssertEqual(fileSystem.readCount, 1)
    }

    func testExplicitRetryLoadsTheOversizedFileAndKeepsSafetyMode() throws {
        let limit = 64
        let data = Data(repeating: 0x61, count: limit + 8)
        let fileSystem = InMemoryReadOnlyFileSystem(data: data, reportsMetadata: true)
        let loader = SourceSnapshotLoader(
            fileSystem: fileSystem,
            renderingSafetyPolicy: SourceRenderingSafetyPolicy(
                fullFidelityByteLimit: limit,
                maximumLineUTF8Length: 100_000
            )
        )
        let url = URL(fileURLWithPath: "/huge.swift")

        XCTAssertThrowsError(try loader.load(url: url))

        let snapshot = try loader.loadIgnoringByteLimit(url: url, version: 7)

        XCTAssertEqual(snapshot.version, 7)
        XCTAssertEqual(snapshot.originalData.count, limit + 8)
        XCTAssertEqual(snapshot.safetyModeReason, .fileSize(limit + 8))
        XCTAssertEqual(fileSystem.readCount, 1, "only the explicit retry reads content")
    }

    func testGuardIsSkippedWhenNoRenderingPolicyIsConfigured() throws {
        let data = Data(repeating: 0x61, count: 4_096)
        let fileSystem = InMemoryReadOnlyFileSystem(data: data, reportsMetadata: true)
        let loader = SourceSnapshotLoader(fileSystem: fileSystem, renderingSafetyPolicy: nil)

        let snapshot = try loader.load(url: URL(fileURLWithPath: "/no-policy.swift"))

        XCTAssertEqual(snapshot.originalData.count, 4_096)
        XCTAssertNil(snapshot.safetyModeReason)
    }

    /// A file system with no cheap `stat` keeps the pre-guard-era
    /// behavior: read, then report safety mode.
    func testFileSystemWithoutMetadataFallsBackToPostReadSafetyMode() throws {
        let limit = 64
        let data = Data(repeating: 0x61, count: limit + 8)
        let loader = SourceSnapshotLoader(
            fileSystem: InMemoryReadOnlyFileSystem(data: data),
            renderingSafetyPolicy: SourceRenderingSafetyPolicy(
                fullFidelityByteLimit: limit,
                maximumLineUTF8Length: 100_000
            )
        )

        let snapshot = try loader.load(url: URL(fileURLWithPath: "/unknown-size.swift"))

        XCTAssertEqual(snapshot.safetyModeReason, .fileSize(limit + 8))
    }

    // MARK: - Local file system

    func testLocalFileSystemReportsMetadataWithoutReadingAndReadsUnmappedBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sample.swift")
        try Data(String(repeating: "let x = 1\n", count: 1_024).utf8).write(to: url)

        let fileSystem = LocalReadOnlyFileSystem()
        let metadata = try XCTUnwrap(fileSystem.metadata(at: url))
        XCTAssertEqual(metadata.byteCount, 10 * 1_024)

        let payload = try fileSystem.readFile(at: url)
        XCTAssertEqual(payload.data.count, 10 * 1_024)

        // The retained bytes are an eager copy, not a window onto a file
        // Kod does not control: deleting the file must not change or
        // invalidate an already-loaded snapshot.
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(payload.data.count, 10 * 1_024)
        XCTAssertTrue(payload.data.allSatisfy { $0 != 0 })
    }

    func testLocalFileSystemRefusesOversizedFileBeforeReading() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("big.swift")
        try Data(repeating: 0x61, count: 4_096).write(to: url)

        let loader = SourceSnapshotLoader(
            renderingSafetyPolicy: SourceRenderingSafetyPolicy(
                fullFidelityByteLimit: 1_024,
                maximumLineUTF8Length: 100_000
            )
        )

        XCTAssertThrowsError(try loader.load(url: url)) { error in
            XCTAssertEqual(
                error as? SourceIOError,
                .fileExceedsRenderingByteLimit(url: url, byteCount: 4_096, limit: 1_024)
            )
        }

        let snapshot = try loader.loadIgnoringByteLimit(url: url)
        XCTAssertEqual(snapshot.originalData.count, 4_096)
        XCTAssertEqual(snapshot.safetyModeReason, .fileSize(4_096))
    }

    // MARK: - Cancellable eager reads

    func testChunkedReadReturnsEveryByteIncludingAPartialFinalChunk() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("chunked.swift")
        let contents = Data(String(repeating: "let value = 1\n", count: 97).utf8)
        try contents.write(to: url)

        let payload = try LocalReadOnlyFileSystem(chunkByteCount: 5)
            .readFile(at: url)

        XCTAssertFalse(contents.count.isMultiple(of: 5))
        XCTAssertEqual(payload.data, contents)
    }

    func testEagerReadKeepsBytesTakenAtReadTimeWhenTheFileIsRewritten() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("rewritten.swift")
        let original = Data(String(repeating: "a", count: 8_192).utf8)
        try original.write(to: url)

        let payload = try LocalReadOnlyFileSystem(chunkByteCount: 512)
            .readFile(at: url)
        try Data(String(repeating: "b", count: 16).utf8).write(to: url)

        XCTAssertEqual(payload.data, original)
    }

    func testAlreadyCancelledTaskReadsNoBytesAtAll() async throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("abandoned.swift")
        try Data(repeating: 0x61, count: 64 * 1_024).write(to: url)
        let barrier = ChunkBarrier(blockingOnFirstChunk: false)
        let fileSystem = LocalReadOnlyFileSystem(
            chunkByteCount: 4_096,
            didReadChunk: { _ in barrier.noteChunk() }
        )
        let start = StartGate()

        let read = Task<Data, any Error>.detached {
            await start.wait()
            return try fileSystem.readFile(at: url).data
        }
        read.cancel()
        await start.open()

        do {
            _ = try await read.value
            XCTFail("a cancelled read must not produce bytes")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(barrier.observedChunks, 0)
    }

    /// The whole point of chunking: a read abandoned mid-file stops
    /// pulling bytes instead of running to completion.
    func testCancellingMidReadStopsAtTheNextChunkBoundary() async throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("interrupted.swift")
        try Data(repeating: 0x61, count: 64 * 1_024).write(to: url)
        let barrier = ChunkBarrier()
        let fileSystem = LocalReadOnlyFileSystem(
            chunkByteCount: 4_096,
            didReadChunk: { _ in barrier.noteChunk() }
        )

        let read = Task<Data, any Error>.detached {
            try fileSystem.readFile(at: url).data
        }
        await barrier.waitUntilReading()
        read.cancel()
        barrier.releaseReader()

        do {
            _ = try await read.value
            XCTFail("a cancelled read must not produce bytes")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(
            barrier.observedChunks,
            1,
            "the read must stop at the first chunk boundary after cancellation"
        )
    }

    // MARK: - Off-actor loads keep the caller's cancellation

    func testDetachedLoadCancellationReachesTheUnderlyingRead() async throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("detached.swift")
        try Data(repeating: 0x61, count: 64 * 1_024).write(to: url)
        let barrier = ChunkBarrier()
        let loader = SourceSnapshotLoader(
            fileSystem: LocalReadOnlyFileSystem(
                chunkByteCount: 4_096,
                didReadChunk: { _ in barrier.noteChunk() }
            )
        )

        let load = Task { try await loader.loadDetached(url: url) }
        await barrier.waitUntilReading()
        load.cancel()
        barrier.releaseReader()

        do {
            _ = try await load.value
            XCTFail("a cancelled load must not produce a snapshot")
        } catch is CancellationError {
            // Expected: cancelling the caller cancels the detached read.
        }
        XCTAssertEqual(barrier.observedChunks, 1)
    }

    func testDetachedUnrestrictedRetryCancellationReachesTheUnderlyingRead() async throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("detached-huge.swift")
        try Data(repeating: 0x61, count: 64 * 1_024).write(to: url)
        let barrier = ChunkBarrier()
        let loader = SourceSnapshotLoader(
            fileSystem: LocalReadOnlyFileSystem(
                chunkByteCount: 4_096,
                didReadChunk: { _ in barrier.noteChunk() }
            ),
            renderingSafetyPolicy: SourceRenderingSafetyPolicy(
                fullFidelityByteLimit: 1_024,
                maximumLineUTF8Length: 100_000
            )
        )

        let load = Task { try await loader.loadIgnoringByteLimitDetached(url: url) }
        await barrier.waitUntilReading()
        load.cancel()
        barrier.releaseReader()

        do {
            _ = try await load.value
            XCTFail("a cancelled retry must not produce a snapshot")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(barrier.observedChunks, 1)
    }

    func testDetachedLoadKeepsThePreReadOversizedGuard() async throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("guarded.swift")
        try Data(repeating: 0x61, count: 4_096).write(to: url)
        let barrier = ChunkBarrier(blockingOnFirstChunk: false)
        let loader = SourceSnapshotLoader(
            fileSystem: LocalReadOnlyFileSystem(
                chunkByteCount: 512,
                didReadChunk: { _ in barrier.noteChunk() }
            ),
            renderingSafetyPolicy: SourceRenderingSafetyPolicy(
                fullFidelityByteLimit: 1_024,
                maximumLineUTF8Length: 100_000
            )
        )

        do {
            _ = try await loader.loadDetached(url: url)
            XCTFail("an oversized file must be refused before reading")
        } catch let error as SourceIOError {
            XCTAssertEqual(
                error,
                .fileExceedsRenderingByteLimit(
                    url: url,
                    byteCount: 4_096,
                    limit: 1_024
                )
            )
        }
        XCTAssertEqual(barrier.observedChunks, 0)

        let snapshot = try await loader.loadIgnoringByteLimitDetached(
            url: url,
            version: 4
        )
        XCTAssertEqual(snapshot.version, 4)
        XCTAssertEqual(snapshot.originalData.count, 4_096)
        XCTAssertEqual(snapshot.safetyModeReason, .fileSize(4_096))
        XCTAssertGreaterThan(barrier.observedChunks, 0)
    }

    // MARK: - Oversized approval is pinned to a file, not to a path

    private func makeOversizedFixture(
        byteCount: Int = 4_096,
        limit: Int = 1_024,
        named name: String = "approved.log"
    ) throws -> (url: URL, loader: SourceSnapshotLoader) {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x61, count: byteCount).write(to: url)
        return (
            url,
            SourceSnapshotLoader(
                renderingSafetyPolicy: SourceRenderingSafetyPolicy(
                    fullFidelityByteLimit: limit,
                    maximumLineUTF8Length: 100_000
                )
            )
        )
    }

    func testApprovalLoadsTheExactFileAndSizeItWasGivenFor() throws {
        let fixture = try makeOversizedFixture()
        let metadata = try XCTUnwrap(fixture.loader.metadata(at: fixture.url))
        XCTAssertNotNil(metadata.identity)

        let snapshot = try fixture.loader.load(
            url: fixture.url,
            approval: OversizedReadApproval(
                identity: metadata.identity,
                byteCount: metadata.byteCount
            )
        )

        XCTAssertEqual(snapshot.originalData.count, 4_096)
        XCTAssertEqual(snapshot.safetyModeReason, .fileSize(4_096))
    }

    /// Consent is for *a file*, not for a path. Deleting the approved file
    /// and writing a new one of exactly the same size at the same path
    /// must not inherit the answer the user gave about the old one.
    func testApprovalDoesNotCoverAReplacementFileOfTheSameSize() throws {
        let fixture = try makeOversizedFixture(named: "replaced.log")
        let metadata = try XCTUnwrap(fixture.loader.metadata(at: fixture.url))
        let approval = OversizedReadApproval(
            identity: metadata.identity,
            byteCount: metadata.byteCount
        )

        try FileManager.default.removeItem(at: fixture.url)
        try Data(repeating: 0x62, count: 4_096).write(to: fixture.url)

        XCTAssertThrowsError(
            try fixture.loader.load(url: fixture.url, approval: approval)
        ) { error in
            XCTAssertEqual(
                error as? SourceIOError,
                .fileExceedsRenderingByteLimit(
                    url: fixture.url,
                    byteCount: 4_096,
                    limit: 1_024
                )
            )
        }
    }

    /// Approving 4 KB is not approving 4 MB. A log file that keeps growing
    /// is the ordinary case, and it must stop being covered the moment it
    /// passes the size the user actually saw.
    func testApprovalDoesNotCoverTheSameFileGrownPastTheApprovedSize() throws {
        let fixture = try makeOversizedFixture(named: "growing.log")
        let metadata = try XCTUnwrap(fixture.loader.metadata(at: fixture.url))
        let approval = OversizedReadApproval(
            identity: metadata.identity,
            byteCount: metadata.byteCount
        )

        let handle = try FileHandle(forWritingTo: fixture.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0x61, count: 1))
        try handle.close()
        // Same inode, same path, one byte more than was approved.
        let grown = try XCTUnwrap(fixture.loader.metadata(at: fixture.url))
        XCTAssertEqual(grown.identity, metadata.identity)

        XCTAssertThrowsError(
            try fixture.loader.load(url: fixture.url, approval: approval)
        ) { error in
            XCTAssertEqual(
                error as? SourceIOError,
                .fileExceedsRenderingByteLimit(
                    url: fixture.url,
                    byteCount: 4_097,
                    limit: 1_024
                )
            )
        }
    }

    /// A file that shrank back under the approved ceiling is still the
    /// file that was approved.
    func testApprovalStillCoversTheSameFileAtASmallerSize() throws {
        let fixture = try makeOversizedFixture(named: "shrinking.log")
        let metadata = try XCTUnwrap(fixture.loader.metadata(at: fixture.url))
        let approval = OversizedReadApproval(
            identity: metadata.identity,
            byteCount: metadata.byteCount
        )

        let handle = try FileHandle(forWritingTo: fixture.url)
        try handle.truncate(atOffset: 2_048)
        try handle.close()

        let snapshot = try fixture.loader.load(
            url: fixture.url,
            approval: approval
        )
        XCTAssertEqual(snapshot.originalData.count, 2_048)
    }

    func testApprovalIsCheckedAgainstTheDescriptorThatIsAboutToBeRead() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("descriptor.log")
        try Data(repeating: 0x61, count: 4_096).write(to: url)
        let fileSystem = LocalReadOnlyFileSystem()
        let identity = try XCTUnwrap(fileSystem.metadata(at: url)?.identity)

        // The validator runs on metadata read back from the open file,
        // not from a second independent `stat` of the path.
        let observed = ObservedMetadata()
        _ = try fileSystem.readFile(at: url) { metadata in
            observed.record(metadata)
        }

        XCTAssertEqual(observed.value?.identity, identity)
        XCTAssertEqual(observed.value?.byteCount, 4_096)
    }

    func testValidationRefusalStopsTheReadBeforeAnyBytesAreTaken() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("refused.log")
        try Data(repeating: 0x61, count: 4_096).write(to: url)
        let barrier = ChunkBarrier(blockingOnFirstChunk: false)
        let fileSystem = LocalReadOnlyFileSystem(
            chunkByteCount: 512,
            didReadChunk: { _ in barrier.noteChunk() }
        )

        XCTAssertThrowsError(
            try fileSystem.readFile(at: url) { _ in
                throw SourceIOError.notRegularFile(url)
            }
        )
        XCTAssertEqual(barrier.observedChunks, 0)
    }

    func testDetachedLoadHonoursAnApprovalAndRefusesAStaleOne() async throws {
        let fixture = try makeOversizedFixture(named: "detached-approved.log")
        let read = try await fixture.loader.metadataDetached(at: fixture.url)
        let metadata = try XCTUnwrap(read)
        let approval = OversizedReadApproval(
            identity: metadata.identity,
            byteCount: metadata.byteCount
        )

        let snapshot = try await fixture.loader.loadDetached(
            url: fixture.url,
            version: 3,
            approval: approval
        )
        XCTAssertEqual(snapshot.version, 3)

        try FileManager.default.removeItem(at: fixture.url)
        try Data(repeating: 0x62, count: 4_096).write(to: fixture.url)

        do {
            _ = try await fixture.loader.loadDetached(
                url: fixture.url,
                approval: approval
            )
            XCTFail("a replaced file must not inherit the old approval")
        } catch let error as SourceIOError {
            XCTAssertEqual(
                error,
                .fileExceedsRenderingByteLimit(
                    url: fixture.url,
                    byteCount: 4_096,
                    limit: 1_024
                )
            )
        }
    }

    // MARK: - Bounded, cancellable raw reads

    /// Images and property lists are routinely larger than the *text*
    /// limit and must stay previewable; the two limits are separate
    /// numbers on purpose.
    func testRawReadLimitIsAboveTheFullFidelityTextLimit() {
        XCTAssertGreaterThan(
            RawFileReadPolicy.previewDefault.byteLimit,
            SourceRenderingSafetyPolicy.codeViewportDefault.fullFidelityByteLimit
        )
    }

    func testRawLoaderReadsAFileAboveTheTextLimitButUnderItsOwn() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("preview.png")
        let contents = Data(repeating: 0x89, count: 2_048)
        try contents.write(to: url)

        let data = try RawFileLoader(
            policy: RawFileReadPolicy(byteLimit: 4_096)
        ).load(url: url)

        XCTAssertEqual(data, contents)
    }

    func testRawLoaderRefusesAnOversizedFileBeforeReadingAnyBytes() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("enormous.png")
        try Data(repeating: 0x89, count: 4_096).write(to: url)
        let barrier = ChunkBarrier(blockingOnFirstChunk: false)
        let loader = RawFileLoader(
            fileSystem: LocalReadOnlyFileSystem(
                chunkByteCount: 512,
                didReadChunk: { _ in barrier.noteChunk() }
            ),
            policy: RawFileReadPolicy(byteLimit: 1_024)
        )

        XCTAssertThrowsError(try loader.load(url: url)) { error in
            XCTAssertEqual(
                error as? SourceIOError,
                .fileExceedsRawReadByteLimit(
                    url: url,
                    byteCount: 4_096,
                    limit: 1_024
                )
            )
        }
        XCTAssertEqual(
            barrier.observedChunks,
            0,
            "an over-limit preview must be refused before any bytes are taken"
        )
    }

    /// The reason previews stopped using a bare `Task.detached`: closing
    /// the tab or the window has to reach the file handle.
    func testRawLoaderCancellationReachesTheUnderlyingRead() async throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("interrupted.png")
        try Data(repeating: 0x89, count: 64 * 1_024).write(to: url)
        let barrier = ChunkBarrier()
        let loader = RawFileLoader(
            fileSystem: LocalReadOnlyFileSystem(
                chunkByteCount: 4_096,
                didReadChunk: { _ in barrier.noteChunk() }
            )
        )

        let read = Task { try await loader.loadDetached(url: url) }
        await barrier.waitUntilReading()
        read.cancel()
        barrier.releaseReader()

        do {
            _ = try await read.value
            XCTFail("a cancelled raw read must not produce bytes")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(barrier.observedChunks, 1)
    }

    func testAlreadyCancelledRawLoadNeverOpensTheFile() async throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("abandoned.png")
        try Data(repeating: 0x89, count: 64 * 1_024).write(to: url)
        let barrier = ChunkBarrier(blockingOnFirstChunk: false)
        let loader = RawFileLoader(
            fileSystem: LocalReadOnlyFileSystem(
                chunkByteCount: 4_096,
                didReadChunk: { _ in barrier.noteChunk() }
            )
        )

        let read = Task { try await loader.loadDetached(url: url) }
        read.cancel()

        do {
            _ = try await read.value
            XCTFail("a cancelled raw read must not produce bytes")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(barrier.observedChunks, 0)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}

/// Makes the chunk boundary of `LocalReadOnlyFileSystem`'s eager read/// observable and stoppable, so cancellation tests assert on an exact
/// chunk count instead of racing a large file.
private final class ChunkBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let blocksOnFirstChunk: Bool
    private var chunkCount = 0
    private var isReading = false
    private var readingWaiter: CheckedContinuation<Void, Never>?

    init(blockingOnFirstChunk: Bool = true) {
        blocksOnFirstChunk = blockingOnFirstChunk
    }

    var observedChunks: Int {
        lock.lock()
        defer { lock.unlock() }
        return chunkCount
    }

    /// Called on the reading thread once per chunk; the first call parks
    /// the reader until `releaseReader()`.
    func noteChunk() {
        lock.lock()
        chunkCount += 1
        let isFirstChunk = chunkCount == 1
        isReading = true
        let waiter = readingWaiter
        readingWaiter = nil
        lock.unlock()

        guard isFirstChunk else {
            return
        }
        waiter?.resume()
        if blocksOnFirstChunk {
            gate.wait()
        }
    }

    func waitUntilReading() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isReading {
                lock.unlock()
                continuation.resume()
                return
            }
            readingWaiter = continuation
            lock.unlock()
        }
    }

    func releaseReader() {
        gate.signal()
    }
}

/// Holds a detached read at its first suspension point so a test can
/// cancel the task before any byte is read.
private actor StartGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

/// Captures what the read-time validator was handed, from whichever
/// thread the read happens to run on.
private final class ObservedMetadata: @unchecked Sendable {
    private let lock = NSLock()
    private var metadata: ReadOnlyFileMetadata?

    func record(_ metadata: ReadOnlyFileMetadata) {
        lock.lock()
        defer { lock.unlock() }
        self.metadata = metadata
    }

    var value: ReadOnlyFileMetadata? {
        lock.lock()
        defer { lock.unlock() }
        return metadata
    }
}
