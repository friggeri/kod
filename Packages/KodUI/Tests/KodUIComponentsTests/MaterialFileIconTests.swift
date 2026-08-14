import AppKit
import XCTest
@testable import KodUIComponents

/// Headless coverage for the Material file-icon mapping, the bundled
/// resources it addresses, and the single documented generic fallback.
/// Nothing here creates a window, makes one key, or orders one front.
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

    /// Every asset the manifest can name must actually ship in this
    /// package's resource bundle: the mapping and the SVGs are vendored
    /// and versioned together, so a missing file is a packaging bug
    /// rather than something to discover at runtime.
    func testEveryMappedAssetIsBundled() throws {
        let manifest = try bundledManifest()
        let bundle = Bundle.kodUIComponents

        XCTAssertFalse(manifest.iconDefinitions.isEmpty)
        for (identifier, assetName) in manifest.iconDefinitions {
            XCTAssertEqual(
                assetName,
                (assetName as NSString).lastPathComponent,
                "\(identifier) must name a file, not a path"
            )
            XCTAssertTrue(assetName.hasSuffix(".svg"), "\(identifier) must map to an SVG asset")
            XCTAssertNotNil(
                bundle.url(
                    forResource: assetName,
                    withExtension: nil,
                    subdirectory: "MaterialIcons/icons"
                ),
                "\(assetName) is mapped by the manifest but missing from the bundle"
            )
        }
    }

    func testProviderResolvesRepresentativeFilesToLoadableAssets() {
        let provider = MaterialFileIconProvider()

        for (fileName, expectedAsset) in [
            ("main.swift", "swift.svg"),
            ("app.tsx", "react_ts.svg"),
            ("README.md", "readme.svg"),
            ("Cargo.toml", "toml.svg"),
            ("unknown.kod-file", "file.svg")
        ] {
            let resolution = provider.resolution(forFileName: fileName, isLight: false)
            XCTAssertEqual(resolution.assetName, expectedAsset, "unexpected asset for \(fileName)")
            XCTAssertNotEqual(resolution.image.size, .zero, "\(expectedAsset) should decode to a real image")
        }
    }

    func testProviderCachesDecodedAssets() {
        let provider = MaterialFileIconProvider()

        let first = provider.resolution(forFileName: "main.swift", isLight: false)
        let second = provider.resolution(forFileName: "Package.swift", isLight: false)

        XCTAssertEqual(first.assetName, second.assetName)
        XCTAssertIdentical(first.image, second.image)
    }

    func testAppearanceSelectsTheLightVariantOfAnIcon() throws {
        let provider = MaterialFileIconProvider()
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))

        XCTAssertNotIdentical(
            provider.image(forFileName: "Cargo.toml", appearance: light),
            provider.image(forFileName: "Cargo.toml", appearance: dark)
        )
    }

    func testMissingAssetFallsBackToTheManifestDefaultIcon() {
        let provider = MaterialFileIconProvider(
            manifest: manifest(
                defaultIcon: "file",
                iconDefinitions: ["swift": "kod-tests-absent-icon.svg", "file": "file.svg"],
                fileExtensions: ["swift": "swift"]
            ),
            bundle: .kodUIComponents
        )

        let resolution = provider.resolution(forFileName: "main.swift", isLight: false)

        XCTAssertEqual(resolution.assetName, "file.svg")
    }

    func testUnusableDefaultIconFallsBackToTheGenericSymbol() {
        let provider = MaterialFileIconProvider(
            manifest: manifest(
                defaultIcon: "file",
                iconDefinitions: ["file": "kod-tests-absent-icon.svg"]
            ),
            bundle: .kodUIComponents
        )
        let symbolName = MaterialFileIconProvider.genericFallbackSymbolName

        let resolution = provider.resolution(forFileName: "main.swift", isLight: false)

        XCTAssertNil(resolution.assetName)
        XCTAssertNotEqual(
            resolution.image.size,
            .zero,
            "the generic \(symbolName) symbol should resolve"
        )
    }

    func testMissingManifestFallsBackToTheGenericSymbol() {
        let provider = MaterialFileIconProvider(manifest: nil, bundle: .kodUIComponents)

        XCTAssertNil(provider.resolution(forFileName: "main.swift", isLight: false).assetName)
    }

    /// The manifest is vendored data, so the provider treats any asset
    /// name that is not a plain `*.svg` file name as unusable rather
    /// than resolving it relative to the bundle.
    func testPathShapedAssetNamesAreRejected() {
        let provider = MaterialFileIconProvider(
            manifest: manifest(
                defaultIcon: "file",
                iconDefinitions: ["file": "../MaterialIcons/icons/file.svg"]
            ),
            bundle: .kodUIComponents
        )

        XCTAssertNil(provider.resolution(forFileName: "main.swift", isLight: false).assetName)
    }

    func testIconViewShowsAndClearsIconsForItsFileName() {
        let view = MaterialFileIconView()
        XCTAssertNil(view.image)

        view.fileName = "main.swift"
        XCTAssertNotNil(view.image)

        view.fileName = nil
        XCTAssertNil(view.image)
    }

    private func bundledManifest() throws -> MaterialFileIconManifest {
        try MaterialFileIconManifest.bundled(in: .kodUIComponents)
    }

    private func manifest(
        defaultIcon: String,
        iconDefinitions: [String: String],
        fileExtensions: [String: String] = [:],
        fileNames: [String: String] = [:]
    ) -> MaterialFileIconManifest {
        MaterialFileIconManifest(
            schemaVersion: 1,
            sourceVersion: "test",
            defaultIcon: defaultIcon,
            iconDefinitions: iconDefinitions,
            fileExtensions: fileExtensions,
            fileNames: fileNames,
            light: MaterialFileIconManifest.AppearanceOverrides(
                fileExtensions: [:],
                fileNames: [:]
            )
        )
    }
}
