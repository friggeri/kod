import Foundation

/// A device-independent sRGB color used throughout the native theme schema.
/// Stored as normalized (0...1) components so it can be serialized,
/// contrast-checked, and converted to `NSColor` without any dependency on
/// `AppKit` in this type itself.
public struct ThemeColor: Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Parses a `#RGB`, `#RGBA`, `#RRGGBB`, or `#RRGGBBAA` hex string, the
    /// format used both by the Kod-native JSON schema and by VS Code
    /// color-theme JSON files.
    public init?(hex: String) {        var value = hex
        if value.hasPrefix("#") {
            value.removeFirst()
        }

        func component(_ hexPair: Substring) -> Double? {
            guard let byte = UInt8(hexPair, radix: 16) else {
                return nil
            }
            return Double(byte) / 255
        }

        switch value.count {
        case 3, 4:
            let chars = Array(value)
            let expanded = chars.map { "\($0)\($0)" }
            guard let r = component(Substring(expanded[0])),
                  let g = component(Substring(expanded[1])),
                  let b = component(Substring(expanded[2])) else {
                return nil
            }
            let a = expanded.count == 4 ? component(Substring(expanded[3])) : 1
            guard let alpha = a else {
                return nil
            }
            self.init(red: r, green: g, blue: b, alpha: alpha)

        case 6, 8:
            let startIndex = value.startIndex
            guard let r = component(value[startIndex..<value.index(startIndex, offsetBy: 2)]),
                  let g = component(
                    value[value.index(startIndex, offsetBy: 2)..<value.index(startIndex, offsetBy: 4)]
                  ),
                  let b = component(
                    value[value.index(startIndex, offsetBy: 4)..<value.index(startIndex, offsetBy: 6)]
                  ) else {
                return nil
            }
            var a = 1.0
            if value.count == 8,
               let parsedAlpha = component(
                value[value.index(startIndex, offsetBy: 6)..<value.index(startIndex, offsetBy: 8)]
               ) {
                a = parsedAlpha
            }
            self.init(red: r, green: g, blue: b, alpha: a)

        default:
            return nil
        }
    }

    /// Convenience for bundled-theme literals that need an explicit alpha
    /// distinct from what the hex string encodes (e.g. a translucent
    /// selection highlight derived from an opaque brand color).
    public init?(hex: String, alpha: Double) {
        guard let base = ThemeColor(hex: hex) else {
            return nil
        }
        self.init(red: base.red, green: base.green, blue: base.blue, alpha: alpha)
    }

    public var hexString: String {
        func byte(_ component: Double) -> String {
            String(format: "%02X", Int((component.clamped(to: 0...1) * 255).rounded()))
        }
        var string = "#" + byte(red) + byte(green) + byte(blue)
        if alpha < 1 {
            string += byte(alpha)
        }
        return string
    }

    /// WCAG relative luminance of this color, ignoring alpha (as if
    /// composited over an opaque background already).
    public var relativeLuminance: Double {
        func linearize(_ component: Double) -> Double {
            let clamped = component.clamped(to: 0...1)
            return clamped <= 0.03928 ? clamped / 12.92 : pow((clamped + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
    }

    /// WCAG contrast ratio between this color and `other`, in the range
    /// `1...21`. Order of the two colors does not matter.
    public func contrastRatio(against other: ThemeColor) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

extension ThemeColor: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let hex = try container.decode(String.self)
        guard let color = ThemeColor(hex: hex) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid color hex string: \(hex)"
            )
        }
        self = color
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexString)
    }
}

extension Double {
    fileprivate func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
