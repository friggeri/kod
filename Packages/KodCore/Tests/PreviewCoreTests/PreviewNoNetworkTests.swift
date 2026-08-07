import Foundation
import ThemeCore
import XCTest
@testable import PreviewCore

/// A `URLProtocol` that fails any request it intercepts, standing in for
/// a network-spy: registering it for the duration of a test means *any*
/// networking anywhere in the process — including from a background
/// thread Kod code might spawn — surfaces as a hard failure instead of
/// silently succeeding or silently being skipped. This is what proves
/// SPEC 10.1/13's "no implicit network" for Markdown/image/JSON parsing,
/// sanitizing, and decoding: none of those operations ever reach this
/// protocol, because none of them ever construct a `URLRequest` at all
/// except through the one explicit, opt-in `BoundedRemoteFetcher` path
/// this suite never calls.
final class NetworkSpyURLProtocol: URLProtocol {
    static let violationCount = LockedCounter()

    override class func canInit(with request: URLRequest) -> Bool {
        violationCount.increment()
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: NSError(domain: "NetworkSpyURLProtocol", code: -1))
    }

    override func stopLoading() {}
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func reset() {
        lock.lock()
        value = 0
        lock.unlock()
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class PreviewNoNetworkTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(NetworkSpyURLProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(NetworkSpyURLProtocol.self)
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        NetworkSpyURLProtocol.violationCount.reset()
    }

    func testMarkdownParsingAndRenderingNeverTouchesNetwork() async {
        let source = """
        # Doc

        Here is a [remote link](https://example.com) and a remote image:

        ![alt](https://example.com/image.png)

        ```swift
        let x = 1
        ```

        | a | b |
        |---|---|
        | 1 | 2 |
        """
        let document = MarkdownParser.parse(source)
        _ = await MarkdownRenderer.render(document, theme: BundledThemes.dark)
        XCTAssertEqual(NetworkSpyURLProtocol.violationCount.current, 0, "Markdown parsing/rendering must never touch the network")
    }

    func testJSONAndPlistParsingNeverTouchesNetwork() {
        _ = JSONParser.parse(Data(#"{"a": [1, 2, 3]}"#.utf8))
        _ = StructuredDocument.parse(Data("<plist version=\"1.0\"><dict><key>a</key><string>b</string></dict></plist>".utf8))
        XCTAssertEqual(NetworkSpyURLProtocol.violationCount.current, 0)
    }

    func testImageDecodingNeverTouchesNetwork() throws {
        let data = try ImageFixture.makePNG(width: 8, height: 8)
        _ = ImageDecoder.decode(data)
        XCTAssertEqual(NetworkSpyURLProtocol.violationCount.current, 0)
    }

    func testSVGSanitizationNeverTouchesNetworkEvenWithExternalReferences() {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"><image href=\"https://example.com/remote.png\"/></svg>"
        _ = SVGSanitizer.sanitize(svg)
        _ = SVGDocumentLoader.load(Data(svg.utf8))
        XCTAssertEqual(NetworkSpyURLProtocol.violationCount.current, 0)
    }

    func testResourcePolicyClassificationAloneNeverFetchesAnything() {
        let policy = MarkdownResourcePolicy(isWorkspaceTrusted: false, remoteImagesEnabledForThisDocument: true)
        let destination = MarkdownDestination(rawValue: "https://example.com/image.png")
        _ = policy.shouldLoadRemoteImage(destination)
        _ = policy.requiresConfirmationToOpen(destination)
        XCTAssertEqual(NetworkSpyURLProtocol.violationCount.current, 0, "computing policy decisions must never itself fetch")
    }

    func testBoundedFetcherIsTheOnlyPathThatEverTouchesNetworkAndOnlyWhenExplicitlyCalled() async {
        // The mirror image of the tests above: this is the *one* function
        // in `PreviewCore` allowed to reach the network, and only because
        // this test explicitly invokes it (standing in for a real,
        // explicit "Load remote images" user action) — proving the spy
        // harness itself is load-bearing, not vacuous.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetworkSpyURLProtocol.self]
        let session = URLSession(configuration: configuration)
        do {
            _ = try await BoundedRemoteFetcher.fetch(URL(string: "https://example.com/image.png")!, session: session)
            XCTFail("the spy protocol always fails requests; reaching here means it was never actually invoked")
        } catch {
            // Expected: the spy failed the request, but only after
            // genuinely intercepting it.
        }
        XCTAssertGreaterThan(NetworkSpyURLProtocol.violationCount.current, 0, "expected the explicit opt-in fetch to actually reach the network layer")
    }
}
