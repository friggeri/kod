import Foundation
import XCTest
@testable import KodFixtureSupport

final class ScaleFixtureGeneratorTests: XCTestCase {
    func testGeneratesDeterministicFixture() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }

        let configuration = ScaleFixtureConfiguration(
            root: root,
            fileCount: 3,
            bytesPerFile: 32
        )
        try ScaleFixtureGenerator().generate(configuration)

        let directory = root.appendingPathComponent("000", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.count, 3)

        let first = try Data(contentsOf: directory.appendingPathComponent("file-000000.swift"))
        XCTAssertEqual(first.count, 32)
        XCTAssertTrue(String(decoding: first, as: UTF8.self).hasPrefix("// fixture 0\n"))
    }

    func testRefusesNonemptyDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: root.appendingPathComponent("existing.txt"))
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }

        let configuration = ScaleFixtureConfiguration(
            root: root,
            fileCount: 1,
            bytesPerFile: 16
        )

        XCTAssertThrowsError(try ScaleFixtureGenerator().generate(configuration)) { error in
            XCTAssertEqual(error as? ScaleFixtureError, .destinationIsNotEmpty(root))
        }
    }
}

