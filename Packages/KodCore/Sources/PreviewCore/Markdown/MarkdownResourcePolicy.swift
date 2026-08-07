import Foundation

/// Kod's default posture for any resource a Markdown document references
/// but does not embed inline (a remote image, a fetched link preview,
/// etc.): SPEC 10.1 requires these blocked unless the user takes an
/// explicit, per-document action, and requires confirmation before
/// navigating to any non-local link from an untrusted workspace.
public struct MarkdownResourcePolicy: Equatable, Sendable {
    /// Whether the *workspace* this document lives in is trusted (SPEC
    /// 5's workspace-trust model, threaded in by the App layer via
    /// `WorkspaceCore`'s `WorkspaceTrustStore` — `PreviewCore` itself has
    /// no dependency on `WorkspaceCore` and never decides trust on its
    /// own).
    public var isWorkspaceTrusted: Bool
    /// Whether the user has explicitly opted in to loading remote images
    /// for *this document* (never persisted as a global default; SPEC
    /// 10.1: "require an explicit per-document action").
    public var remoteImagesEnabledForThisDocument: Bool

    public init(isWorkspaceTrusted: Bool, remoteImagesEnabledForThisDocument: Bool = false) {
        self.isWorkspaceTrusted = isWorkspaceTrusted
        self.remoteImagesEnabledForThisDocument = remoteImagesEnabledForThisDocument
    }

    /// Kod's absolute default: nothing trusted, nothing opted in. Every
    /// call site must construct a policy explicitly rather than rely on a
    /// convenience default that could silently drift toward "trusted" —
    /// this one deliberately reads as "safest", not "most convenient".
    public static let untrustedDefault = MarkdownResourcePolicy(isWorkspaceTrusted: false, remoteImagesEnabledForThisDocument: false)

    /// Whether following `destination` (a link click, not an image) needs
    /// an explicit confirmation dialog before Kod navigates anywhere.
    public func requiresConfirmationToOpen(_ destination: MarkdownDestination) -> Bool {
        guard destination.requiresConfirmationInUntrustedWorkspace else {
            return false
        }
        return !isWorkspaceTrusted
    }

    /// Whether a remote image reference should be fetched at all right
    /// now. `data:` URIs and local relative paths are never "remote" and
    /// are unaffected by this policy; only `http`/`https`/other
    /// non-local schemes are gated.
    public func shouldLoadRemoteImage(_ destination: MarkdownDestination) -> Bool {
        if destination.scheme == .local {
            return true
        }
        return remoteImagesEnabledForThisDocument
    }
}

/// Bounds for the one, fully explicit, opt-in remote-image fetch path
/// (SPEC 10.1: "make any opt-in fetch explicit and bounded"). There is no
/// implicit/automatic network path anywhere else in `PreviewCore`.
public struct BoundedRemoteFetchLimits: Equatable, Sendable {
    public var maximumByteCount: Int
    public var timeoutSeconds: TimeInterval
    /// Only `https` is ever allowed for an opt-in fetch — plaintext `http`
    /// remote images are refused outright rather than silently downgraded
    /// to an insecure request a user never explicitly asked for.
    public var requireHTTPS: Bool

    public init(
        maximumByteCount: Int = 20 * 1_024 * 1_024,
        timeoutSeconds: TimeInterval = 10,
        requireHTTPS: Bool = true
    ) {
        self.maximumByteCount = maximumByteCount
        self.timeoutSeconds = timeoutSeconds
        self.requireHTTPS = requireHTTPS
    }

    public static let `default` = BoundedRemoteFetchLimits()
}

public enum BoundedRemoteFetchError: Error, Equatable {
    case schemeNotAllowed
    case responseTooLarge(byteCount: Int, limit: Int)
    case nonSuccessStatus(Int)
    case transportError(String)
}

/// A minimal, bounded, explicit-only remote fetcher. Nothing in
/// `PreviewCore` calls this automatically while parsing or rendering a
/// document — it exists purely as the implementation the App layer wires
/// up behind a real, per-document "Load remote images" user action, so
/// that action itself is still bounded (size, timeout, scheme) rather than
/// an unbounded `URLSession` call.
public enum BoundedRemoteFetcher {
    public static func fetch(
        _ url: URL,
        limits: BoundedRemoteFetchLimits = .default,
        session: URLSession = .shared
    ) async throws -> Data {
        guard url.scheme?.lowercased() == "https" || (!limits.requireHTTPS && url.scheme?.lowercased() == "http") else {
            throw BoundedRemoteFetchError.schemeNotAllowed
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = limits.timeoutSeconds
        request.httpShouldHandleCookies = false

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw BoundedRemoteFetchError.transportError(String(describing: error))
        }

        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw BoundedRemoteFetchError.nonSuccessStatus(httpResponse.statusCode)
        }
        if let expectedLength = response.expectedContentLength as Int64?, expectedLength > 0, Int(expectedLength) > limits.maximumByteCount {
            throw BoundedRemoteFetchError.responseTooLarge(byteCount: Int(expectedLength), limit: limits.maximumByteCount)
        }

        var data = Data()
        data.reserveCapacity(min(limits.maximumByteCount, 1_024 * 1_024))
        for try await byte in bytes {
            data.append(byte)
            if data.count > limits.maximumByteCount {
                throw BoundedRemoteFetchError.responseTooLarge(byteCount: data.count, limit: limits.maximumByteCount)
            }
        }
        return data
    }
}
