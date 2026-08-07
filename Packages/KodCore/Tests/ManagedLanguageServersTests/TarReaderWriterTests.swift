import XCTest
@testable import ManagedLanguageServers

final class TarReaderWriterTests: XCTestCase {
    func testRoundTripBasicEntries() throws {
        let archive = TarWriter.write([
            .init(name: "bin/", type: .directory, mode: 0o755),
            .init(name: "bin/tool", type: .regularFile, mode: 0o755, body: Data("#!/bin/echo\n".utf8)),
            .init(name: "README.txt", type: .regularFile, mode: 0o644, body: Data("hello".utf8))
        ])
        let entries = try TarReader.readEntries(archive)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].name, "bin/")
        XCTAssertEqual(entries[0].type, .directory)
        XCTAssertEqual(entries[1].name, "bin/tool")
        XCTAssertEqual(entries[1].body, Data("#!/bin/echo\n".utf8))
        XCTAssertEqual(entries[1].mode, 0o755)
        XCTAssertEqual(entries[2].body, Data("hello".utf8))
    }

    func testSymlinkEntryDetected() throws {
        let archive = TarWriter.write([
            .init(name: "evil-link", type: .symbolicLink, linkName: "/etc/passwd")
        ])
        let entries = try TarReader.readEntries(archive)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].type, .symbolicLink)
        XCTAssertEqual(entries[0].linkName, "/etc/passwd")
    }

    func testDeviceFileEntryDetected() throws {
        let archive = TarWriter.write([
            .init(name: "dev/evil", type: .characterDevice)
        ])
        let entries = try TarReader.readEntries(archive)
        XCTAssertEqual(entries[0].type, .characterDevice)
    }

    func testCorruptedChecksumRejected() throws {
        var archive = TarWriter.write([.init(name: "a", body: Data("x".utf8))])
        archive[0] = archive[0] &+ 1
        XCTAssertThrowsError(try TarReader.readEntries(archive)) { error in
            guard case TarError.badHeaderChecksum = error else {
                XCTFail("expected badHeaderChecksum, got \(error)")
                return
            }
        }
    }

    func testGzipTarRoundTrip() throws {
        let archive = TarWriter.write([
            .init(name: "hello.txt", body: Data("hello tar.gz".utf8))
        ])
        let compressed = try GzipCodec.compress(archive)
        let decompressed = try GzipCodec.decompress(compressed, maxDecompressedBytes: archive.count + 10)
        let entries = try TarReader.readEntries(decompressed)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].body, Data("hello tar.gz".utf8))
    }
}
