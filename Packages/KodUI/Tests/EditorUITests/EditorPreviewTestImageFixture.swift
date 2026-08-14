import CoreGraphics
import Foundation
import ImageIO

enum EditorPreviewTestImageFixture {
    enum FixtureError: Error {
        case creationFailed
    }

    static func makePNG(width: Int, height: Int) throws -> Data {
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
        context.setFillColor(
            CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw FixtureError.creationFailed
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw FixtureError.creationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError.creationFailed
        }
        return data as Data
    }
}
