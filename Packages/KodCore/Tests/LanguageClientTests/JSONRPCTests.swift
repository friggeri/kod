import Foundation
import XCTest
@testable import LanguageClient

final class JSONRPCFramingTests: XCTestCase {
    func testDecodesASingleWholeMessage() throws {
        var decoder = JSONRPCFramingDecoder()
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"test"}"#.utf8)
        let framed = JSONRPCFramingEncoder.frame(body)

        let messages = try decoder.consume(framed)
        XCTAssertEqual(messages, [body])
    }

    func testDecodesMessageDeliveredAcrossManyByteAtATimeFragments() throws {
        var decoder = JSONRPCFramingDecoder()
        let body = Data(#"{"jsonrpc":"2.0","id":42,"method":"fragmented"}"#.utf8)
        let framed = JSONRPCFramingEncoder.frame(body)

        var received: [Data] = []
        for byte in framed {
            received.append(contentsOf: try decoder.consume(Data([byte])))
        }
        XCTAssertEqual(received, [body])
    }

    func testDecodesTwoMessagesDeliveredBackToBackInOneChunk() throws {
        var decoder = JSONRPCFramingDecoder()
        let first = Data(#"{"jsonrpc":"2.0","id":1,"method":"a"}"#.utf8)
        let second = Data(#"{"jsonrpc":"2.0","id":2,"method":"b"}"#.utf8)
        var combined = JSONRPCFramingEncoder.frame(first)
        combined.append(JSONRPCFramingEncoder.frame(second))

        let messages = try decoder.consume(combined)
        XCTAssertEqual(messages, [first, second])
    }

    func testDecodesMessageSplitExactlyAtTheHeaderBodyBoundary() throws {
        var decoder = JSONRPCFramingDecoder()
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"split"}"#.utf8)
        let framed = JSONRPCFramingEncoder.frame(body)
        let headerEnd = framed.count - body.count

        var received: [Data] = []
        received.append(contentsOf: try decoder.consume(framed.prefix(headerEnd)))
        XCTAssertTrue(received.isEmpty)
        received.append(contentsOf: try decoder.consume(framed.suffix(from: headerEnd)))
        XCTAssertEqual(received, [body])
    }

    func testDecodesMessageWithBodySplitMidway() throws {
        var decoder = JSONRPCFramingDecoder()
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"midway-split","params":{"x":1}}"#.utf8)
        let framed = JSONRPCFramingEncoder.frame(body)
        let splitPoint = framed.count - (body.count / 2)

        var received: [Data] = []
        received.append(contentsOf: try decoder.consume(framed.prefix(splitPoint)))
        XCTAssertTrue(received.isEmpty)
        received.append(contentsOf: try decoder.consume(framed.suffix(from: splitPoint)))
        XCTAssertEqual(received, [body])
    }

    func testRejectsAnOversizedDeclaredContentLength() {
        var decoder = JSONRPCFramingDecoder(maxMessageByteCount: 1_024)
        let header = Data("Content-Length: 999999999\r\n\r\n".utf8)
        XCTAssertThrowsError(try decoder.consume(header)) { error in
            guard case JSONRPCFramingDecoder.ParseError.messageTooLarge(let declared, let limit) = error else {
                XCTFail("Expected messageTooLarge, got \(error)")
                return
            }
            XCTAssertEqual(declared, 999_999_999)
            XCTAssertEqual(limit, 1_024)
        }
    }

    func testRejectsANonNumericContentLengthHeader() {
        var decoder = JSONRPCFramingDecoder()
        let header = Data("Content-Length: notanumber\r\n\r\n".utf8)
        XCTAssertThrowsError(try decoder.consume(header)) { error in
            guard case JSONRPCFramingDecoder.ParseError.invalidContentLengthHeader = error else {
                XCTFail("Expected invalidContentLengthHeader, got \(error)")
                return
            }
        }
    }

    func testRejectsAHeaderBlockThatNeverTerminates() {
        var decoder = JSONRPCFramingDecoder(maxHeaderByteCount: 64)
        let junk = Data(String(repeating: "x", count: 128).utf8)
        XCTAssertThrowsError(try decoder.consume(junk)) { error in
            guard case JSONRPCFramingDecoder.ParseError.headerTooLarge = error else {
                XCTFail("Expected headerTooLarge, got \(error)")
                return
            }
        }
    }

    func testIgnoresEmptyInput() throws {
        var decoder = JSONRPCFramingDecoder()
        XCTAssertEqual(try decoder.consume(Data()), [])
    }
}

final class JSONRPCMessageTests: XCTestCase {
    private struct ConcurrentPayload: Codable, Equatable, Sendable {
        let enabled: Bool
        let languageId: String
        let index: Int
    }

    func testRoundTripsARequest() throws {
        let message = JSONRPCMessage(kind: .request(id: .number(7), method: "textDocument/hover", params: .object(["x": .number(1)])))
        let data = try message.encoded()
        let decoded = try JSONRPCMessage.decode(from: data)

        guard case .request(let id, let method, let params) = decoded.kind else {
            return XCTFail("Expected .request")
        }
        XCTAssertEqual(id, .number(7))
        XCTAssertEqual(method, "textDocument/hover")
        XCTAssertEqual(params, .object(["x": .number(1)]))
    }

    func testRoundTripsANotification() throws {
        let message = JSONRPCMessage(kind: .notification(method: "textDocument/didOpen", params: .null))
        let data = try message.encoded()
        let decoded = try JSONRPCMessage.decode(from: data)

        guard case .notification(let method, _) = decoded.kind else {
            return XCTFail("Expected .notification")
        }
        XCTAssertEqual(method, "textDocument/didOpen")
    }

    func testRoundTripsASuccessResponse() throws {
        let message = JSONRPCMessage(kind: .response(id: .string("abc"), result: .bool(true), error: nil))
        let data = try message.encoded()
        let decoded = try JSONRPCMessage.decode(from: data)

        guard case .response(let id, let result, let error) = decoded.kind else {
            return XCTFail("Expected .response")
        }
        XCTAssertEqual(id, .string("abc"))
        XCTAssertEqual(result, .bool(true))
        XCTAssertNil(error)
    }

    func testRoundTripsAnErrorResponse() throws {
        let message = JSONRPCMessage(
            kind: .response(id: .number(1), result: nil, error: .methodNotFound("workspace/executeCommand"))
        )
        let data = try message.encoded()
        let decoded = try JSONRPCMessage.decode(from: data)

        guard case .response(_, _, let error) = decoded.kind else {
            return XCTFail("Expected .response")
        }
        XCTAssertEqual(error?.code, JSONRPCErrorCode.methodNotFound)
    }

    func testPreservesAnExplicitNullResponseResult() throws {
        let data = Data(#"{"jsonrpc":"2.0","id":1,"result":null}"#.utf8)
        let decoded = try JSONRPCMessage.decode(from: data)

        guard case .response(let id, let result, let error) = decoded.kind else {
            return XCTFail("Expected .response")
        }
        XCTAssertEqual(id, .number(1))
        XCTAssertEqual(result, .null)
        XCTAssertNil(error)
    }

    func testRejectsAnUnsupportedJSONRPCVersion() {
        let data = Data(#"{"jsonrpc":"1.0","id":1,"method":"x"}"#.utf8)
        XCTAssertThrowsError(try JSONRPCMessage.decode(from: data)) { error in
            guard case JSONRPCMessageError.unsupportedJSONRPCVersion(let version) = error else {
                XCTFail("Expected unsupportedJSONRPCVersion, got \(error)")
                return
            }
            XCTAssertEqual(version, "1.0")
        }
    }

    func testDecodingMalformedJSONThrowsRatherThanCrashing() {
        let data = Data("not json at all".utf8)
        XCTAssertThrowsError(try JSONRPCMessage.decode(from: data))
    }

    func testConcurrentJSONValueRoundTripsUseIndependentCoders() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<1_000 {
                group.addTask {
                    let expected = ConcurrentPayload(
                        enabled: index.isMultiple(of: 2),
                        languageId: "rust",
                        index: index
                    )
                    let value = try JSONValue.encoding(expected)
                    let decoded = try value.decoding(as: ConcurrentPayload.self)
                    XCTAssertEqual(decoded, expected)
                }
            }
            try await group.waitForAll()
        }
    }

    func testEncodesTextDocumentParamsWithSingleValueURI() throws {
        let params = HoverParams(
            textDocument: TextDocumentIdentifier(
                uri: DocumentURI(stringValue: "file:///tmp/example.rs")
            ),
            position: LSPPosition(line: 3, character: 7)
        )

        let value = try JSONValue.encoding(params)

        guard case .object(let object) = value,
              case .object(let textDocument)? = object["textDocument"] else {
            return XCTFail("Expected encoded textDocument object")
        }
        XCTAssertEqual(textDocument["uri"], .string("file:///tmp/example.rs"))
    }

    func testEncodesRustDidOpenParams() throws {
        let params = DidOpenTextDocumentParams(
            textDocument: TextDocumentItem(
                uri: DocumentURI(stringValue: "file:///tmp/example.rs"),
                languageId: "rust",
                version: 1,
                text: "pub fn greet(name: &str) -> String {\n    format!(\"Hello, {name}!\")\n}\n"
            )
        )

        let value = try JSONValue.encoding(params)

        guard case .object(let object) = value,
              case .object(let textDocument)? = object["textDocument"] else {
            return XCTFail("Expected encoded textDocument object")
        }
        XCTAssertEqual(textDocument["languageId"], .string("rust"))
        XCTAssertEqual(textDocument["uri"], .string("file:///tmp/example.rs"))
    }
}
