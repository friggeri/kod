import Foundation

/// Incrementally parses the LSP base protocol's `Content-Length`-framed
/// message stream out of arbitrarily fragmented byte chunks (a single
/// `read()` from a pipe may deliver part of a header, part of a body, or
/// several whole messages back to back). Never assumes a chunk boundary
/// lines up with a message boundary.
public struct JSONRPCFramingDecoder {
    public enum ParseError: Error, Equatable {
        /// The header block exceeded `maxHeaderByteCount` without a
        /// terminating `\r\n\r\n`, which means the peer is either not
        /// speaking the protocol or is hostile/broken.
        case headerTooLarge
        /// `Content-Length` was absent, non-numeric, or negative.
        case invalidContentLengthHeader(String)
        /// The declared body size exceeds `maxMessageByteCount`. Kod
        /// refuses to allocate unbounded memory for a single message.
        case messageTooLarge(declared: Int, limit: Int)
    }

    private enum State {
        case readingHeader
        case readingBody(contentLength: Int)
    }

    public let maxHeaderByteCount: Int
    public let maxMessageByteCount: Int

    private var buffer = Data()
    private var state = State.readingHeader

    public init(maxHeaderByteCount: Int = 8 * 1_024, maxMessageByteCount: Int = 64 * 1_024 * 1_024) {
        self.maxHeaderByteCount = maxHeaderByteCount
        self.maxMessageByteCount = maxMessageByteCount
    }

    /// Feeds newly-read bytes into the decoder and returns every complete
    /// message body (the raw JSON bytes, header stripped) that became
    /// available. Bytes belonging to a still-incomplete message are
    /// retained internally for the next call.
    public mutating func consume(_ data: Data) throws -> [Data] {
        guard !data.isEmpty else {
            return []
        }
        buffer.append(data)

        var messages: [Data] = []
        while true {
            switch state {
            case .readingHeader:
                guard let headerEnd = Self.range(ofHeaderTerminator: buffer) else {
                    if buffer.count > maxHeaderByteCount {
                        throw ParseError.headerTooLarge
                    }
                    return messages
                }
                let headerBytes = buffer[buffer.startIndex..<headerEnd.lowerBound]
                let headerText = String(decoding: headerBytes, as: UTF8.self)
                let contentLength = try Self.contentLength(fromHeaderText: headerText)
                guard contentLength <= maxMessageByteCount else {
                    throw ParseError.messageTooLarge(declared: contentLength, limit: maxMessageByteCount)
                }
                buffer.removeSubrange(buffer.startIndex..<headerEnd.upperBound)
                state = .readingBody(contentLength: contentLength)

            case .readingBody(let contentLength):
                guard buffer.count >= contentLength else {
                    return messages
                }
                let bodyEnd = buffer.index(buffer.startIndex, offsetBy: contentLength)
                let body = Data(buffer[buffer.startIndex..<bodyEnd])
                buffer.removeSubrange(buffer.startIndex..<bodyEnd)
                state = .readingHeader
                messages.append(body)
            }
        }
    }

    /// Bytes still buffered awaiting more input; only ever non-empty
    /// between reads, never persisted across the encoder's lifetime.
    public var pendingByteCount: Int {
        buffer.count
    }

    private static func range(ofHeaderTerminator data: Data) -> Range<Data.Index>? {
        let terminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        guard data.count >= terminator.count else {
            return nil
        }
        var index = data.startIndex
        let limit = data.index(data.endIndex, offsetBy: -terminator.count + 1)
        while index < limit {
            if data[index] == terminator[0],
               data[data.index(index, offsetBy: 1)] == terminator[1],
               data[data.index(index, offsetBy: 2)] == terminator[2],
               data[data.index(index, offsetBy: 3)] == terminator[3] {
                let end = data.index(index, offsetBy: 4)
                return index..<end
            }
            index = data.index(after: index)
        }
        return nil
    }

    private static func contentLength(fromHeaderText text: String) throws -> Int {
        for line in text.split(separator: "\r\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else {
                continue
            }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard name.caseInsensitiveCompare("Content-Length") == .orderedSame else {
                continue
            }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard let length = Int(value), length >= 0 else {
                throw ParseError.invalidContentLengthHeader(value)
            }
            return length
        }
        throw ParseError.invalidContentLengthHeader(text)
    }
}

/// Frames one message body for the wire: `Content-Length: N\r\n\r\n` plus
/// the raw bytes, exactly per the LSP base protocol.
public enum JSONRPCFramingEncoder {
    public static func frame(_ body: Data) -> Data {
        var framed = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        framed.append(body)
        return framed
    }
}
