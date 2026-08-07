import Foundation

/// A minimal, loopback-only HTTP/1.1 server used solely by
/// `ManagedLanguageServersTests` to exercise `BoundedDownloader` against
/// a *real* socket and TCP/HTTP framing — never an external, mutable
/// URL, and never reachable outside `127.0.0.1` (SPEC 6.5's "Download
/// over TLS only" is deliberately not modeled here: this server speaks
/// plain HTTP, which is exactly why `BoundedDownloader` accepts
/// `http`/`https` while `ManagedInstallController` is the layer that
/// actually enforces HTTPS-only for a real catalog artifact — see that
/// type's doc comment).
///
/// Built on raw POSIX sockets rather than `URLProtocol` stubbing so the
/// download path under test is the real thing: real chunked delivery,
/// a real `Content-Length` header, and a genuine ability to simulate a
/// slow/oversized/truncated response.
final class LocalHTTPTestServer: @unchecked Sendable {
    enum ServerError: Error {
        case socketCreationFailed
        case bindFailed
        case listenFailed
    }

    private let listenSocket: Int32
    let port: UInt16
    private var acceptThread: Thread?
    private var shouldStop = false
    private let stopLock = NSLock()

    /// `responses` maps a request path (e.g. `"/v1.0.0.tar.gz"`) to the
    /// bytes to serve for it — lets one server instance stand in for a
    /// whole catalog's worth of per-version download URLs. A path not
    /// present in `responses` gets a 404. `chunkDelayNanoseconds`, if
    /// non-zero, sleeps between writing fixed-size chunks of whichever
    /// body is being served, so a cancellation test can reliably cancel
    /// mid-download rather than racing a near-instantaneous localhost
    /// transfer.
    private let responses: [String: Data]
    private let chunkDelayNanoseconds: UInt64
    private let declaredContentLengthOverride: Int?

    convenience init(responseBody: Data, chunkDelayNanoseconds: UInt64 = 0, declaredContentLength: Int? = nil) throws {
        try self.init(responses: ["/": responseBody], chunkDelayNanoseconds: chunkDelayNanoseconds, declaredContentLength: declaredContentLength)
    }

    init(responses: [String: Data], chunkDelayNanoseconds: UInt64 = 0, declaredContentLength: Int? = nil) throws {
        self.responses = responses
        self.chunkDelayNanoseconds = chunkDelayNanoseconds
        self.declaredContentLengthOverride = declaredContentLength

        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw ServerError.socketCreationFailed
        }
        var reuse: Int32 = 1
        setsockopt(fileDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0 // let the OS pick an ephemeral port

        let bindResult = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fileDescriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fileDescriptor)
            throw ServerError.bindFailed
        }

        var assignedAddress = sockaddr_in()
        var assignedLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &assignedAddress) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fileDescriptor, sockaddrPointer, &assignedLength)
            }
        }
        guard nameResult == 0 else {
            close(fileDescriptor)
            throw ServerError.bindFailed
        }

        guard listen(fileDescriptor, 8) == 0 else {
            close(fileDescriptor)
            throw ServerError.listenFailed
        }

        self.listenSocket = fileDescriptor
        self.port = assignedAddress.sin_port.bigEndian
    }

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    func url(forPath path: String) -> URL {
        baseURL.appendingPathComponent(path)
    }

    func start() {
        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.start()
        acceptThread = thread
    }

    func stop() {
        stopLock.lock()
        shouldStop = true
        stopLock.unlock()
        close(listenSocket)
    }

    private func acceptLoop() {
        while true {
            stopLock.lock()
            let stopping = shouldStop
            stopLock.unlock()
            if stopping {
                return
            }

            let clientSocket = accept(listenSocket, nil, nil)
            if clientSocket < 0 {
                return
            }
            // A cancelled/aborted download closes the client side of
            // the socket while this server is still mid-`send()`;
            // without this, the resulting SIGPIPE would (by POSIX
            // default disposition) terminate the whole test process
            // rather than just failing this one `send()` call with
            // `EPIPE`.
            var noSigPipe: Int32 = 1
            setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            handle(clientSocket: clientSocket)
        }
    }

    private func handle(clientSocket: Int32) {
        defer { close(clientSocket) }

        var requestBuffer = [UInt8](repeating: 0, count: 4096)
        let received = requestBuffer.withUnsafeMutableBytes { buffer in
            recv(clientSocket, buffer.baseAddress, buffer.count, 0)
        }
        let requestLine = received > 0
            ? String(decoding: requestBuffer.prefix(received), as: UTF8.self).split(separator: "\r\n").first.map(String.init)
            : nil
        // A minimal GET line parse: "GET /path HTTP/1.1" -> "/path".
        let requestedPath = requestLine?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"

        guard let body = responses[requestedPath] ?? responses["/"] else {
            let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            _ = notFound.withCString { pointer in
                send(clientSocket, pointer, strlen(pointer), 0)
            }
            return
        }

        let header = "HTTP/1.1 200 OK\r\nContent-Length: \(declaredContentLengthOverride ?? body.count)\r\nConnection: close\r\n\r\n"
        _ = header.withCString { pointer in
            send(clientSocket, pointer, strlen(pointer), 0)
        }

        let chunkSize = 4096
        var offset = 0
        while offset < body.count {
            let end = min(offset + chunkSize, body.count)
            let chunk = body.subdata(in: offset..<end)
            let sent = chunk.withUnsafeBytes { buffer -> Int in
                send(clientSocket, buffer.baseAddress, buffer.count, 0)
            }
            if sent <= 0 {
                break
            }
            offset = end
            if chunkDelayNanoseconds > 0 {
                Thread.sleep(forTimeInterval: Double(chunkDelayNanoseconds) / 1_000_000_000)
            }
        }
    }
}
