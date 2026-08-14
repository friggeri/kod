import Foundation
import XCTest

final class KodUITargetBoundaryTests: XCTestCase {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testProductionTargetsOnlyImportDeclaredBoundaryModules() throws {
        let allowedImports: [String: Set<String>] = [
            "KodUIComponents": [
                "AppKit", "FontCore", "Foundation", "SettingsCore",
                "TextDecorationModel", "ThemeCore", "os"
            ],
            "SearchUI": [
                "AppKit", "DiagnosticsCore", "Foundation",
                "KodUIComponents", "SearchCore"
            ],
            "PreviewUI": [
                "AppKit", "DiagnosticsCore", "FontCore", "Foundation",
                "KodUIComponents", "PreviewCore", "ThemeCore"
            ],
            "GitUI": [
                "AppKit", "CodeViewport", "Foundation", "GitCore",
                "KodUIComponents", "SettingsCore", "ThemeCore"
            ],
            "EditorUI": [
                "AppKit", "CodeViewport", "FontCore", "Foundation", "GitCore",
                "GitUI", "KodUIComponents", "LanguageClient", "PreviewCore",
                "PreviewUI", "QuartzCore", "SettingsCore", "SourceModel",
                "SyntaxCore", "ThemeCore", "WorkspaceCore"
            ]
        ]

        for (target, allowed) in allowedImports {
            let sourceRoot = packageRoot
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent(target, isDirectory: true)
            for sourceURL in try swiftFiles(under: sourceRoot) {
                let imports = try String(contentsOf: sourceURL, encoding: .utf8)
                    .split(separator: "\n")
                    .compactMap { line -> String? in
                        let fields = line.split { $0.isWhitespace }
                        guard fields.count == 2, fields[0] == "import" else {
                            return nil
                        }
                        return String(fields[1])
                    }
                XCTAssertTrue(
                    Set(imports).isSubset(of: allowed),
                    "\(target)/\(sourceURL.lastPathComponent) imports outside its boundary: "
                        + Set(imports).subtracting(allowed).sorted().joined(separator: ", ")
                )
                XCTAssertFalse(imports.contains("Kod"))
            }
        }
    }

    func testFeatureTargetsUsePackageResourcesInsteadOfAppBundle() throws {
        for target in ["SearchUI", "PreviewUI", "GitUI", "EditorUI"] {
            let sourceRoot = packageRoot
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent(target, isDirectory: true)
            for sourceURL in try swiftFiles(under: sourceRoot) {
                let source = try String(contentsOf: sourceURL, encoding: .utf8)
                XCTAssertFalse(source.contains("Bundle.main"), sourceURL.path)
                XCTAssertFalse(source.contains("Localized.string("), sourceURL.path)
            }
        }
    }

    private func swiftFiles(under root: URL) throws -> [URL] {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
        )
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }
}
