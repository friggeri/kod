import XCTest
@testable import ManagedLanguageServers

final class BoundedDownloaderTests: XCTestCase {
    private var destinationDirectory: URL!

    override func setUpWithError() throws {
        destinationDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("BoundedDownloaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: destinationDirectory)
    }

    func testDownloadsFullBodyAndReportsProgress() async throws {
        let body = Data(repeating: 0x41, count: 200_000)
        let server = try LocalHTTPTestServer(responseBody: body)
        server.start()
        defer { server.stop() }

        let destination = destinationDirectory.appendingPathComponent("out.bin")
        let progressBox = LockedBoxValue<ManagedDownloadProgress?>(nil)
        try await BoundedDownloader.download(
            url: server.baseURL,
            maxBytes: 300_000,
            destinationURL: destination,
            onProgress: { progress in
                progressBox.set(progress)
            }
        )

        let downloaded = try Data(contentsOf: destination)
        XCTAssertEqual(downloaded, body)
        XCTAssertEqual(progressBox.get()?.bytesReceived, body.count)
    }

    func testExceedsDeclaredMaxBytesAborts() async throws {
        let body = Data(repeating: 0x42, count: 500_000)
        let server = try LocalHTTPTestServer(responseBody: body)
        server.start()
        defer { server.stop() }

        let destination = destinationDirectory.appendingPathComponent("out.bin")
        do {
            try await BoundedDownloader.download(url: server.baseURL, maxBytes: 1_000, destinationURL: destination)
            XCTFail("expected maxBytesExceeded")
        } catch let error as BoundedDownloadError {
            guard case .maxBytesExceeded = error else {
                XCTFail("expected maxBytesExceeded, got \(error)")
                return
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "partial file must be cleaned up")
    }

    func testCancellationCleansUpPartialFile() async throws {
        let body = Data(repeating: 0x43, count: 400_000)
        let server = try LocalHTTPTestServer(responseBody: body, chunkDelayNanoseconds: 20_000_000)
        server.start()
        defer { server.stop() }

        let destination = destinationDirectory.appendingPathComponent("out.bin")
        let token = ManagedDownloadCancellationToken()

        let downloadTask = Task {
            try await BoundedDownloader.download(url: server.baseURL, maxBytes: 1_000_000, destinationURL: destination, cancellationToken: token)
        }
        try await Task.sleep(nanoseconds: 60_000_000)
        token.cancel()

        do {
            try await downloadTask.value
            XCTFail("expected cancellation error")
        } catch let error as BoundedDownloadError {
            guard case .cancelled = error else {
                XCTFail("expected cancelled, got \(error)")
                return
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "cancelled download must not leave a partial file")
    }

    func testInsecureSchemeRejected() async throws {
        let destination = destinationDirectory.appendingPathComponent("out.bin")
        do {
            try await BoundedDownloader.download(url: URL(fileURLWithPath: "/etc/hosts"), maxBytes: 100, destinationURL: destination)
            XCTFail("expected insecureScheme")
        } catch let error as BoundedDownloadError {
            guard case .insecureScheme = error else {
                XCTFail("expected insecureScheme, got \(error)")
                return
            }
        }
    }
}
