import Foundation
import WorkspaceCore
import XCTest

final class WorkspaceScannerPathComponentValidationTests: XCTestCase {
    func testScanDirectoryRejectsInvalidCStringComponents() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let invalidPaths = [
            "..\0ignored",
            ".\0ignored",
            "\0",
            "folder//child",
            "folder/./child",
            "folder/../child",
            "folder/"
        ]

        for relativePath in invalidPaths {
            do {
                for try await _ in WorkspaceScanner().scanDirectory(
                    root: root,
                    relativePath: relativePath
                ) {}
                XCTFail("Expected \(relativePath.debugDescription) to fail")
            } catch {
                XCTAssertEqual(
                    error as? WorkspaceScannerError,
                    .invalidRelativeDirectory(relativePath)
                )
            }
        }
    }

    func testProductionCapabilitiesRejectInvalidChildNamesBeforeCString() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let enumerator = LocalDirectoryEnumerator()
        guard case .opened(let handle) = try enumerator.openRoot(root) else {
            return XCTFail("Expected root to open")
        }
        defer { enumerator.closeDirectory(handle) }

        for name in ["..\0ignored", ".\0ignored", "child/name", "\0"] {
            XCTAssertThrowsError(
                try enumerator.openChild(
                    name,
                    of: handle,
                    url: root.appendingPathComponent(name),
                    relativePath: name
                )
            ) { error in
                XCTAssertEqual(
                    error as? WorkspaceAccessFailure,
                    .unavailable
                )
            }

            XCTAssertThrowsError(
                try LocalPathMetadataProvider().metadata(
                    ofChild: name,
                    in: handle,
                    url: root.appendingPathComponent(name)
                )
            ) { error in
                XCTAssertEqual(
                    error as? WorkspaceAccessFailure,
                    .unavailable
                )
            }
        }
    }

    func testUnicodeDirectoryComponentsRemainValid() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(
            "日本語-café",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("source".utf8).write(
            to: directory.appendingPathComponent("résumé.swift")
        )

        var paths: [String] = []
        for try await batch in WorkspaceScanner().scanDirectory(
            root: root,
            relativePath: "日本語-café"
        ) {
            paths.append(contentsOf: batch.entries.map(\.relativePath))
        }

        XCTAssertEqual(paths, ["日本語-café/résumé.swift"])
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WorkspaceScannerPathComponents-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}
