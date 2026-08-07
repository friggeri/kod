import Foundation

public enum BoundedDownloadError: Error, Equatable, Sendable {
    case insecureScheme(URL)
    case maxBytesExceeded(limit: Int)
    case httpStatus(Int)
    case cancelled
    case transportFailure(String)
}

/// One progress observation during a download: bytes received so far
/// and, when the server reported it, the expected total.
public struct ManagedDownloadProgress: Sendable, Equatable {
    public let bytesReceived: Int
    public let expectedTotalBytes: Int?
}

/// A cooperative cancellation flag one `BoundedDownloader.download` call
/// checks between chunks. Cancelling stops the underlying
/// `URLSessionDataTask` and deletes any partially-written bytes at the
/// destination — a cancelled download never leaves a partial file
/// behind for a later step to mistake for a complete one.
public final class ManagedDownloadCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Downloads one URL to a destination file, enforcing a hard byte cap
/// (SPEC 6.5 "bounded download") that aborts the instant more bytes
/// than declared have arrived — before they are written to disk —
/// rather than downloading everything and checking the size afterward.
/// Reports incremental progress and supports cooperative cancellation
/// that cleans up the partial file.
///
/// This type itself accepts `http`/`https` (rejecting anything else,
/// e.g. `file://`) so it can be exercised against `LocalHTTPTestServer`
/// in tests without TLS. The SPEC 6.5 "TLS only" policy for a real
/// managed-install download is enforced one layer up, in
/// `ManagedInstallController`, which refuses to call this at all for a
/// catalog artifact whose URL scheme isn't exactly `https` — so
/// production installs are still HTTPS-only end to end.
public enum BoundedDownloader {
    public static func download(
        url: URL,
        maxBytes: Int,
        destinationURL: URL,
        session: URLSession = .shared,
        cancellationToken: ManagedDownloadCancellationToken = ManagedDownloadCancellationToken(),
        onProgress: (@Sendable (ManagedDownloadProgress) -> Void)? = nil
    ) async throws {
        guard url.scheme == "https" || url.scheme == "http" else {
            throw BoundedDownloadError.insecureScheme(url)
        }

        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        guard let fileHandle = FileHandle(forWritingAtPath: destinationURL.path) else {
            throw BoundedDownloadError.transportFailure("could not open destination file for writing")
        }

        let delegate = BoundedDownloadDelegate(
            maxBytes: maxBytes,
            fileHandle: fileHandle,
            cancellationToken: cancellationToken,
            onProgress: onProgress
        )
        let taskSession = URLSession(configuration: session.configuration, delegate: delegate, delegateQueue: nil)
        defer { taskSession.finishTasksAndInvalidate() }

        let task = taskSession.dataTask(with: url)
        delegate.task = task

        do {
            try await withTaskCancellationHandler(
                operation: {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        delegate.completion = { result in
                            continuation.resume(with: result)
                        }
                        task.resume()
                    }
                },
                onCancel: {
                    cancellationToken.cancel()
                    task.cancel()
                }
            )
        } catch {
            try? fileHandle.close()
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
        try? fileHandle.close()
    }
}

private final class BoundedDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let maxBytes: Int
    let fileHandle: FileHandle
    let cancellationToken: ManagedDownloadCancellationToken
    let onProgress: (@Sendable (ManagedDownloadProgress) -> Void)?
    var completion: ((Result<Void, Error>) -> Void)?
    weak var task: URLSessionDataTask?

    private var bytesReceived = 0
    private var expectedTotalBytes: Int?
    private let lock = NSLock()
    private var finished = false

    init(
        maxBytes: Int,
        fileHandle: FileHandle,
        cancellationToken: ManagedDownloadCancellationToken,
        onProgress: (@Sendable (ManagedDownloadProgress) -> Void)?
    ) {
        self.maxBytes = maxBytes
        self.fileHandle = fileHandle
        self.cancellationToken = cancellationToken
        self.onProgress = onProgress
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        completion?(result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            finish(.failure(BoundedDownloadError.httpStatus(httpResponse.statusCode)))
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > 0 {
            expectedTotalBytes = Int(response.expectedContentLength)
            if let expectedTotalBytes, expectedTotalBytes > maxBytes {
                finish(.failure(BoundedDownloadError.maxBytesExceeded(limit: maxBytes)))
                completionHandler(.cancel)
                return
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if cancellationToken.isCancelled {
            dataTask.cancel()
            finish(.failure(BoundedDownloadError.cancelled))
            return
        }
        bytesReceived += data.count
        if bytesReceived > maxBytes {
            dataTask.cancel()
            finish(.failure(BoundedDownloadError.maxBytesExceeded(limit: maxBytes)))
            return
        }
        fileHandle.write(data)
        onProgress?(ManagedDownloadProgress(bytesReceived: bytesReceived, expectedTotalBytes: expectedTotalBytes))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                if cancellationToken.isCancelled {
                    finish(.failure(BoundedDownloadError.cancelled))
                } else {
                    // Already finished with `.maxBytesExceeded`/`.httpStatus`
                    // above, which itself cancelled the task — `finish`
                    // is idempotent, so this is a no-op in that case.
                    finish(.failure(BoundedDownloadError.cancelled))
                }
                return
            }
            finish(.failure(BoundedDownloadError.transportFailure(error.localizedDescription)))
            return
        }
        finish(.success(()))
    }
}
