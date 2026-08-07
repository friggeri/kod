import Foundation

/// Read-only metadata about a decoded (or about-to-be-decoded) image,
/// exposed for the metadata panel in SPEC 10.2 ("image metadata").
public struct ImageMetadata: Equatable, Sendable {
    public let format: ImageFormat
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let frameCount: Int
    public let hasAlpha: Bool
    public let colorModel: String?
    public let bitsPerComponent: Int?
    public let dpiWidth: Double?
    public let dpiHeight: Double?
    /// Loop count for animated images: `0` means "loop forever" (GIF's own
    /// convention), `nil` means not applicable/unknown.
    public let loopCount: Int?
    public let fileByteCount: Int

    public init(
        format: ImageFormat,
        pixelWidth: Int,
        pixelHeight: Int,
        frameCount: Int,
        hasAlpha: Bool,
        colorModel: String?,
        bitsPerComponent: Int?,
        dpiWidth: Double?,
        dpiHeight: Double?,
        loopCount: Int?,
        fileByteCount: Int
    ) {
        self.format = format
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.frameCount = frameCount
        self.hasAlpha = hasAlpha
        self.colorModel = colorModel
        self.bitsPerComponent = bitsPerComponent
        self.dpiWidth = dpiWidth
        self.dpiHeight = dpiHeight
        self.loopCount = loopCount
        self.fileByteCount = fileByteCount
    }
}
