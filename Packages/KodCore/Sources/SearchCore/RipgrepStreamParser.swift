import Foundation

enum RipgrepLine: Equatable {
    case begin
    case match(
        absolutePath: String,
        lineNumber: Int,
        lineText: String,
        lineIsValidUTF8: Bool,
        ranges: [SearchMatchRange]
    )
    case end
    case summary
}

/// Incrementally decodes ripgrep's `--json` newline-delimited protocol from
/// raw stdout chunks, bounding the amount of undecoded data ever buffered so
/// a pathological or hostile single line cannot grow memory without limit
/// (SPEC 8.2: "Search subprocess output is parsed incrementally and bounded
/// to prevent unbounded memory growth").
struct RipgrepStreamParser {
    enum ParseError: Error, Equatable {
        case lineExceedsBufferLimit(byteCount: Int)
        case invalidJSON(String)
        case invalidTextOrBytesPayload(String)
    }

    private var buffer = Data()
    private let maxLineByteCount: Int
    private let decoder = JSONDecoder()

    init(maxLineByteCount: Int = 4 * 1_024 * 1_024) {
        self.maxLineByteCount = maxLineByteCount
    }

    /// Feeds one chunk of raw stdout bytes and returns every complete
    /// `--json` line decoded from it (a chunk may contain zero, one, or
    /// many complete lines, and a line may span multiple chunks).
    mutating func consume(_ chunk: Data) throws -> [RipgrepLine] {
        buffer.append(chunk)

        var results: [RipgrepLine] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            let decoded = try decodeLine(Data(lineData))
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            if let decoded {
                results.append(decoded)
            }
        }

        if buffer.count > maxLineByteCount {
            throw ParseError.lineExceedsBufferLimit(byteCount: buffer.count)
        }

        return results
    }

    /// Call once the process has exited to surface a final unterminated
    /// line, if any (well-behaved `rg` always ends every line with `\n`, so
    /// a non-empty leftover buffer at process exit is itself a
    /// malformed-output signal rather than a line to decode).
    mutating func finish() throws {
        guard !buffer.isEmpty else {
            return
        }
        let leftover = buffer
        buffer.removeAll()
        throw ParseError.invalidJSON(
            "Unterminated trailing output (\(leftover.count) bytes)"
        )
    }

    private func decodeLine(_ lineData: Data) throws -> RipgrepLine? {
        guard !lineData.isEmpty else {
            return nil
        }

        let envelope: RipgrepEnvelope
        do {
            envelope = try decoder.decode(RipgrepEnvelope.self, from: lineData)
        } catch {
            throw ParseError.invalidJSON(describeUndecodableLine(lineData))
        }

        switch envelope.type {
        case "begin":
            return .begin
        case "end":
            return .end
        case "summary":
            return .summary
        case "context":
            // Kod never requests context lines (-A/-B/-C); ignore defensively.
            return nil
        case "match":
            return try decodeMatch(lineData)
        default:
            throw ParseError.invalidJSON("Unknown message type '\(envelope.type)'")
        }
    }

    private func decodeMatch(_ lineData: Data) throws -> RipgrepLine {
        let message: RipgrepMatchMessage
        do {
            message = try decoder.decode(RipgrepMatchMessage.self, from: lineData)
        } catch {
            throw ParseError.invalidJSON(describeUndecodableLine(lineData))
        }

        guard let pathBytes = message.data.path.rawBytes,
              let absolutePath = String(data: pathBytes, encoding: .utf8) else {
            throw ParseError.invalidTextOrBytesPayload(describeUndecodableLine(lineData))
        }
        guard let lineBytes = message.data.lines.rawBytes else {
            throw ParseError.invalidTextOrBytesPayload(describeUndecodableLine(lineData))
        }

        var ranges: [SearchMatchRange] = []
        ranges.reserveCapacity(message.data.submatches.count)
        for submatch in message.data.submatches {
            guard submatch.start >= 0, submatch.end >= submatch.start else {
                throw ParseError.invalidTextOrBytesPayload(describeUndecodableLine(lineData))
            }
            ranges.append(SearchMatchRange(utf8Range: submatch.start..<submatch.end))
        }

        // Both the valid- and invalid-UTF-8 cases decode with `UTF8.self`:
        // valid content decodes exactly, while invalid content decodes
        // lossily (U+FFFD substitution) for display only. `lineIsValidUTF8`
        // tells callers which case they are in.
        let lineText = String(decoding: lineBytes, as: UTF8.self)

        return .match(
            absolutePath: absolutePath,
            lineNumber: message.data.lineNumber,
            lineText: stripTrailingNewline(lineText),
            lineIsValidUTF8: message.data.lines.isValidUTF8,
            ranges: ranges
        )
    }

    private func stripTrailingNewline(_ text: String) -> String {
        var text = text
        if text.hasSuffix("\n") {
            text.removeLast()
        }
        if text.hasSuffix("\r") {
            text.removeLast()
        }
        return text
    }

    private func describeUndecodableLine(_ data: Data) -> String {
        let preview = String(decoding: data.prefix(200), as: UTF8.self)
        return data.count > 200 ? "\(preview)… (\(data.count) bytes)" : preview
    }
}
