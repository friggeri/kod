import Foundation

/// The concrete structured-data format a source was decoded as, detected
/// from real byte content (never a file extension alone — SPEC 10: "dispatch
/// by validated content/UTType rather than extension alone").
public enum StructuredDataFormat: Equatable, Sendable {
    case json
    case xmlPropertyList
    case binaryPropertyList
}

/// A fully-resolved JSON/property-list preview: the exact source bytes (for
/// the raw/source mode), the detected format, and either a parsed tree or a
/// diagnostic explaining exactly why parsing failed (SPEC 10.3: "Invalid
/// data falls back to the source viewer with a parse diagnostic" — never a
/// silently-empty tree standing in for success).
public struct StructuredDocument: Sendable {
    public let format: StructuredDataFormat
    public let sourceData: Data
    public let result: StructuredParseResult

    public init(format: StructuredDataFormat, sourceData: Data, result: StructuredParseResult) {
        self.format = format
        self.sourceData = sourceData
        self.result = result
    }

    public var node: StructuredNode? {
        result.node
    }

    public var diagnostic: StructuredDataDiagnostic? {
        result.diagnostic
    }

    /// Decodes `data` as JSON or a property list, detected from its actual
    /// bytes: `bplist00` magic selects the binary-plist decoder, an
    /// `<?xml`/`<plist` prologue selects the XML-plist decoder, and
    /// anything else is attempted as JSON. `extensionHint` (from the
    /// file's path extension, if any) only ever narrows which detector
    /// runs *first* as a minor optimization — a mismatched hint still
    /// falls through to the other detectors rather than failing outright,
    /// and the final `format` always reflects what the bytes actually
    /// were, never the hint.
    public static func parse(
        _ data: Data,
        extensionHint: StructuredDataFormat? = nil,
        limits: StructuredDataLimits = .default
    ) -> StructuredDocument {
        let looksBinary = data.starts(with: Array("bplist00".utf8))
        let looksXML = XMLPlistParser.looksLikeXMLPlist(data)

        if looksBinary {
            return StructuredDocument(
                format: .binaryPropertyList,
                sourceData: data,
                result: BinaryPlistParser.parse(data, limits: limits)
            )
        }
        if looksXML {
            return StructuredDocument(
                format: .xmlPropertyList,
                sourceData: data,
                result: XMLPlistParser.parse(data, limits: limits)
            )
        }
        return StructuredDocument(
            format: .json,
            sourceData: data,
            result: JSONParser.parse(data, limits: limits)
        )
    }
}
