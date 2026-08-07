import Foundation

/// Ripgrep's `--json` protocol represents any textual field as either
/// `{"text": "..."}` for valid UTF-8, or `{"bytes": "<base64>"}` when the
/// raw bytes are not valid UTF-8 (e.g. binary-looking content). Decoding
/// both into one type keeps every call site UTF-8-safe instead of assuming
/// `text` is always present.
struct RipgrepTextOrBytes: Decodable {
    let text: String?
    let base64Bytes: String?

    private enum CodingKeys: String, CodingKey {
        case text
        case base64Bytes = "bytes"
    }

    /// The exact original bytes, decoding `text` as UTF-8 or `bytes` as
    /// base64. Returns `nil` only if the payload is malformed (neither key
    /// present, or invalid base64) — callers treat that as malformed output.
    var rawBytes: Data? {
        if let text {
            return Data(text.utf8)
        }
        if let base64Bytes {
            return Data(base64Encoded: base64Bytes)
        }
        return nil
    }

    var isValidUTF8: Bool {
        text != nil
    }
}

struct RipgrepSubmatch: Decodable {
    let match: RipgrepTextOrBytes
    let start: Int
    let end: Int
}

struct RipgrepMatchData: Decodable {
    let path: RipgrepTextOrBytes
    let lines: RipgrepTextOrBytes
    let lineNumber: Int
    let submatches: [RipgrepSubmatch]

    private enum CodingKeys: String, CodingKey {
        case path, lines, submatches
        case lineNumber = "line_number"
    }
}

struct RipgrepMatchMessage: Decodable {
    let data: RipgrepMatchData
}

/// Only the `type` discriminator is decoded up front; the full payload for
/// that type is decoded separately from the same line once the type is
/// known, since `begin`/`end`/`summary` messages carry no match data Kod
/// needs.
struct RipgrepEnvelope: Decodable {
    let type: String
}
