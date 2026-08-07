import CoreGraphics
import Foundation
import ImageIO

/// A single decoded raster frame: its image and per-frame timing (only
/// meaningful for animated GIFs; `0` otherwise).
public struct ImageFrame: Sendable {
    public let image: CGImageBox
    public let durationSeconds: Double

    public init(image: CGImage, durationSeconds: Double) {
        self.image = ImageFrame.wrap(image)
        self.durationSeconds = durationSeconds
    }

    private static func wrap(_ image: CGImage) -> CGImageBox {
        CGImageBox(image)
    }
}

/// `CGImage` predates Swift concurrency and is not declared `Sendable` by
/// Core Graphics, but it is an immutable, reference-counted Core
/// Foundation object safe to share across isolation domains once created —
/// exactly the pattern Apple's own newer frameworks mark
/// `@unchecked Sendable` for. This box makes that safety assumption
/// explicit and localized to one type instead of disabling concurrency
/// checking more broadly.
public final class CGImageBox: @unchecked Sendable {
    public let value: CGImage

    public init(_ value: CGImage) {
        self.value = value
    }
}

/// The result of decoding an image source: metadata plus every accepted
/// frame, or a specific rejection diagnostic. There is no "succeeded with
/// zero frames" case standing in for a rejected/malformed source.
public enum ImageDecodeResult: Sendable {
    case decoded(metadata: ImageMetadata, frames: [ImageFrame])
    case rejected(ImageDecodeDiagnostic)

    public var metadata: ImageMetadata? {
        if case .decoded(let metadata, _) = self {
            return metadata
        }
        return nil
    }

    public var diagnostic: ImageDecodeDiagnostic? {
        if case .rejected(let diagnostic) = self {
            return diagnostic
        }
        return nil
    }
}

/// Decodes PNG/JPEG/GIF/HEIC/TIFF via ImageIO with every SPEC-10.2 safety
/// check applied *before* a full bitmap is ever requested:
///
/// 1. The source byte count is checked first.
/// 2. Each frame's *declared* pixel dimensions are read via
///    `CGImageSourceCopyPropertiesAtIndex`, which only parses the
///    container/header — it does not allocate or decode pixel data — so a
///    decompression bomb's true size is caught without ever inflating it.
/// 3. Frame count and a running total decoded-byte budget are checked
///    before each additional frame is decoded, so a many-frame GIF is
///    rejected once the cumulative budget would be exceeded rather than
///    after all frames are already resident in memory.
///
/// SVG is never handled here — see `SVGDocument`, which sanitizes and
/// rasterizes it through a completely separate, script-free path.
public enum ImageDecoder {
    public static func decode(
        _ data: Data,
        limits: ImageDecodeLimits = .default
    ) -> ImageDecodeResult {
        guard data.count <= limits.maximumSourceByteCount else {
            return .rejected(.sourceTooLarge(byteCount: data.count, limit: limits.maximumSourceByteCount))
        }
        guard let format = ImageFormat.detect(fromPrefixBytes: data), format.usesImageIODecoding else {
            return .rejected(.unrecognizedFormat)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return .rejected(.unreadableSource)
        }

        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else {
            return .rejected(.unreadableSource)
        }
        guard frameCount <= limits.maximumFrameCount else {
            return .rejected(.frameCountTooLarge(frameCount: frameCount, limit: limits.maximumFrameCount))
        }

        var totalEstimatedBytes = 0
        var firstWidth = 0
        var firstHeight = 0
        var hasAlpha = false
        var colorModel: String?
        var bitsPerComponent: Int?
        var dpiWidth: Double?
        var dpiHeight: Double?
        var loopCount: Int?

        // Pass 1: validate every declared frame size against limits and
        // the cumulative decode budget *before* decoding any pixel data.
        for index in 0..<frameCount {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
                return .rejected(.missingDimensions(frameIndex: index))
            }
            guard let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0 else {
                return .rejected(.missingDimensions(frameIndex: index))
            }
            guard width <= limits.maximumDimension, height <= limits.maximumDimension else {
                return .rejected(.dimensionTooLarge(width: width, height: height, limit: limits.maximumDimension))
            }
            let pixelCount = width * height
            guard pixelCount <= limits.maximumPixelCount else {
                return .rejected(.pixelCountTooLarge(pixelCount: pixelCount, limit: limits.maximumPixelCount))
            }
            totalEstimatedBytes += pixelCount * 4
            guard totalEstimatedBytes <= limits.maximumTotalDecodedByteBudget else {
                return .rejected(.decodedByteBudgetExceeded(estimatedBytes: totalEstimatedBytes, limit: limits.maximumTotalDecodedByteBudget))
            }

            if index == 0 {
                firstWidth = width
                firstHeight = height
                hasAlpha = (properties[kCGImagePropertyHasAlpha] as? Bool) ?? false
                colorModel = properties[kCGImagePropertyColorModel] as? String
                bitsPerComponent = properties[kCGImagePropertyDepth] as? Int
                dpiWidth = properties[kCGImagePropertyDPIWidth] as? Double
                dpiHeight = properties[kCGImagePropertyDPIHeight] as? Double
                if let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                    loopCount = gifProperties[kCGImagePropertyGIFLoopCount] as? Int
                }
            }
        }

        // Pass 2: only now decode actual pixel buffers, one frame at a
        // time, having already proven the total cost is within budget.
        var frames: [ImageFrame] = []
        frames.reserveCapacity(frameCount)
        for index in 0..<frameCount {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                return .rejected(.decodeFailed(frameIndex: index))
            }
            var duration = 0.0
            if format == .gif,
               let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
               let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                duration = (gifProperties[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                    ?? (gifProperties[kCGImagePropertyGIFDelayTime] as? Double)
                    ?? 0
            }
            frames.append(ImageFrame(image: cgImage, durationSeconds: duration))
        }

        let metadata = ImageMetadata(
            format: format,
            pixelWidth: firstWidth,
            pixelHeight: firstHeight,
            frameCount: frameCount,
            hasAlpha: hasAlpha,
            colorModel: colorModel,
            bitsPerComponent: bitsPerComponent,
            dpiWidth: dpiWidth,
            dpiHeight: dpiHeight,
            loopCount: loopCount,
            fileByteCount: data.count
        )
        return .decoded(metadata: metadata, frames: frames)
    }
}
