import XCTest
@testable import PreviewCore

final class MarkdownResourcePolicyTests: XCTestCase {
    func testUntrustedDefaultBlocksEverythingRemote() {
        let policy = MarkdownResourcePolicy.untrustedDefault
        XCTAssertFalse(policy.isWorkspaceTrusted)
        XCTAssertFalse(policy.remoteImagesEnabledForThisDocument)
        XCTAssertTrue(policy.requiresConfirmationToOpen(MarkdownDestination(rawValue: "https://example.com")))
        XCTAssertFalse(policy.shouldLoadRemoteImage(MarkdownDestination(rawValue: "https://example.com/image.png")))
    }

    func testLocalLinksNeverRequireConfirmation() {
        let policy = MarkdownResourcePolicy.untrustedDefault
        XCTAssertFalse(policy.requiresConfirmationToOpen(MarkdownDestination(rawValue: "./relative/path.md")))
        XCTAssertFalse(policy.requiresConfirmationToOpen(MarkdownDestination(rawValue: "#fragment")))
    }

    func testTrustedWorkspaceDoesNotRequireConfirmation() {
        let policy = MarkdownResourcePolicy(isWorkspaceTrusted: true)
        XCTAssertFalse(policy.requiresConfirmationToOpen(MarkdownDestination(rawValue: "https://example.com")))
    }

    func testRemoteImagesRequireExplicitPerDocumentOptIn() {
        var policy = MarkdownResourcePolicy.untrustedDefault
        let destination = MarkdownDestination(rawValue: "https://example.com/image.png")
        XCTAssertFalse(policy.shouldLoadRemoteImage(destination))
        policy.remoteImagesEnabledForThisDocument = true
        XCTAssertTrue(policy.shouldLoadRemoteImage(destination))
    }

    func testLocalImagesAlwaysLoadRegardlessOfOptIn() {
        let policy = MarkdownResourcePolicy.untrustedDefault
        XCTAssertTrue(policy.shouldLoadRemoteImage(MarkdownDestination(rawValue: "./local.png")))
    }

    // MARK: - Bounded fetcher (no implicit network; explicit-only path)

    func testBoundedFetcherRejectsNonHTTPSSchemeByDefault() async {
        do {
            _ = try await BoundedRemoteFetcher.fetch(URL(string: "http://example.com/image.png")!)
            XCTFail("expected plaintext http to be refused by default")
        } catch BoundedRemoteFetchError.schemeNotAllowed {
            // expected
        } catch {
            XCTFail("expected schemeNotAllowed, got \(error)")
        }
    }

    func testBoundedFetcherRejectsFileScheme() async {
        do {
            _ = try await BoundedRemoteFetcher.fetch(URL(string: "file:///etc/passwd")!)
            XCTFail("expected file: scheme to be refused")
        } catch BoundedRemoteFetchError.schemeNotAllowed {
            // expected
        } catch {
            XCTFail("expected schemeNotAllowed, got \(error)")
        }
    }
}
