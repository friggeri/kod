import XCTest
@testable import ManagedLanguageServers

final class SecureArchiveExtractorTests: XCTestCase {
    private var stagingRoot: URL!

    override func setUpWithError() throws {
        stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("SecureArchiveExtractorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stagingRoot)
    }

    private func gz(_ entries: [TarWriter.RawEntry]) throws -> Data {
        try GzipCodec.compress(TarWriter.write(entries))
    }

    func testHappyPathExtractsAndSetsExecutableBit() throws {
        let archive = try gz([
            .init(name: "bin/tool", type: .regularFile, mode: 0o644, body: Data("binary".utf8)),
            .init(name: "README.md", type: .regularFile, mode: 0o644, body: Data("docs".utf8))
        ])
        let written = try SecureArchiveExtractor.extract(
            archiveBytes: archive,
            format: .tarGz,
            maxDecompressedBytes: 1 << 20,
            expectedRelativePaths: ["bin/tool", "README.md"],
            executableRelativePath: "bin/tool",
            destinationRoot: stagingRoot
        )
        XCTAssertEqual(written, ["README.md", "bin/tool"])
        let attrs = try FileManager.default.attributesOfItem(atPath: stagingRoot.appendingPathComponent("bin/tool").path)
        let permissions = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, 0o755)
        let readmeAttrs = try FileManager.default.attributesOfItem(atPath: stagingRoot.appendingPathComponent("README.md").path)
        XCTAssertEqual((readmeAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o644)
    }

    func testPathTraversalRejected() throws {
        let archive = try gz([.init(name: "../evil", body: Data())])
        XCTAssertThrowsError(try SecureArchiveExtractor.extract(
            archiveBytes: archive, format: .tarGz, maxDecompressedBytes: 65536,
            expectedRelativePaths: ["evil"], executableRelativePath: "evil", destinationRoot: stagingRoot
        )) { error in
            guard case ArchiveExtractionError.pathTraversal = error else {
                XCTFail("expected pathTraversal, got \(error)"); return
            }
        }
    }

    func testNestedTraversalRejected() throws {
        let archive = try gz([.init(name: "bin/../../evil", body: Data())])
        XCTAssertThrowsError(try SecureArchiveExtractor.extract(
            archiveBytes: archive, format: .tarGz, maxDecompressedBytes: 65536,
            expectedRelativePaths: ["evil"], executableRelativePath: "evil", destinationRoot: stagingRoot
        )) { error in
            guard case ArchiveExtractionError.pathTraversal = error else {
                XCTFail("expected pathTraversal, got \(error)"); return
            }
        }
    }

    func testAbsolutePathRejected() throws {
        let archive = try gz([.init(name: "/etc/passwd", body: Data())])
        XCTAssertThrowsError(try SecureArchiveExtractor.extract(
            archiveBytes: archive, format: .tarGz, maxDecompressedBytes: 65536,
            expectedRelativePaths: ["etc/passwd"], executableRelativePath: "etc/passwd", destinationRoot: stagingRoot
        )) { error in
            guard case ArchiveExtractionError.absolutePath = error else {
                XCTFail("expected absolutePath, got \(error)"); return
            }
        }
    }

    func testSymlinkEscapeRejected() throws {
        let archive = try gz([.init(name: "bin/tool", type: .symbolicLink, linkName: "/etc/passwd")])
        XCTAssertThrowsError(try SecureArchiveExtractor.extract(
            archiveBytes: archive, format: .tarGz, maxDecompressedBytes: 65536,
            expectedRelativePaths: ["bin/tool"], executableRelativePath: "bin/tool", destinationRoot: stagingRoot
        )) { error in
            guard case ArchiveExtractionError.disallowedEntryType(_, let type) = error else {
                XCTFail("expected disallowedEntryType, got \(error)"); return
            }
            XCTAssertEqual(type, "symbolicLink")
        }
    }

    func testHardLinkRejected() throws {
        let archive = try gz([.init(name: "bin/tool", type: .hardLink, linkName: "bin/other")])
        XCTAssertThrowsError(try SecureArchiveExtractor.extract(
            archiveBytes: archive, format: .tarGz, maxDecompressedBytes: 65536,
            expectedRelativePaths: ["bin/tool"], executableRelativePath: "bin/tool", destinationRoot: stagingRoot
        )) { error in
            guard case ArchiveExtractionError.disallowedEntryType(_, let type) = error else {
                XCTFail("expected disallowedEntryType, got \(error)"); return
            }
            XCTAssertEqual(type, "hardLink")
        }
    }

    func testDeviceFileRejected() throws {
        let archive = try gz([.init(name: "dev/evil", type: .characterDevice)])
        XCTAssertThrowsError(try SecureArchiveExtractor.extract(
            archiveBytes: archive, format: .tarGz, maxDecompressedBytes: 65536,
            expectedRelativePaths: ["dev/evil"], executableRelativePath: "dev/evil", destinationRoot: stagingRoot
        )) { error in
            guard case ArchiveExtractionError.disallowedEntryType(_, let type) = error else {
                XCTFail("expected disallowedEntryType, got \(error)"); return
            }
            XCTAssertEqual(type, "characterDevice")
        }
    }

    func testDuplicateEntryRejected() throws {
        let archive = try gz([
            .init(name: "bin/tool", body: Data("a".utf8)),
            .init(name: "bin/tool", body: Data("b".utf8))
        ])
        XCTAssertThrowsError(try SecureArchiveExtractor.extract(
            archiveBytes: archive, format: .tarGz, maxDecompressedBytes: 65536,
            expectedRelativePaths: ["bin/tool"], executableRelativePath: "bin/tool", destinationRoot: stagingRoot
        )) { error in
            guard case ArchiveExtractionError.duplicateOrCaseFoldCollision = error else {
                XCTFail("expected duplicateOrCaseFoldCollision, got \(error)"); return
            }
        }
    }

    func testCaseFoldCollisionRejected() throws {
        let archive = try gz([
            .init(name: "bin/Tool", body: Data("a".utf8)),
            .init(name: "bin/tool", body: Data("b".utf8))
        ])
        XCTAssertThrowsError(try SecureArchiveExtractor.extract(
            archiveBytes: archive, format: .tarGz, maxDecompressedBytes: 65536,
            expectedRelativePaths: ["bin/Tool", "bin/tool"], executableRelativePath: "bin/tool", destinationRoot: stagingRoot
        )) { error in
            guard case ArchiveExtractionError.duplicateOrCaseFoldCollision = error else {
                XCTFail("expected duplicateOrCaseFoldCollision, got \(error)"); return
            }
        }
    }

    func testDecompressionBombRejected() throws {
        let bigBody = Data(repeating: 0, count: 5_000_000)
        let archive = try gz([.init(name: "bomb", body: bigBody)])
        XCTAssertThrowsError(try SecureArchiveExtractor.extract(
            archiveBytes: archive, format: .tarGz, maxDecompressedBytes: 65536,
            expectedRelativePaths: ["bomb"], executableRelativePath: "bomb", destinationRoot: stagingRoot
        ))
    }

    func testUnexpectedExecutableSmuggledRejected() throws {
        let archive = try gz([
            .init(name: "bin/tool", body: Data("a".utf8)),
            .init(name: "bin/evil", body: Data("b".utf8))
        ])
        XCTAssertThrowsError(try SecureArchiveExtractor.extract(
            archiveBytes: archive, format: .tarGz, maxDecompressedBytes: 65536,
            expectedRelativePaths: ["bin/tool"], executableRelativePath: "bin/tool", destinationRoot: stagingRoot
        )) { error in
            guard case ArchiveExtractionError.layoutMismatch(_, let unexpected) = error else {
                XCTFail("expected layoutMismatch, got \(error)"); return
            }
            XCTAssertEqual(unexpected, ["bin/evil"])
        }
    }

    func testMissingExpectedFileRejected() throws {
        let archive = try gz([.init(name: "bin/tool", body: Data("a".utf8))])
        XCTAssertThrowsError(try SecureArchiveExtractor.extract(
            archiveBytes: archive, format: .tarGz, maxDecompressedBytes: 65536,
            expectedRelativePaths: ["bin/tool", "bin/other"], executableRelativePath: "bin/tool", destinationRoot: stagingRoot
        )) { error in
            guard case ArchiveExtractionError.layoutMismatch(let missing, _) = error else {
                XCTFail("expected layoutMismatch, got \(error)"); return
            }
            XCTAssertEqual(missing, ["bin/other"])
        }
    }

    func testZipFormatRejectedAsUnsupported() throws {
        XCTAssertThrowsError(try SecureArchiveExtractor.extract(
            archiveBytes: Data(), format: .zip, maxDecompressedBytes: 65536,
            expectedRelativePaths: [], executableRelativePath: "", destinationRoot: stagingRoot
        )) { error in
            guard case ArchiveExtractionError.unsupportedFormat = error else {
                XCTFail("expected unsupportedFormat, got \(error)"); return
            }
        }
    }

    func testEntryCountExceededRejected() throws {
        var entries: [TarWriter.RawEntry] = []
        for index in 0..<5 {
            entries.append(.init(name: "file\(index)", body: Data("x".utf8)))
        }
        let archive = try gz(entries)
        XCTAssertThrowsError(try SecureArchiveExtractor.extract(
            archiveBytes: archive, format: .tarGz, maxDecompressedBytes: 65536,
            expectedRelativePaths: (0..<5).map { "file\($0)" }, executableRelativePath: "file0",
            destinationRoot: stagingRoot, maxEntryCount: 3
        )) { error in
            guard case ArchiveExtractionError.entryCountExceeded = error else {
                XCTFail("expected entryCountExceeded, got \(error)"); return
            }
        }
    }
}
