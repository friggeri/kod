import Foundation

/// Bounds Markdown parsing so a pathological document (thousands of
/// nested blockquotes/list items, a single-line file of megabytes) cannot
/// exhaust the stack or memory while only trying to render a preview.
public struct MarkdownLimits: Equatable, Sendable {
    /// Maximum nesting depth for block containers (blockquotes, list
    /// items nested inside list items, etc.).
    public var maximumBlockDepth: Int
    /// Maximum nesting depth for inline containers (emphasis inside
    /// emphasis inside a link, etc.).
    public var maximumInlineDepth: Int
    /// Maximum number of top-level+nested block nodes in one document.
    public var maximumBlockCount: Int
    /// Maximum source size this parser will attempt at all.
    public var maximumSourceByteCount: Int
    /// Maximum columns a single GFM table may declare.
    public var maximumTableColumns: Int

    public init(
        maximumBlockDepth: Int = 128,
        maximumInlineDepth: Int = 128,
        maximumBlockCount: Int = 200_000,
        maximumSourceByteCount: Int = 10 * 1_024 * 1_024,
        maximumTableColumns: Int = 256
    ) {
        self.maximumBlockDepth = maximumBlockDepth
        self.maximumInlineDepth = maximumInlineDepth
        self.maximumBlockCount = maximumBlockCount
        self.maximumSourceByteCount = maximumSourceByteCount
        self.maximumTableColumns = maximumTableColumns
    }

    public static let `default` = MarkdownLimits()
}
