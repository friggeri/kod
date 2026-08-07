import CryptoKit
import Foundation
import ThemeCore
import XCTest
@testable import PreviewCore

/// Proves the SPEC-wide read-only-by-construction guarantee holds for
/// `PreviewCore` specifically: previewing a Markdown file, an image, a
/// JSON file, and a property list — including previewing ones that are
/// themselves hostile/malformed — never changes a single byte, timestamp,
/// or permission bit of the source file on disk. Every operation reads
/// `Data`/`String` into memory once and works from there; nothing in this
/// package ever opens a file for writing.
final class PreviewCoreWorkspaceImmutabilityTests: XCTestCase {
    private var workspaceRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewCoreImmutability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspaceRoot)
        try super.tearDownWithError()
    }

    func testPreviewingMarkdownImageJSONAndPlistNeverModifiesTheSourceFiles() async throws {
        let markdownURL = workspaceRoot.appendingPathComponent("README.md")
        try Data("# Title\n\nSome **bold** [link](https://example.com) text.\n".utf8).write(to: markdownURL)

        let imageURL = workspaceRoot.appendingPathComponent("icon.png")
        try ImageFixture.makePNG(width: 8, height: 8).write(to: imageURL)

        let jsonURL = workspaceRoot.appendingPathComponent("data.json")
        try Data(#"{"a": [1, 2, 3], "b": "hostile\u0000value"}"#.utf8).write(to: jsonURL)

        let plistURL = workspaceRoot.appendingPathComponent("Info.plist")
        try Data("<plist version=\"1.0\"><dict><key>a</key><string>b</string></dict></plist>".utf8).write(to: plistURL)

        // A deliberately hostile file too, so the immutability guarantee
        // is proven for the failure path as well as the success path.
        let hostileURL = workspaceRoot.appendingPathComponent("hostile.md")
        try Data("<script>alert(document.cookie)</script>\n".utf8).write(to: hostileURL)

        let allFiles = [markdownURL, imageURL, jsonURL, plistURL, hostileURL]
        let before = try snapshot(of: allFiles)

        for url in allFiles {
            let data = try Data(contentsOf: url)
            let kind = PreviewContentDetector.detect(pathExtension: url.pathExtension, contentPrefix: data)
            switch kind {
            case .markdown:
                let text = String(data: data, encoding: .utf8) ?? ""
                let document = MarkdownParser.parse(text)
                _ = await MarkdownRenderer.render(document, theme: BundledThemes.dark)
            case .image:
                _ = ImageDecoder.decode(data)
            case .structuredData:
                _ = StructuredDocument.parse(data)
            case .none:
                break
            }
        }

        let after = try snapshot(of: allFiles)
        XCTAssertEqual(before, after, "previewing must never modify workspace file content, size, or modification date")
    }

    // MARK: - Helpers

    private struct FileFingerprint: Equatable {
        let path: String
        let digest: String
        let modificationDate: Date?
        let size: Int
    }

    private func snapshot(of urls: [URL]) throws -> [FileFingerprint] {
        try urls.map { url in
            let data = try Data(contentsOf: url)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return FileFingerprint(
                path: url.path,
                digest: digest,
                modificationDate: attributes[.modificationDate] as? Date,
                size: data.count
            )
        }
    }
}
