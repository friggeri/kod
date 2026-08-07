import Foundation

/// Bounds every raster image decode in `PreviewCore` (SPEC 10.2:
/// "Oversized/decompression-bomb safeguards with an explicit error
/// state"). A decompression bomb is a small file that declares enormous
/// pixel dimensions or frame counts; these limits are checked against a
/// format's *declared* properties (read cheaply via
/// `CGImageSourceCopyPropertiesAtIndex`, which does not decode pixel data)
/// before Kod ever asks ImageIO to actually decode a bitmap.
public struct ImageDecodeLimits: Equatable, Sendable {
    /// Maximum source file size this decoder will even open.
    public var maximumSourceByteCount: Int
    /// Maximum width or height of a single frame, in pixels.
    public var maximumDimension: Int
    /// Maximum total pixel count (`width * height`) of a single frame.
    public var maximumPixelCount: Int
    /// Maximum number of frames an animated image (GIF) may have.
    public var maximumFrameCount: Int
    /// Maximum total decoded-bitmap memory budget across every frame,
    /// assuming 4 bytes per pixel (RGBA8). This is the real
    /// decompression-bomb backstop: a GIF within the per-frame pixel-count
    /// limit could still multiply that by thousands of frames.
    public var maximumTotalDecodedByteBudget: Int

    public init(
        maximumSourceByteCount: Int = 100 * 1_024 * 1_024,
        maximumDimension: Int = 20_000,
        maximumPixelCount: Int = 60_000_000,
        maximumFrameCount: Int = 1_024,
        maximumTotalDecodedByteBudget: Int = 512 * 1_024 * 1_024
    ) {
        self.maximumSourceByteCount = maximumSourceByteCount
        self.maximumDimension = maximumDimension
        self.maximumPixelCount = maximumPixelCount
        self.maximumFrameCount = maximumFrameCount
        self.maximumTotalDecodedByteBudget = maximumTotalDecodedByteBudget
    }

    public static let `default` = ImageDecodeLimits()
}

/// Why an image was rejected before or during decode. Every case is a
/// concrete, actionable reason — never a generic failure — matching
/// SPEC 10.2's "Reject malformed/oversized input explicitly".
public enum ImageDecodeDiagnostic: Equatable, Sendable {
    case sourceTooLarge(byteCount: Int, limit: Int)
    case unrecognizedFormat
    case unreadableSource
    case dimensionTooLarge(width: Int, height: Int, limit: Int)
    case pixelCountTooLarge(pixelCount: Int, limit: Int)
    case frameCountTooLarge(frameCount: Int, limit: Int)
    case decodedByteBudgetExceeded(estimatedBytes: Int, limit: Int)
    case decodeFailed(frameIndex: Int)
    case missingDimensions(frameIndex: Int)

    public var message: String {
        switch self {
        case .sourceTooLarge(let byteCount, let limit):
            "Image source is \(byteCount) bytes, above the \(limit)-byte preview limit."
        case .unrecognizedFormat:
            "Not a recognized image format (PNG, JPEG, GIF, HEIC, TIFF, or SVG)."
        case .unreadableSource:
            "Image data could not be read (corrupt or truncated container)."
        case .dimensionTooLarge(let width, let height, let limit):
            "Image dimensions \(width)x\(height) exceed the \(limit)-pixel-per-side preview limit."
        case .pixelCountTooLarge(let pixelCount, let limit):
            "Image has \(pixelCount) pixels, above the \(limit)-pixel preview limit."
        case .frameCountTooLarge(let frameCount, let limit):
            "Image has \(frameCount) frames, above the \(limit)-frame preview limit."
        case .decodedByteBudgetExceeded(let estimatedBytes, let limit):
            "Decoding would require an estimated \(estimatedBytes) bytes, above the \(limit)-byte preview budget."
        case .decodeFailed(let frameIndex):
            "Frame \(frameIndex) could not be decoded (malformed pixel data)."
        case .missingDimensions(let frameIndex):
            "Frame \(frameIndex) has no readable pixel dimensions."
        }
    }
}
