/// The highlighting pipeline layers from SPEC 7.1 in ascending precedence
/// order: later layers override earlier ones' attributes where they set a
/// value. Git changes are editor gutter chrome and intentionally do not
/// participate in source-text decoration composition.
/// `Comparable` conformance follows raw-value order so a compositor can
/// iterate `DecorationLayerKind.allCases` to apply overlays correctly.
public enum DecorationLayerKind: Int, CaseIterable, Sendable, Comparable {
    case base = 0
    case lexical = 2
    case semantic = 3
    case search = 4
    case diagnostics = 5
    case selection = 6

    public static func < (lhs: DecorationLayerKind, rhs: DecorationLayerKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Visual attributes a single decoration layer contributes to a byte range.
/// Composition overlays fields: a layer only overrides an attribute it
/// actually sets, so a higher-precedence layer that only sets a background
/// (e.g. a search-match highlight) does not blank out a lower layer's
/// foreground color.
public struct DecorationAttributes: Equatable, Sendable {
    public var foreground: ThemeColor?
    public var background: ThemeColor?
    public var isBold: Bool
    public var isItalic: Bool
    public var isUnderlined: Bool
    public var isStrikethrough: Bool

    public init(
        foreground: ThemeColor? = nil,
        background: ThemeColor? = nil,
        isBold: Bool = false,
        isItalic: Bool = false,
        isUnderlined: Bool = false,
        isStrikethrough: Bool = false
    ) {
        self.foreground = foreground
        self.background = background
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderlined = isUnderlined
        self.isStrikethrough = isStrikethrough
    }

    public static let none = DecorationAttributes()

    /// Overlays `other` on top of `self`, per the merge rule above.
    public func overlaying(_ other: DecorationAttributes) -> DecorationAttributes {
        DecorationAttributes(
            foreground: other.foreground ?? foreground,
            background: other.background ?? background,
            isBold: other.isBold || isBold,
            isItalic: other.isItalic || isItalic,
            isUnderlined: other.isUnderlined || isUnderlined,
            isStrikethrough: other.isStrikethrough || isStrikethrough
        )
    }
}

/// One styled, contiguous UTF-8 byte range within a single layer.
public struct DecorationRun: Equatable, Sendable {
    public let utf8Range: Range<Int>
    public let attributes: DecorationAttributes

    public init(utf8Range: Range<Int>, attributes: DecorationAttributes) {
        self.utf8Range = utf8Range
        self.attributes = attributes
    }
}

/// A versioned batch of runs a single layer contributes for one source
/// snapshot. `layerVersion` increases monotonically as a layer recomputes
/// (e.g. a second, wider re-highlight after the viewport-priority pass), so
/// the compositor can reject an out-of-order, superseded delivery.
public struct DecorationLayerSnapshot: Sendable {
    public let kind: DecorationLayerKind
    public let snapshotVersion: Int
    public let layerVersion: Int
    public let runs: [DecorationRun]

    public init(
        kind: DecorationLayerKind,
        snapshotVersion: Int,
        layerVersion: Int,
        runs: [DecorationRun]
    ) {
        self.kind = kind
        self.snapshotVersion = snapshotVersion
        self.layerVersion = layerVersion
        self.runs = runs
    }
}
