import Foundation

/// Bounds every structured-data (JSON/property-list) parse in `PreviewCore`.
///
/// These exist so a hostile or merely pathological document (deeply nested
/// arrays, a single multi-gigabyte string, millions of keys) cannot exhaust
/// memory or the call stack while Kod is only trying to preview a file. A
/// parse that would exceed any limit stops with an explicit
/// `StructuredDataDiagnostic` (see `StructuredParseResult`); it never
/// silently truncates data and claims success, and it never partially
/// allocates the offending structure before checking.
public struct StructuredDataLimits: Equatable, Sendable {
    /// Maximum container nesting depth (an array/object nested inside
    /// another counts as one level deeper). Bounds recursion so a document
    /// built from millions of nested `[[[[...]]]]` cannot overflow the
    /// stack.
    public var maximumDepth: Int
    /// Maximum number of nodes (object members + array elements +
    /// scalars) the whole document may contain.
    public var maximumNodeCount: Int
    /// Maximum UTF-8 byte length of any single string value or key.
    public var maximumStringLength: Int
    /// Maximum UTF-8 byte length of any single number literal's source
    /// text, guarding against pathological exponents/digit runs.
    public var maximumNumberLength: Int
    /// Maximum total source size this parser will attempt at all.
    public var maximumSourceLength: Int

    public init(
        maximumDepth: Int = 512,
        maximumNodeCount: Int = 500_000,
        maximumStringLength: Int = 4 * 1_024 * 1_024,
        maximumNumberLength: Int = 512,
        maximumSourceLength: Int = 64 * 1_024 * 1_024
    ) {
        self.maximumDepth = maximumDepth
        self.maximumNodeCount = maximumNodeCount
        self.maximumStringLength = maximumStringLength
        self.maximumNumberLength = maximumNumberLength
        self.maximumSourceLength = maximumSourceLength
    }

    /// Kod's documented default preview limits (SPEC 10.3).
    public static let `default` = StructuredDataLimits()
}
