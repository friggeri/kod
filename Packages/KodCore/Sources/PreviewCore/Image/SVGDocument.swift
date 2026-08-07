import Foundation

/// Why an SVG source was rejected before Kod would ever hand it to a
/// renderer.
public enum SVGDiagnostic: Equatable, Sendable {
    case sourceTooLarge(byteCount: Int, limit: Int)
    case notSVG
    case noRootElement

    public var message: String {
        switch self {
        case .sourceTooLarge(let byteCount, let limit):
            "SVG source is \(byteCount) bytes, above the \(limit)-byte preview limit."
        case .notSVG:
            "Not a recognized SVG document (no <svg> root element)."
        case .noRootElement:
            "SVG document has no readable root <svg> element after sanitization."
        }
    }
}

/// A sanitized, safe-to-rasterize SVG document: the fully-sanitized XML
/// text (guaranteed free of `<script>`, event-handler attributes, and any
/// externally-reachable reference — see `SVGSanitizer`), its intrinsic
/// pixel size (from `width`/`height`/`viewBox` on the root element), and a
/// record of exactly what sanitization removed, so a hostile-input test
/// can assert the mitigation actually fired rather than merely trusting
/// that the output looks safe.
public struct SVGDocument: Equatable, Sendable {
    public let sanitizedXML: String
    public let intrinsicWidth: Double?
    public let intrinsicHeight: Double?
    public let removedConstructs: [String]

    public init(sanitizedXML: String, intrinsicWidth: Double?, intrinsicHeight: Double?, removedConstructs: [String]) {
        self.sanitizedXML = sanitizedXML
        self.intrinsicWidth = intrinsicWidth
        self.intrinsicHeight = intrinsicHeight
        self.removedConstructs = removedConstructs
    }
}

public enum SVGDocumentResult: Equatable, Sendable {
    case valid(SVGDocument)
    case rejected(SVGDiagnostic)

    public var document: SVGDocument? {
        if case .valid(let document) = self {
            return document
        }
        return nil
    }
}

public enum SVGDocumentLoader {
    /// Maximum SVG source size this loader will sanitize at all — bounds
    /// the tokenizer's work independent of its own internal token cap.
    public static let maximumSourceByteCount = 32 * 1_024 * 1_024

    public static func load(_ data: Data) -> SVGDocumentResult {
        guard data.count <= maximumSourceByteCount else {
            return .rejected(.sourceTooLarge(byteCount: data.count, limit: maximumSourceByteCount))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .rejected(.notSVG)
        }
        guard ImageFormat.detect(fromPrefixBytes: data) == .svg else {
            return .rejected(.notSVG)
        }

        let sanitized = SVGSanitizer.sanitize(text)
        guard let (width, height) = intrinsicSize(fromSanitizedXML: sanitized.sanitizedXML) else {
            // Sanitization can legitimately succeed with no explicit
            // width/height/viewBox (SVG permits this; a renderer falls
            // back to a default size), so a missing size alone is not a
            // rejection — only a genuinely absent root element is.
            guard sanitized.sanitizedXML.range(of: "<svg", options: [.caseInsensitive]) != nil else {
                return .rejected(.noRootElement)
            }
            return .valid(SVGDocument(
                sanitizedXML: sanitized.sanitizedXML,
                intrinsicWidth: nil,
                intrinsicHeight: nil,
                removedConstructs: sanitized.removedConstructs
            ))
        }

        return .valid(SVGDocument(
            sanitizedXML: sanitized.sanitizedXML,
            intrinsicWidth: width,
            intrinsicHeight: height,
            removedConstructs: sanitized.removedConstructs
        ))
    }

    private static func intrinsicSize(fromSanitizedXML xml: String) -> (Double, Double)? {
        let tokens = LenientXMLTokenizer.tokenize(xml)
        for token in tokens {
            guard case .startElement(let name, let attributes, _) = token, name.lowercased() == "svg" else {
                continue
            }
            let dict = Dictionary(attributes.map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
            if let widthString = dict["width"], let heightString = dict["height"],
               let width = Double(widthString.filter { $0.isNumber || $0 == "." }),
               let height = Double(heightString.filter { $0.isNumber || $0 == "." }),
               width > 0, height > 0 {
                return (width, height)
            }
            if let viewBox = dict["viewbox"] {
                let components = viewBox.split(separator: " ").compactMap { Double($0) }
                if components.count == 4, components[2] > 0, components[3] > 0 {
                    return (components[2], components[3])
                }
            }
            return nil
        }
        return nil
    }
}
