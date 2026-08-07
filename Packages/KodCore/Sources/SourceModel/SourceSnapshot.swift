import Foundation

public enum SourceEncoding: Equatable, Sendable {
    case utf8
    case utf16LittleEndian
    case utf16BigEndian
    case utf32LittleEndian
    case utf32BigEndian
    case fallback(rawValue: UInt)

    public var displayName: String {
        switch self {
        case .utf8:
            "UTF-8"
        case .utf16LittleEndian:
            "UTF-16 LE"
        case .utf16BigEndian:
            "UTF-16 BE"
        case .utf32LittleEndian:
            "UTF-32 LE"
        case .utf32BigEndian:
            "UTF-32 BE"
        case .fallback(let rawValue):
            "Encoding \(rawValue)"
        }
    }

    fileprivate var byteOrderMarkLength: Int {
        switch self {
        case .utf8:
            3
        case .utf16LittleEndian, .utf16BigEndian:
            2
        case .utf32LittleEndian, .utf32BigEndian:
            4
        case .fallback:
            0
        }
    }
}

public enum SourceLineEnding: String, Equatable, Sendable {
    case none
    case lineFeed
    case carriageReturnLineFeed
    case carriageReturn
    case mixed
}

public enum SourceSafetyModeReason: Equatable, Sendable {
    case fileSize(Int)
    case lineLength(Int)

    public var message: String {
        switch self {
        case .fileSize(let size):
            "Safety mode: this file is \(size) bytes, above the 10 MB full-fidelity limit."
        case .lineLength(let length):
            "Safety mode: this file contains a line longer than \(length) UTF-8 bytes."
        }
    }
}

public enum LSPPositionEncoding: Equatable, Sendable {
    case utf8
    case utf16
}

public struct SourcePosition: Equatable, Sendable {
    public let line: Int
    public let character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }
}

public enum SourceSnapshotError: Error, Equatable {
    case notRegularFile(URL)
    case unsupportedEncoding(URL)
    case invalidLine(Int)
    case invalidCharacter(line: Int, character: Int)
    case invalidUTF8Offset(Int)
    case invalidCharacterBoundary(Int)
    case fallbackEncodingFailed(UInt)
}

public struct SourceSnapshot: Sendable {
    public let url: URL
    public let version: Int
    public let originalData: Data
    public let modificationDate: Date?
    public let encoding: SourceEncoding
    public let lineEnding: SourceLineEnding
    public let text: String
    public let safetyModeReason: SourceSafetyModeReason?

    private let normalizedUTF8: Data
    private let lineStarts: [Int]
    private let lineEnds: [Int]
    private let longestLineLength: Int
    private let hadByteOrderMark: Bool

    public var lineCount: Int {
        lineStarts.count
    }

    public var utf8Count: Int {
        normalizedUTF8.count
    }

    public var longestLineUTF8Length: Int {
        longestLineLength
    }

    public init(
        text: String,
        url: URL = URL(fileURLWithPath: "/in-memory.swift"),
        version: Int = 1
    ) {
        let utf8 = Data(text.utf8)
        let index = SourceLineIndex(utf8: utf8)

        self.url = url
        self.version = version
        self.originalData = utf8
        self.modificationDate = nil
        self.encoding = .utf8
        self.lineEnding = index.lineEnding
        self.text = text
        self.safetyModeReason = Self.safetyMode(
            fileSize: utf8.count,
            longestLine: index.longestLineLength
        )
        self.normalizedUTF8 = utf8
        self.lineStarts = index.starts
        self.lineEnds = index.ends
        self.longestLineLength = index.longestLineLength
        self.hadByteOrderMark = false
    }

    fileprivate init(
        url: URL,
        version: Int,
        originalData: Data,
        modificationDate: Date?,
        encoding: SourceEncoding,
        text: String,
        normalizedUTF8: Data,
        hadByteOrderMark: Bool
    ) {
        let index = SourceLineIndex(utf8: normalizedUTF8)

        self.url = url
        self.version = version
        self.originalData = originalData
        self.modificationDate = modificationDate
        self.encoding = encoding
        self.lineEnding = index.lineEnding
        self.text = text
        self.safetyModeReason = Self.safetyMode(
            fileSize: originalData.count,
            longestLine: index.longestLineLength
        )
        self.normalizedUTF8 = normalizedUTF8
        self.lineStarts = index.starts
        self.lineEnds = index.ends
        self.longestLineLength = index.longestLineLength
        self.hadByteOrderMark = hadByteOrderMark
    }

    /// The full normalized UTF-8 byte buffer backing this snapshot. Exposed
    /// so consumers such as `SyntaxCore` can feed the exact bytes that
    /// `utf8RangeForLine`/`text(inUTF8Range:)` address into a parser.
    /// `Data` is copy-on-write, so retaining this is O(1) until mutated,
    /// which callers never do (`SourceSnapshot` is immutable).
    public var utf8Data: Data {
        normalizedUTF8
    }

    public func line(at index: Int) -> String? {
        guard let range = utf8RangeForLine(index) else {
            return nil
        }
        return String(decoding: normalizedUTF8[range], as: UTF8.self)
    }

    public func utf8RangeForLine(_ line: Int) -> Range<Int>? {
        guard lineStarts.indices.contains(line), lineEnds.indices.contains(line) else {
            return nil
        }
        return lineStarts[line]..<lineEnds[line]
    }

    public func text(inUTF8Range range: Range<Int>) throws -> String {
        guard range.lowerBound >= 0, range.upperBound <= normalizedUTF8.count else {
            throw SourceSnapshotError.invalidUTF8Offset(range.upperBound)
        }
        guard isUTF8Boundary(range.lowerBound), isUTF8Boundary(range.upperBound) else {
            throw SourceSnapshotError.invalidCharacterBoundary(range.lowerBound)
        }
        return String(decoding: normalizedUTF8[range], as: UTF8.self)
    }

    public func utf8Offset(
        for position: SourcePosition,
        encoding positionEncoding: LSPPositionEncoding
    ) throws -> Int {
        guard let range = utf8RangeForLine(position.line) else {
            throw SourceSnapshotError.invalidLine(position.line)
        }
        guard position.character >= 0 else {
            throw SourceSnapshotError.invalidCharacter(
                line: position.line,
                character: position.character
            )
        }

        switch positionEncoding {
        case .utf8:
            let offset = range.lowerBound + position.character
            guard offset <= range.upperBound else {
                throw SourceSnapshotError.invalidCharacter(
                    line: position.line,
                    character: position.character
                )
            }
            guard isUTF8Boundary(offset) else {
                throw SourceSnapshotError.invalidCharacterBoundary(offset)
            }
            return offset

        case .utf16:
            let line = String(decoding: normalizedUTF8[range], as: UTF8.self)
            guard position.character <= line.utf16.count else {
                throw SourceSnapshotError.invalidCharacter(
                    line: position.line,
                    character: position.character
                )
            }

            let utf16Index = line.utf16.index(
                line.utf16.startIndex,
                offsetBy: position.character
            )
            guard let stringIndex = String.Index(utf16Index, within: line),
                  let utf8Index = stringIndex.samePosition(in: line.utf8) else {
                throw SourceSnapshotError.invalidCharacterBoundary(position.character)
            }

            return range.lowerBound + line.utf8.distance(
                from: line.utf8.startIndex,
                to: utf8Index
            )
        }
    }

    public func position(
        forUTF8Offset offset: Int,
        encoding positionEncoding: LSPPositionEncoding
    ) throws -> SourcePosition {
        guard offset >= 0, offset <= normalizedUTF8.count else {
            throw SourceSnapshotError.invalidUTF8Offset(offset)
        }
        guard isUTF8Boundary(offset) else {
            throw SourceSnapshotError.invalidCharacterBoundary(offset)
        }

        let line = lineIndex(containingUTF8Offset: offset)
        let contentEnd = lineEnds[line]
        let clampedOffset = min(offset, contentEnd)
        let localUTF8Offset = clampedOffset - lineStarts[line]

        switch positionEncoding {
        case .utf8:
            return SourcePosition(line: line, character: localUTF8Offset)
        case .utf16:
            let prefixRange = lineStarts[line]..<clampedOffset
            let prefix = String(decoding: normalizedUTF8[prefixRange], as: UTF8.self)
            return SourcePosition(line: line, character: prefix.utf16.count)
        }
    }

    public func globalUTF16Offset(forUTF8Offset offset: Int) throws -> Int {
        guard offset >= 0, offset <= normalizedUTF8.count else {
            throw SourceSnapshotError.invalidUTF8Offset(offset)
        }
        guard isUTF8Boundary(offset) else {
            throw SourceSnapshotError.invalidCharacterBoundary(offset)
        }

        let prefix = String(decoding: normalizedUTF8[0..<offset], as: UTF8.self)
        return prefix.utf16.count
    }

    /// The inverse of `globalUTF16Offset(forUTF8Offset:)`: maps a document-
    /// wide UTF-16 offset (the unit `NSRange`/`NSAccessibility` APIs use)
    /// back to a validated UTF-8 byte offset. Needed so accessibility
    /// clients (e.g. VoiceOver setting `accessibilitySelectedTextRange`)
    /// can round-trip a UTF-16 range they were given back into the byte
    /// offsets `selectUTF8Range`/`text(inUTF8Range:)` require.
    ///
    /// Walks `unicodeScalars` directly (accumulating each scalar's UTF-16
    /// and UTF-8 code-unit widths) rather than going through
    /// `String.Index(_:within:)`, which snaps to *extended grapheme
    /// cluster* boundaries, not Unicode scalar boundaries: a base
    /// character immediately followed by one or more combining marks is
    /// one grapheme cluster, so a `utf16Offset` that lands between the
    /// base character and its combining mark is a perfectly valid
    /// scalar/UTF-8 boundary (exactly the kind `globalUTF16Offset(for
    /// UTF8Offset:)` can itself produce for such an offset) but is
    /// *not* a valid `String.Index` under the grapheme-cluster view —
    /// `String.Index(_:within:)` would spuriously return `nil` and this
    /// method would incorrectly throw for a boundary its own forward
    /// direction considers entirely valid. This was caught by
    /// `EncodingPositionFuzzTests`'s round-trip property test against
    /// adversarial Unicode containing combining marks.
    public func globalUTF8Offset(forGlobalUTF16Offset utf16Offset: Int) throws -> Int {
        guard utf16Offset >= 0 else {
            throw SourceSnapshotError.invalidUTF8Offset(utf16Offset)
        }

        let full = String(decoding: normalizedUTF8, as: UTF8.self)
        var remainingUTF16 = utf16Offset
        var utf8ByteOffset = 0
        for scalar in full.unicodeScalars {
            if remainingUTF16 == 0 {
                return utf8ByteOffset
            }
            let scalarUTF16Width = UTF16.width(scalar)
            guard remainingUTF16 >= scalarUTF16Width else {
                // `utf16Offset` lands inside this scalar's own surrogate
                // pair (only possible for a scalar outside the BMP) —
                // not a valid boundary of any kind, unlike the
                // combining-mark case this rewrite fixes above.
                throw SourceSnapshotError.invalidCharacterBoundary(utf16Offset)
            }
            remainingUTF16 -= scalarUTF16Width
            utf8ByteOffset += UTF8.width(scalar)
        }

        guard remainingUTF16 == 0 else {
            throw SourceSnapshotError.invalidUTF8Offset(utf16Offset)
        }
        return utf8ByteOffset
    }

    public func originalByteOffset(forUTF8Offset offset: Int) throws -> Int {
        guard offset >= 0, offset <= normalizedUTF8.count else {
            throw SourceSnapshotError.invalidUTF8Offset(offset)
        }
        guard isUTF8Boundary(offset) else {
            throw SourceSnapshotError.invalidCharacterBoundary(offset)
        }

        let markLength = hadByteOrderMark ? encoding.byteOrderMarkLength : 0
        if encoding == .utf8 {
            return markLength + offset
        }

        let prefix = String(decoding: normalizedUTF8[0..<offset], as: UTF8.self)
        switch encoding {
        case .utf8:
            return markLength + offset
        case .utf16LittleEndian, .utf16BigEndian:
            return markLength + (prefix.utf16.count * 2)
        case .utf32LittleEndian, .utf32BigEndian:
            return markLength + (prefix.unicodeScalars.count * 4)
        case .fallback(let rawValue):
            let stringEncoding = String.Encoding(rawValue: rawValue)
            guard let encoded = prefix.data(using: stringEncoding) else {
                throw SourceSnapshotError.fallbackEncodingFailed(rawValue)
            }
            return encoded.count
        }
    }

    private func lineIndex(containingUTF8Offset offset: Int) -> Int {
        var lowerBound = 0
        var upperBound = lineStarts.count

        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            if lineStarts[midpoint] <= offset {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }

        return max(0, lowerBound - 1)
    }

    private func isUTF8Boundary(_ offset: Int) -> Bool {
        guard offset > 0, offset < normalizedUTF8.count else {
            return true
        }
        return normalizedUTF8[offset] & 0b1100_0000 != 0b1000_0000
    }

    private static func safetyMode(
        fileSize: Int,
        longestLine: Int
    ) -> SourceSafetyModeReason? {
        let fullFidelityLimit = 10 * 1_024 * 1_024
        if fileSize > fullFidelityLimit {
            return .fileSize(fileSize)
        }
        if longestLine > 100_000 {
            return .lineLength(longestLine)
        }
        return nil
    }
}

public struct SourceSnapshotLoader: Sendable {
    private let fileSystem: any ReadOnlyFileSystem

    public init(fileSystem: any ReadOnlyFileSystem = LocalReadOnlyFileSystem()) {
        self.fileSystem = fileSystem
    }

    public func load(
        url: URL,
        version: Int = 1,
        fallbackEncodingRawValue: UInt? = nil
    ) throws -> SourceSnapshot {
        let payload = try fileSystem.readFile(at: url)
        let decoded = try SourceDecoder.decode(
            payload.data,
            url: url,
            fallbackEncodingRawValue: fallbackEncodingRawValue
        )

        return SourceSnapshot(
            url: url,
            version: version,
            originalData: payload.data,
            modificationDate: payload.modificationDate,
            encoding: decoded.encoding,
            text: decoded.text,
            normalizedUTF8: decoded.normalizedUTF8,
            hadByteOrderMark: decoded.hadByteOrderMark
        )
    }
}

private struct DecodedSource {
    let encoding: SourceEncoding
    let text: String
    let normalizedUTF8: Data
    let hadByteOrderMark: Bool
}

private enum SourceDecoder {
    static func decode(
        _ data: Data,
        url: URL,
        fallbackEncodingRawValue: UInt?
    ) throws -> DecodedSource {
        let bytes = Array(data.prefix(4))

        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return try decodeMarked(
                data,
                markLength: 4,
                stringEncoding: .utf32BigEndian,
                sourceEncoding: .utf32BigEndian
            )
        }
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return try decodeMarked(
                data,
                markLength: 4,
                stringEncoding: .utf32LittleEndian,
                sourceEncoding: .utf32LittleEndian
            )
        }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return try decodeMarked(
                data,
                markLength: 3,
                stringEncoding: .utf8,
                sourceEncoding: .utf8
            )
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return try decodeMarked(
                data,
                markLength: 2,
                stringEncoding: .utf16BigEndian,
                sourceEncoding: .utf16BigEndian
            )
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            return try decodeMarked(
                data,
                markLength: 2,
                stringEncoding: .utf16LittleEndian,
                sourceEncoding: .utf16LittleEndian
            )
        }
        if let text = String(data: data, encoding: .utf8) {
            return DecodedSource(
                encoding: .utf8,
                text: text,
                normalizedUTF8: data,
                hadByteOrderMark: false
            )
        }
        if let fallbackEncodingRawValue {
            let stringEncoding = String.Encoding(rawValue: fallbackEncodingRawValue)
            if let text = String(data: data, encoding: stringEncoding) {
                return DecodedSource(
                    encoding: .fallback(rawValue: fallbackEncodingRawValue),
                    text: text,
                    normalizedUTF8: Data(text.utf8),
                    hadByteOrderMark: false
                )
            }
            throw SourceSnapshotError.fallbackEncodingFailed(fallbackEncodingRawValue)
        }

        throw SourceSnapshotError.unsupportedEncoding(url)
    }

    private static func decodeMarked(
        _ data: Data,
        markLength: Int,
        stringEncoding: String.Encoding,
        sourceEncoding: SourceEncoding
    ) throws -> DecodedSource {
        let content = Data(data.dropFirst(markLength))
        guard let text = String(data: content, encoding: stringEncoding) else {
            throw SourceSnapshotError.fallbackEncodingFailed(stringEncoding.rawValue)
        }
        return DecodedSource(
            encoding: sourceEncoding,
            text: text,
            normalizedUTF8: sourceEncoding == .utf8 ? content : Data(text.utf8),
            hadByteOrderMark: true
        )
    }
}

private struct SourceLineIndex {
    let starts: [Int]
    let ends: [Int]
    let lineEnding: SourceLineEnding
    let longestLineLength: Int

    init(utf8: Data) {
        var starts = [0]
        var ends: [Int] = []
        starts.reserveCapacity(max(1, utf8.count / 32))
        ends.reserveCapacity(max(1, utf8.count / 32))
        var lineFeedCount = 0
        var carriageReturnLineFeedCount = 0
        var carriageReturnCount = 0
        var longestLineLength = 0
        var currentLineStart = 0
        var index = 0

        utf8.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            while index < bytes.count {
                switch bytes[index] {
                case 0x0A:
                    ends.append(index)
                    longestLineLength = max(longestLineLength, index - currentLineStart)
                    starts.append(index + 1)
                    currentLineStart = index + 1
                    lineFeedCount += 1

                case 0x0D:
                    ends.append(index)
                    longestLineLength = max(longestLineLength, index - currentLineStart)
                    if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                        index += 1
                        carriageReturnLineFeedCount += 1
                    } else {
                        carriageReturnCount += 1
                    }
                    starts.append(index + 1)
                    currentLineStart = index + 1

                default:
                    break
                }
                index += 1
            }
        }

        ends.append(utf8.count)
        longestLineLength = max(longestLineLength, utf8.count - currentLineStart)
        self.starts = starts
        self.ends = ends
        self.longestLineLength = longestLineLength

        let kinds = [
            lineFeedCount > 0,
            carriageReturnLineFeedCount > 0,
            carriageReturnCount > 0
        ].filter { $0 }.count

        if kinds > 1 {
            self.lineEnding = .mixed
        } else if carriageReturnLineFeedCount > 0 {
            self.lineEnding = .carriageReturnLineFeed
        } else if carriageReturnCount > 0 {
            self.lineEnding = .carriageReturn
        } else if lineFeedCount > 0 {
            self.lineEnding = .lineFeed
        } else {
            self.lineEnding = .none
        }
    }
}
