import AppKit

/// A source-relative marker rendered in `CodeViewport`'s dedicated diff
/// gutter lane. The model is intentionally Git-agnostic: callers provide a
/// stable identifier and semantic kind while the viewport owns geometry,
/// hit-testing, and accessibility.
public struct CodeGutterChange: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case added
        case modified
        case deleted
    }

    public enum Layer: Equatable, Sendable {
        case primary
        case secondary
    }

    public enum Location: Equatable, Sendable {
        /// A non-empty, zero-based range of current-document source lines.
        case lines(Range<Int>)
        /// A deletion boundary after a zero-based source line. `-1` means
        /// before the first line.
        case deletion(afterLine: Int)
    }

    public let id: String
    public let kind: Kind
    public let layer: Layer
    public let location: Location
    public let accessibilityLabel: String

    public init(
        id: String,
        kind: Kind,
        layer: Layer = .primary,
        location: Location,
        accessibilityLabel: String
    ) {
        self.id = id
        self.kind = kind
        self.layer = layer
        self.location = location
        self.accessibilityLabel = accessibilityLabel
    }
}

/// Stable identity for one embedded editor view zone.
public struct CodeViewZoneID: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

@MainActor
struct CodeEmbeddedViewZone {
    let id: CodeViewZoneID
    let afterLine: Int
    let heightInLines: Int
    let view: NSView
}
