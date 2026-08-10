import AppKit
import XCTest
@testable import Kod

@MainActor
final class MaterialFileIconTests: XCTestCase {
    func testBundledManifestMapsFileNamesAndExtensions() throws {
        let manifest = try bundledManifest()

        XCTAssertEqual(manifest.iconIdentifier(forFileName: "README.md", isLight: false), "readme")
        XCTAssertEqual(manifest.iconIdentifier(forFileName: "Package.swift", isLight: false), "swift")
        XCTAssertEqual(manifest.iconIdentifier(forFileName: "package.json", isLight: false), "nodejs")
        XCTAssertEqual(manifest.iconIdentifier(forFileName: ".gitignore", isLight: false), "git")
        XCTAssertEqual(manifest.iconIdentifier(forFileName: "Dockerfile", isLight: false), "docker")
        XCTAssertEqual(manifest.iconIdentifier(forFileName: "Caddyfile", isLight: false), "caddy")
        XCTAssertEqual(
            manifest.iconIdentifier(forFileName: ".github/FUNDING.yml", isLight: false),
            "github-sponsors"
        )
        XCTAssertEqual(manifest.iconIdentifier(forFileName: "Main.SWIFT", isLight: false), "swift")
        XCTAssertEqual(manifest.iconIdentifier(forFileName: "unknown.kod-file", isLight: false), "file")
    }

    func testCompoundExtensionsUseMostSpecificMapping() throws {
        let manifest = try bundledManifest()

        XCTAssertEqual(manifest.iconIdentifier(forFileName: "types.d.ts", isLight: false), "typescript-def")
        XCTAssertEqual(manifest.iconIdentifier(forFileName: "widget.test.ts", isLight: false), "test-ts")
        XCTAssertEqual(manifest.iconIdentifier(forFileName: "widget.ts", isLight: false), "typescript")
    }

    func testLightAppearanceUsesMaterialThemeOverride() throws {
        let manifest = try bundledManifest()

        XCTAssertEqual(manifest.iconIdentifier(forFileName: "Cargo.toml", isLight: false), "toml")
        XCTAssertEqual(manifest.iconIdentifier(forFileName: "Cargo.toml", isLight: true), "toml_light")
    }

    func testMappedAssetsAreBundledAndLoadable() throws {
        let manifest = try bundledManifest()
        let bundle = MaterialFileIconProvider.resourceBundle

        for fileName in ["main.swift", "app.tsx", "README.md", "Cargo.toml", "unknown.kod-file"] {
            let identifier = manifest.iconIdentifier(forFileName: fileName, isLight: false)
            let assetName = try XCTUnwrap(manifest.iconDefinitions[identifier])
            let url = try XCTUnwrap(
                bundle.url(
                    forResource: assetName,
                    withExtension: nil,
                    subdirectory: "MaterialIcons/icons"
                )
            )
            XCTAssertNotNil(NSImage(contentsOf: url), "\(assetName) should be a loadable image")
        }
    }

    private func bundledManifest() throws -> MaterialFileIconManifest {
        try MaterialFileIconManifest.bundled(in: MaterialFileIconProvider.resourceBundle)
    }
}
