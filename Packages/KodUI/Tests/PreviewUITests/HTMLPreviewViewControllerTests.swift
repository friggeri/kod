import Foundation
import PreviewCore
import XCTest
@testable import PreviewUI

@MainActor
final class HTMLPreviewViewControllerTests: XCTestCase {
    func testRendersHTMLLoadsLocalResourceAndDoesNotExecuteScript() async throws {
        var loadedPaths: [String] = []
        let html = """
        <!doctype html>
        <html>
        <head><title>Static fixture</title></head>
        <body>
            <img src="vector.svg" alt="Fixture">
            <script>document.title = "Script executed";</script>
        </body>
        </html>
        """
        let controller = HTMLPreviewViewController(
            data: Data(html.utf8),
            documentRelativePath: "Fixtures/Site/index.html",
            loadLocalResource: { path in
                loadedPaths.append(path)
                return Data(
                    """
                    <svg xmlns="http://www.w3.org/2000/svg" width="1" height="1">
                    <rect width="1" height="1" fill="red"/>
                    </svg>
                    """.utf8
                )
            },
            isWorkspaceTrusted: { false },
            openLocalRelativePath: nil,
            confirmBeforeOpening: { _ in false }
        )

        controller.loadView()
        let deadline = Date().addingTimeInterval(5)
        while (controller.webView.title != "Static fixture"
               || loadedPaths.isEmpty),
              Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(controller.webView.title, "Static fixture")
        XCTAssertEqual(
            loadedPaths,
            ["Fixtures/Site/vector.svg"]
        )
    }

    func testResourceURLsResolveOnlyToWorkspaceRelativePaths() throws {
        let documentURL = try XCTUnwrap(
            HTMLPreviewResourceURL.documentURL(
                for: "Fixtures/Preview Workspace/index.html"
            )
        )
        XCTAssertEqual(
            documentURL.absoluteString,
            "kod-preview-resource://workspace/Fixtures/Preview%20Workspace/index.html"
        )

        let sibling = try XCTUnwrap(
            URL(string: "vector.svg", relativeTo: documentURL)?.absoluteURL
        )
        XCTAssertEqual(
            HTMLPreviewResourceURL.relativePath(from: sibling),
            "Fixtures/Preview Workspace/vector.svg"
        )
        XCTAssertNil(
            HTMLPreviewResourceURL.relativePath(
                from: URL(fileURLWithPath: "/etc/passwd")
            )
        )
        XCTAssertNil(
            HTMLPreviewResourceURL.relativePath(
                from: URL(string: "https://example.com/tracker.js")!
            )
        )
        XCTAssertNil(
            HTMLPreviewResourceURL.relativePath(
                from: URL(
                    string: "kod-preview-resource://workspace/%252e%252e/secret"
                )!
            )
        )
    }

    func testTraversalCannotProduceAnAbsoluteFilesystemPath() throws {
        let documentURL = try XCTUnwrap(
            HTMLPreviewResourceURL.documentURL(
                for: "Fixtures/Site/index.html"
            )
        )
        let escaped = try XCTUnwrap(
            URL(
                string: "../../../../etc/passwd",
                relativeTo: documentURL
            )?.absoluteURL
        )

        XCTAssertEqual(
            HTMLPreviewResourceURL.relativePath(from: escaped),
            "etc/passwd"
        )
    }
}
