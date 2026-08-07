import Foundation

/// A cross-platform-safe mirror of `NSFont.Weight`'s handful of named
/// weights, kept independent of AppKit so the settings model stays a plain
/// value type; `FontCore+AppKit.swift` converts to/from `NSFont.Weight`.
public enum FontWeight: String, Codable, Sendable, CaseIterable {
    case ultraLight
    case thin
    case light
    case regular
    case medium
    case semibold
    case bold
    case heavy
    case black

    public var displayName: String {
        switch self {
        case .ultraLight: "Ultra Light"
        case .thin: "Thin"
        case .light: "Light"
        case .regular: "Regular"
        case .medium: "Medium"
        case .semibold: "Semibold"
        case .bold: "Bold"
        case .heavy: "Heavy"
        case .black: "Black"
        }
    }
}
