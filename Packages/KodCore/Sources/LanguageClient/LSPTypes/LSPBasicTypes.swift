import Foundation

/// A document URI as LSP transmits it: always the string form of a
/// `file://` URL Kod already resolved to an absolute path. Never accepted
/// back from a server without validating it maps to a file Kod actually
/// has open (SPEC 6.3: "validate every returned URI/range/snapshot
/// version before use").
public struct DocumentURI: Codable, Hashable, Sendable {
    public let stringValue: String

    public init(stringValue: String) {
        self.stringValue = stringValue
    }

    public init(fileURL: URL) {
        stringValue = fileURL.absoluteURL.standardizedFileURL.absoluteString
    }

    public var fileURL: URL? {
        guard let url = URL(string: stringValue), url.isFileURL else {
            return nil
        }
        return url
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        stringValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue)
    }
}

/// `line`/`character` are UTF-16 code units by default per LSP 3.17,
/// unless `general.positionEncodings` negotiation selected UTF-8 during
/// `initialize` (SPEC 6.3). `SourceSnapshot.utf8Offset(for:encoding:)`
/// is what actually interprets `character` against the right encoding;
/// this type is just the wire shape.
public struct LSPPosition: Codable, Equatable, Sendable {
    public let line: Int
    public let character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }
}

public struct LSPRange: Codable, Equatable, Sendable {
    public let start: LSPPosition
    public let end: LSPPosition

    public init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }
}

public struct LSPLocation: Codable, Equatable, Sendable {
    public let uri: DocumentURI
    public let range: LSPRange

    public init(uri: DocumentURI, range: LSPRange) {
        self.uri = uri
        self.range = range
    }
}

public struct LSPLocationLink: Codable, Equatable, Sendable {
    public let originSelectionRange: LSPRange?
    public let targetUri: DocumentURI
    public let targetRange: LSPRange
    public let targetSelectionRange: LSPRange
}

public struct TextDocumentIdentifier: Codable, Sendable {
    public let uri: DocumentURI

    public init(uri: DocumentURI) {
        self.uri = uri
    }
}

public struct VersionedTextDocumentIdentifier: Codable, Sendable {
    public let uri: DocumentURI
    public let version: Int

    public init(uri: DocumentURI, version: Int) {
        self.uri = uri
        self.version = version
    }
}

public struct TextDocumentPositionParams: Codable, Sendable {
    public let textDocument: TextDocumentIdentifier
    public let position: LSPPosition

    public init(textDocument: TextDocumentIdentifier, position: LSPPosition) {
        self.textDocument = textDocument
        self.position = position
    }
}

/// LSP's `ProgressToken` is `integer | string`, mirroring `JSONRPCID`.
public typealias ProgressToken = JSONRPCID

public struct WorkDoneProgressParams: Codable, Sendable {
    public let workDoneToken: ProgressToken?

    public init(workDoneToken: ProgressToken?) {
        self.workDoneToken = workDoneToken
    }
}
