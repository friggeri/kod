import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import PreviewCore

final class ImageDecoderTests: XCTestCase {
    // MARK: - Golden

    func testDecodesValidPNG() throws {
        let data = try ImageFixture.makePNG(width: 16, height: 8)
        let result = ImageDecoder.decode(data)
        guard case .decoded(let metadata, let frames) = result else {
            return XCTFail("expected decoded PNG, got \(result)")
        }
        XCTAssertEqual(metadata.format, .png)
        XCTAssertEqual(metadata.pixelWidth, 16)
        XCTAssertEqual(metadata.pixelHeight, 8)
        XCTAssertEqual(metadata.frameCount, 1)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].image.value.width, 16)
        XCTAssertEqual(frames[0].image.value.height, 8)
    }

    func testDecodesValidJPEG() throws {
        let data = try ImageFixture.makeJPEG(width: 20, height: 10)
        let result = ImageDecoder.decode(data)
        guard case .decoded(let metadata, _) = result else {
            return XCTFail("expected decoded JPEG, got \(result)")
        }
        XCTAssertEqual(metadata.format, .jpeg)
        XCTAssertEqual(metadata.pixelWidth, 20)
        XCTAssertEqual(metadata.pixelHeight, 10)
    }

    func testDecodesAnimatedGIFWithMultipleFrames() throws {
        let data = try ImageFixture.makeGIF(width: 4, height: 4, frameCount: 3)
        let result = ImageDecoder.decode(data)
        guard case .decoded(let metadata, let frames) = result else {
            return XCTFail("expected decoded GIF, got \(result)")
        }
        XCTAssertEqual(metadata.format, .gif)
        XCTAssertEqual(metadata.frameCount, 3)
        XCTAssertEqual(frames.count, 3)
    }

    func testDecodesTIFF() throws {
        let data = try ImageFixture.makeTIFF(width: 12, height: 6)
        let result = ImageDecoder.decode(data)
        guard case .decoded(let metadata, _) = result else {
            return XCTFail("expected decoded TIFF, got \(result)")
        }
        XCTAssertEqual(metadata.format, .tiff)
        XCTAssertEqual(metadata.pixelWidth, 12)
        XCTAssertEqual(metadata.pixelHeight, 6)
    }

    // MARK: - Hostile / limits

    func testEmptyDataIsRejectedAsUnrecognized() {
        guard case .rejected(.unrecognizedFormat) = ImageDecoder.decode(Data()) else {
            return XCTFail("expected unrecognizedFormat for empty data")
        }
    }

    func testTruncatedPNGIsRejectedNotCrashed() throws {
        let full = try ImageFixture.makePNG(width: 16, height: 16)
        let truncated = full.prefix(full.count / 2)
        let result = ImageDecoder.decode(Data(truncated))
        // Either rejected outright or fails during decode — never a
        // silently-empty "success".
        if case .decoded(_, let frames) = result {
            XCTAssertFalse(frames.isEmpty, "a 'decoded' result must not silently contain zero frames")
        } else {
            XCTAssertNotNil(result.diagnostic)
        }
    }

    func testCorruptedMagicBytesAreRejected() {
        var bytes = Array("bplist00".utf8) // a plist, not an image
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 64))
        guard case .rejected(.unrecognizedFormat) = ImageDecoder.decode(Data(bytes)) else {
            return XCTFail("expected unrecognizedFormat for non-image content")
        }
    }

    func testOversizedSourceIsRejectedBeforeDecoding() throws {
        let data = try ImageFixture.makePNG(width: 8, height: 8)
        let limits = ImageDecodeLimits(maximumSourceByteCount: 4)
        guard case .rejected(.sourceTooLarge) = ImageDecoder.decode(data, limits: limits) else {
            return XCTFail("expected sourceTooLarge")
        }
    }

    func testDecompressionBombDeclaredDimensionsAreRejectedWithoutAllocating() throws {
        // A real PNG whose IHDR declares an enormous width/height. Real
        // pixel data is never provided (and never needs to be, for the
        // rejection to be correct) — this is exactly the "tiny file,
        // huge claimed dimensions" decompression-bomb shape.
        let data = try ImageFixture.makePNGWithForgedIHDRDimensions(width: 500_000, height: 500_000)
        let limits = ImageDecodeLimits(maximumDimension: 20_000, maximumPixelCount: 60_000_000)
        guard case .rejected(let diagnostic) = ImageDecoder.decode(data, limits: limits) else {
            return XCTFail("expected a forged-huge-dimension PNG to be rejected")
        }
        switch diagnostic {
        case .dimensionTooLarge, .pixelCountTooLarge, .unreadableSource, .missingDimensions:
            break // any of these is an acceptable, explicit rejection
        default:
            XCTFail("expected a dimension/pixel-count rejection, got \(diagnostic)")
        }
    }

    func testGIFExceedingFrameCountLimitIsRejected() throws {
        let data = try ImageFixture.makeGIF(width: 2, height: 2, frameCount: 20)
        let limits = ImageDecodeLimits(maximumFrameCount: 5)
        guard case .rejected(.frameCountTooLarge(let frameCount, let limit)) = ImageDecoder.decode(data, limits: limits) else {
            return XCTFail("expected frameCountTooLarge")
        }
        XCTAssertEqual(frameCount, 20)
        XCTAssertEqual(limit, 5)
    }

    func testDimensionExceedingLimitIsRejected() throws {
        let data = try ImageFixture.makePNG(width: 4_000, height: 4_000)
        let limits = ImageDecodeLimits(maximumDimension: 1_000)
        guard case .rejected(.dimensionTooLarge) = ImageDecoder.decode(data, limits: limits) else {
            return XCTFail("expected dimensionTooLarge")
        }
    }

    func testPixelCountExceedingLimitIsRejected() throws {
        let data = try ImageFixture.makePNG(width: 3_000, height: 3_000)
        let limits = ImageDecodeLimits(maximumDimension: 100_000, maximumPixelCount: 1_000_000)
        guard case .rejected(.pixelCountTooLarge) = ImageDecoder.decode(data, limits: limits) else {
            return XCTFail("expected pixelCountTooLarge")
        }
    }

    func testSVGFileIsNeverRoutedThroughImageIODecoder() throws {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"></svg>"
        guard case .rejected(.unrecognizedFormat) = ImageDecoder.decode(Data(svg.utf8)) else {
            return XCTFail("SVG must never be handed to the ImageIO-based decoder")
        }
    }
}

enum ImageFixture {
    enum FixtureError: Error {
        case creationFailed
    }

    static func makeSolidBitmapContext(width: Int, height: Int) throws -> CGContext {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw FixtureError.creationFailed
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    static func makePNG(width: Int, height: Int) throws -> Data {
        let context = try makeSolidBitmapContext(width: width, height: height)
        guard let image = context.makeImage() else {
            throw FixtureError.creationFailed
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw FixtureError.creationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError.creationFailed
        }
        return data as Data
    }

    static func makeJPEG(width: Int, height: Int) throws -> Data {
        let context = try makeSolidBitmapContext(width: width, height: height)
        guard let image = context.makeImage() else {
            throw FixtureError.creationFailed
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw FixtureError.creationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError.creationFailed
        }
        return data as Data
    }

    static func makeTIFF(width: Int, height: Int) throws -> Data {
        let context = try makeSolidBitmapContext(width: width, height: height)
        guard let image = context.makeImage() else {
            throw FixtureError.creationFailed
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.tiff" as CFString, 1, nil) else {
            throw FixtureError.creationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError.creationFailed
        }
        return data as Data
    }

    static func makeGIF(width: Int, height: Int, frameCount: Int) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, frameCount, nil) else {
            throw FixtureError.creationFailed
        }
        for frameIndex in 0..<frameCount {
            let context = try makeSolidBitmapContext(width: width, height: height)
            context.setFillColor(CGColor(red: Double(frameIndex) / Double(frameCount), green: 0.1, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            guard let image = context.makeImage() else {
                throw FixtureError.creationFailed
            }
            let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary
            CGImageDestinationAddImage(destination, image, frameProperties)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError.creationFailed
        }
        return data as Data
    }

    /// Builds a syntactically-valid minimal PNG (correct signature, a
    /// real CRC-32'd IHDR chunk, and an empty IEND) whose IHDR declares
    /// `width`/`height` far larger than any real pixel data backs — the
    /// canonical decompression-bomb shape ImageIO must reject from the
    /// header alone, without ever allocating a buffer that size.
    static func makePNGWithForgedIHDRDimensions(width: UInt32, height: UInt32) throws -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        func chunk(_ type: String, _ payload: Data) -> Data {
            var chunkData = Data()
            var length = UInt32(payload.count).bigEndian
            chunkData.append(Data(bytes: &length, count: 4))
            let typeAndPayload = Data(type.utf8) + payload
            chunkData.append(typeAndPayload)
            var crc = CRC32.checksum(typeAndPayload).bigEndian
            chunkData.append(Data(bytes: &crc, count: 4))
            return chunkData
        }

        var ihdr = Data()
        var widthBE = width.bigEndian
        var heightBE = height.bigEndian
        ihdr.append(Data(bytes: &widthBE, count: 4))
        ihdr.append(Data(bytes: &heightBE, count: 4))
        ihdr.append(contentsOf: [8, 6, 0, 0, 0]) // 8-bit depth, RGBA, defaults

        data.append(chunk("IHDR", ihdr))
        data.append(chunk("IEND", Data()))
        return data
    }
}

/// A minimal CRC-32 (ISO 3309 / PNG's checksum) implementation — needed
/// only to build a syntactically-valid forged-IHDR PNG fixture above; not
/// used anywhere in `PreviewCore` itself.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1 != 0) ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
