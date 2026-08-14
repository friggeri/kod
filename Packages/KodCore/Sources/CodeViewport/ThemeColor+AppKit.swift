import AppKit
import TextDecorationModel

// `ThemeColor` itself is a portable value type in `TextDecorationModel`
// (no AppKit, no theme schema). The `NSColor` bridge lives here, in the
// only AppKit presentation target that actually paints with it, so
// neither the decoration model nor `ThemeCore` has to import AppKit.
extension ThemeColor {
    public init(nsColor: NSColor) {
        let converted = nsColor.usingColorSpace(.sRGB) ?? nsColor
        self.init(
            red: Double(converted.redComponent),
            green: Double(converted.greenComponent),
            blue: Double(converted.blueComponent),
            alpha: Double(converted.alphaComponent)
        )
    }

    public var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat(red),
            green: CGFloat(green),
            blue: CGFloat(blue),
            alpha: CGFloat(alpha)
        )
    }
}
