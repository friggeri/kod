import XCTest
@testable import PreviewCore

final class PlistParserTests: XCTestCase {
    // MARK: - XML plist golden

    func testParsesXMLPlistDictionary() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Name</key>
            <string>Kod</string>
            <key>Count</key>
            <integer>42</integer>
            <key>Ratio</key>
            <real>1.5</real>
            <key>Enabled</key>
            <true/>
            <key>Disabled</key>
            <false/>
            <key>Items</key>
            <array>
                <string>a</string>
                <string>b</string>
            </array>
        </dict>
        </plist>
        """
        let document = StructuredDocument.parse(Data(xml.utf8))
        XCTAssertEqual(document.format, .xmlPropertyList)
        guard case .object(let members) = document.node else {
            return XCTFail("expected valid object, diagnostic: \(String(describing: document.diagnostic))")
        }
        XCTAssertEqual(members.map(\.key), ["Name", "Count", "Ratio", "Enabled", "Disabled", "Items"])
        XCTAssertEqual(members[0].value, .string("Kod"))
        XCTAssertEqual(members[1].value, .number("42"))
        XCTAssertEqual(members[2].value, .number("1.5"))
        XCTAssertEqual(members[3].value, .bool(true))
        XCTAssertEqual(members[4].value, .bool(false))
        guard case .array(let items) = members[5].value else {
            return XCTFail("expected array")
        }
        XCTAssertEqual(items, [.string("a"), .string("b")])
    }

    func testParsesXMLPlistDateAndData() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>When</key>
            <date>2024-01-02T03:04:05Z</date>
            <key>Blob</key>
            <data>aGVsbG8=</data>
        </dict>
        </plist>
        """
        let document = StructuredDocument.parse(Data(xml.utf8))
        guard case .object(let members) = document.node else {
            return XCTFail("expected valid object, diagnostic: \(String(describing: document.diagnostic))")
        }
        guard case .date(let date) = members[0].value else {
            return XCTFail("expected date")
        }
        XCTAssertEqual(Int(date.timeIntervalSince1970), 1_704_164_645)
        guard case .data(let data) = members[1].value else {
            return XCTFail("expected data")
        }
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "hello")
    }

    // MARK: - Binary plist golden (round-trip via PropertyListSerialization)

    func testParsesBinaryPlistProducedBySystemSerializer() throws {
        let original: [String: Any] = [
            "Name": "Kod",
            "Count": 42,
            "Enabled": true,
            "Items": ["a", "b", "c"]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: original, format: .binary, options: 0)
        let document = StructuredDocument.parse(data)
        XCTAssertEqual(document.format, .binaryPropertyList)
        guard case .object(let members) = document.node else {
            return XCTFail("expected valid object, diagnostic: \(String(describing: document.diagnostic))")
        }
        let dict = Dictionary(uniqueKeysWithValues: members.map { ($0.key, $0.value) })
        XCTAssertEqual(dict["Name"], .string("Kod"))
        XCTAssertEqual(dict["Count"], .number("42"))
        XCTAssertEqual(dict["Enabled"], .bool(true))
        guard case .array(let items) = dict["Items"] else {
            return XCTFail("expected array")
        }
        XCTAssertEqual(items, [.string("a"), .string("b"), .string("c")])
    }

    func testParsesBinaryPlistWithNestedContainers() throws {
        let original: [String: Any] = [
            "outer": [
                "inner": [1, 2, 3],
                "flag": false
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: original, format: .binary, options: 0)
        let document = StructuredDocument.parse(data)
        guard case .object(let members) = document.node, members.count == 1, case .object(let inner) = members[0].value else {
            return XCTFail("expected nested object, diagnostic: \(String(describing: document.diagnostic))")
        }
        XCTAssertEqual(inner.map(\.key).sorted(), ["flag", "inner"])
    }

    // MARK: - Hostile / diagnostics

    func testMalformedXMLPlistReportsDiagnosticNotEmptySuccess() {
        let xml = "<plist><dict><key>a</key><string>unterminated</dict></plist>"
        let document = StructuredDocument.parse(Data(xml.utf8))
        XCTAssertNil(document.node)
        XCTAssertNotNil(document.diagnostic)
    }

    func testXMLPlistWithCustomEntityDeclarationIsRejected() {
        // A classic "billion laughs" style payload: entity declarations
        // Kod must never expand, either for exponential-blowup memory
        // exhaustion or for XXE-style data exfiltration.
        let xml = """
        <?xml version="1.0"?>
        <!DOCTYPE plist [
          <!ENTITY lol "lol">
          <!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">
        ]>
        <plist version="1.0"><dict><key>a</key><string>&lol2;</string></dict></plist>
        """
        let document = StructuredDocument.parse(Data(xml.utf8))
        guard case .invalid(.malformedXMLPlist) = document.result else {
            return XCTFail("expected custom entity declarations to be rejected outright, got \(document.result)")
        }
    }

    func testXMLPlistExternalEntityIsNeverResolved() {
        // An XXE probe pointing at a local file. Even if somehow
        // tokenized, external entities must never be resolved/fetched.
        let xml = """
        <?xml version="1.0"?>
        <!DOCTYPE plist [
          <!ENTITY xxe SYSTEM "file:///etc/passwd">
        ]>
        <plist version="1.0"><dict><key>a</key><string>&xxe;</string></dict></plist>
        """
        let document = StructuredDocument.parse(Data(xml.utf8))
        // Either rejected outright (expected) or, if parsed, the
        // external entity's content must never appear literally in the
        // resulting tree.
        if case .valid(.object(let members)) = document.result {
            for member in members {
                if case .string(let value) = member.value {
                    XCTAssertFalse(value.contains("root:"), "external entity content must never be resolved into the tree")
                }
            }
        } else {
            XCTAssertNotNil(document.diagnostic)
        }
    }

    func testDuplicateKeyInXMLPlistIsReported() {
        let xml = """
        <plist version="1.0"><dict>
            <key>a</key><string>1</string>
            <key>a</key><string>2</string>
        </dict></plist>
        """
        guard case .invalid(.duplicateKey) = StructuredDocument.parse(Data(xml.utf8)).result else {
            return XCTFail("expected duplicateKey diagnostic")
        }
    }

    func testValueWithoutPrecedingKeyIsRejected() {
        let xml = "<plist version=\"1.0\"><dict><string>orphan</string></dict></plist>"
        guard case .invalid = StructuredDocument.parse(Data(xml.utf8)).result else {
            return XCTFail("expected invalid result for a dict value with no preceding key")
        }
    }

    func testDeeplyNestedXMLPlistExceedsDepthLimit() {
        let depth = 2_000
        let xml = "<plist version=\"1.0\">" + String(repeating: "<array>", count: depth) + String(repeating: "</array>", count: depth) + "</plist>"
        let limits = StructuredDataLimits(maximumDepth: 100)
        guard case .invalid(.depthLimitExceeded) = XMLPlistParser.parse(Data(xml.utf8), limits: limits) else {
            return XCTFail("expected depthLimitExceeded")
        }
    }

    func testNotAPropertyListForArbitraryBinaryData() {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0] = 0xDE
        bytes[1] = 0xAD
        bytes[2] = 0xBE
        bytes[3] = 0xEF
        guard case .invalid(.notAPropertyList) = XMLPlistParser.parse(Data(bytes), limits: .default) else {
            return XCTFail("expected notAPropertyList for arbitrary binary content")
        }
    }

    // MARK: - Binary plist hostile

    func testTruncatedBinaryPlistHeaderIsRejected() {
        var bytes = Array("bplist00".utf8)
        bytes.append(contentsOf: [0, 0, 0]) // far too short to contain a real trailer
        guard case .invalid = BinaryPlistParser.parse(Data(bytes), limits: .default) else {
            return XCTFail("expected a truncated binary plist to be rejected")
        }
    }

    func testBinaryPlistWithOutOfRangeTopObjectIsRejected() throws {
        let original: [String: Any] = ["a": 1]
        var data = try PropertyListSerialization.data(fromPropertyList: original, format: .binary, options: 0)
        // Corrupt the top-object index in the trailer (last 32 bytes:
        // bytes 16...23 are the big-endian top-object index) to point far
        // out of range.
        let trailerStart = data.count - 32
        for offset in 16..<24 {
            data[trailerStart + offset] = 0xFF
        }
        guard case .invalid(.malformedBinaryPlist) = BinaryPlistParser.parse(data, limits: .default) else {
            return XCTFail("expected malformedBinaryPlist for an out-of-range top object index")
        }
    }

    func testBinaryPlistWithHugeDeclaredObjectCountIsRejected() throws {
        var bytes = Array("bplist00".utf8)
        // A minimal-looking but obviously-too-small file claiming an
        // enormous object count in its trailer — this is the
        // decompression-bomb shape: tiny file, huge claimed structure.
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 8))
        var trailer = [UInt8](repeating: 0, count: 32)
        trailer[6] = 1 // offsetIntSize
        trailer[7] = 1 // objectRefSize
        // numObjects = a huge number, far beyond any reasonable preview limit
        let hugeCount: UInt64 = 0x0000_0100_0000_0000
        for i in 0..<8 {
            trailer[8 + i] = UInt8((hugeCount >> (8 * (7 - i))) & 0xFF)
        }
        bytes.append(contentsOf: trailer)
        guard case .invalid(.malformedBinaryPlist) = BinaryPlistParser.parse(Data(bytes), limits: .default) else {
            return XCTFail("expected a huge declared object count to be rejected before any allocation")
        }
    }

    func testBinaryPlistCyclicArrayReferenceIsRejectedNotInfiniteLoop() throws {
        // Hand-build the smallest possible binary plist whose single
        // array object references itself, which a naive recursive
        // decoder would loop on forever.
        var objectTable: [UInt8] = []
        // Object 0: an array of length 1 referencing object 0 itself.
        objectTable.append(0xA1) // array, count 1
        objectTable.append(0x00) // ref to object 0

        var bytes = Array("bplist00".utf8)
        let objectOffset = bytes.count
        bytes.append(contentsOf: objectTable)

        let offsetTableOffset = bytes.count
        bytes.append(UInt8(objectOffset)) // one offset-table entry, 1 byte wide

        var trailer = [UInt8](repeating: 0, count: 32)
        trailer[6] = 1 // offsetIntSize
        trailer[7] = 1 // objectRefSize
        func writeUInt64(_ value: UInt64, at index: Int) {
            for i in 0..<8 {
                trailer[index + i] = UInt8((value >> (8 * (7 - i))) & 0xFF)
            }
        }
        writeUInt64(1, at: 8) // numObjects
        writeUInt64(0, at: 16) // topObject
        writeUInt64(UInt64(offsetTableOffset), at: 24) // offsetTableOffset
        bytes.append(contentsOf: trailer)

        guard case .invalid(.malformedBinaryPlist(let reason)) = BinaryPlistParser.parse(Data(bytes), limits: .default) else {
            return XCTFail("expected a cyclic object reference to be rejected, not looped forever")
        }
        XCTAssertTrue(reason.contains("cyclic"), "diagnostic should explain the cycle, got: \(reason)")
    }

    func testEmptyDataIsNotAPropertyList() {
        guard case .invalid(.notAPropertyList) = BinaryPlistParser.parse(Data(), limits: .default) else {
            return XCTFail("expected notAPropertyList for empty data")
        }
    }
}
