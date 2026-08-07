import Foundation

/// The image formats Kod's built-in preview recognizes (SPEC 10.2): PNG,
/// JPEG, GIF, HEIC, TIFF, and SVG. Detected from real file content (magic
/// bytes for the raster formats, a sniffed `<svg`/`<?xml` root element for
/// SVG) — never from a path extension alone.
public enum ImageFormat: String, CaseIterable, Equatable, Sendable {
    case png
    case jpeg
    case gif
    case heic
    case tiff
    case svg

    /// Detects a format from real file bytes. Returns `nil` for anything
    /// that does not match one of the six recognized signatures, in which
    /// case Kod must not attempt an image preview at all (falling back to
    /// the plain-text/code viewer instead of guessing).
    public static func detect(fromPrefixBytes bytes: Data) -> ImageFormat? {
        let prefix = Array(bytes.prefix(64))
        guard !prefix.isEmpty else {
            return nil
        }

        if prefix.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return .png
        }
        if prefix.starts(with: [0xFF, 0xD8, 0xFF]) {
            return .jpeg
        }
        if prefix.starts(with: Array("GIF87a".utf8)) || prefix.starts(with: Array("GIF89a".utf8)) {
            return .gif
        }
        if prefix.starts(with: [0x49, 0x49, 0x2A, 0x00]) || prefix.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return .tiff
        }
        if prefix.count >= 12,
           prefix[4] == UInt8(ascii: "f"), prefix[5] == UInt8(ascii: "t"),
           prefix[6] == UInt8(ascii: "y"), prefix[7] == UInt8(ascii: "p") {
            let brand = String(decoding: prefix[8..<12], as: UTF8.self)
            if Self.heicBrands.contains(brand) {
                return .heic
            }
        }
        if looksLikeSVG(bytes) {
            return .svg
        }
        return nil
    }

    private static let heicBrands: Set<String> = [
        "heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs", "mif1", "msf1"
    ]

    /// SVG has no fixed magic bytes (it is XML text, optionally preceded by
    /// a UTF-8 BOM or `<?xml ...?>` prologue and/or comments), so detection
    /// sniffs a bounded text prefix for a real `<svg` root element rather
    /// than trusting any single byte pattern.
    private static func looksLikeSVG(_ data: Data) -> Bool {
        let prefix = data.prefix(4_096)
        guard let text = String(data: prefix, encoding: .utf8) else {
            return false
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<") else {
            return false
        }
        return text.range(of: "<svg", options: [.caseInsensitive]) != nil
    }

    public var displayName: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .gif: "GIF"
        case .heic: "HEIC"
        case .tiff: "TIFF"
        case .svg: "SVG"
        }
    }

    /// Whether ImageIO decodes this format directly (all but `svg`, which
    /// Kod sanitizes and rasterizes through a dedicated, script-free path
    /// instead — see `SVGDocument`).
    public var usesImageIODecoding: Bool {
        self != .svg
    }
}
