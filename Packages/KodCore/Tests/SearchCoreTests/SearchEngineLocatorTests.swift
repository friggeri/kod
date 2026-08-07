import Foundation
import XCTest
@testable import SearchCore

final class SearchEngineLocatorTests: XCTestCase {
    func testCurrentArchitectureIsSupportedOnThisTestHost() {
        // The CI/dev host for Kod is Apple silicon or Intel; both are
        // bundled. Any other architecture is an explicit, surfaced error
        // rather than a silent fallback (see testUnsupportedArchitectureThrows
        // — this test documents that *this* host resolves to a real case).
        XCTAssertNotNil(SearchEngineArchitecture.current)
    }

    func testBundledExecutableURLResolvesToAnExecutableFile() throws {
        let url = try SearchEngineLocator.bundledExecutableURL()

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        XCTAssertFalse(isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path))
    }

    func testBundledExecutableReportsThePinnedVersion() throws {
        let url = try SearchEngineLocator.bundledExecutableURL()

        let process = Process()
        process.executableURL = url
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(output.contains("ripgrep 14.1.1"), "unexpected version output: \(output)")
    }

    func testMissingBundledExecutableThrowsExplicitError() {
        // An empty bundle has no `ripgrep/<arch>/rg` resource, simulating a
        // packaging defect without needing to strip the real resource.
        let emptyBundle = Bundle(for: BundleMarker.self)

        XCTAssertThrowsError(try SearchEngineLocator.bundledExecutableURL(bundle: emptyBundle)) { error in
            guard case SearchEngineError.bundledExecutableMissing = error else {
                return XCTFail("expected bundledExecutableMissing, got \(error)")
            }
        }
    }
}

private final class BundleMarker {}
