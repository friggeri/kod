import CTreeSitter
import Foundation

/// A single Tree-sitter highlight capture: the dotted capture name from the
/// bundled `highlights.scm` (e.g. `"keyword"`, `"function.method"`) and the
/// UTF-8 byte range of the captured node in the snapshot that produced it.
public struct SyntaxCapture: Equatable, Sendable {
    public let name: String
    public let utf8Range: Range<Int>

    public init(name: String, utf8Range: Range<Int>) {
        self.name = name
        self.utf8Range = utf8Range
    }
}

/// A structural fold candidate: `headerLine` stays visible when folded,
/// and lines `headerLine + 1...endLine` collapse.
public struct FoldRange: Equatable, Sendable {
    public let headerLine: Int
    public let endLine: Int

    public init(headerLine: Int, endLine: Int) {
        self.headerLine = headerLine
        self.endLine = endLine
    }
}

/// One level of an enclosing structural scope, used for sticky scope
/// headers: the source line whose text should be pinned while the viewport
/// has scrolled past it but is still inside the scope's byte range.
public struct ScopeHeader: Equatable, Sendable {
    public let startLine: Int
    public let endLine: Int

    public init(startLine: Int, endLine: Int) {
        self.startLine = startLine
        self.endLine = endLine
    }
}

struct SyntaxTreeLayer {
    let treeBox: TSTreeBox
    let language: SyntaxLanguage

    func copy() -> sending SyntaxTreeLayer? {
        guard let copiedBox = treeBox.copy() else {
            return nil
        }
        return SyntaxTreeLayer(treeBox: copiedBox, language: language)
    }
}

/// A parsed Tree-sitter tree bound to the exact snapshot bytes it was
/// parsed from, plus the snapshot version and language it is valid for.
/// `SyntaxEngine` discards any `SyntaxTree` whose `snapshotVersion` no
/// longer matches the active snapshot before it is ever composited into a
/// decoration layer.
///
/// Not `Sendable`: it owns `TSTree`s, which tree-sitter documents as not
/// thread safe (see `TSTreeBox`). A tree is *transferred* out of
/// `SyntaxEngine` as a `sending` result, and any second isolation domain
/// that needs one at the same time gets its own `copy()` rather than a
/// shared reference.
public struct SyntaxTree {
    public let language: SyntaxLanguage
    public let snapshotVersion: Int

    private let treeBox: TSTreeBox
    private let additionalLayers: [SyntaxTreeLayer]
    private let utf8: Data

    /// Safety ceiling for fold ranges and scope-header collection so a
    /// pathologically deep or repetitive tree cannot allocate an unbounded
    /// array (SPEC 12.3: "No supported or adversarial input may cause
    /// unbounded allocation").
    private static let maximumStructuralResults = 20_000

    init(
        treeBox: TSTreeBox,
        additionalLayers: [SyntaxTreeLayer] = [],
        utf8: Data,
        language: SyntaxLanguage,
        snapshotVersion: Int
    ) {
        self.treeBox = treeBox
        self.additionalLayers = additionalLayers
        self.utf8 = utf8
        self.language = language
        self.snapshotVersion = snapshotVersion
    }

    private var rootNode: TSNode {
        ts_tree_root_node(treeBox.pointer)
    }

    /// An independent tree describing the same parse, safe to hand to
    /// another isolation domain while this one keeps using the original
    /// (tree-sitter's documented requirement for using a tree on more
    /// than one thread). Must be called from the domain that owns `self`;
    /// the copy is a fresh value with no shared mutable state.
    ///
    /// Returns `nil` only if a tree copy could not be allocated, in which
    /// case the caller does without highlighting rather than sharing a
    /// tree unsafely.
    public func copy() -> sending SyntaxTree? {
        guard let copiedTree = treeBox.copy() else {
            return nil
        }
        var copiedLayers: [SyntaxTreeLayer] = []
        copiedLayers.reserveCapacity(additionalLayers.count)
        for layer in additionalLayers {
            guard let copiedLayer = layer.copy() else {
                return nil
            }
            copiedLayers.append(copiedLayer)
        }
        return SyntaxTree(
            treeBox: copiedTree,
            additionalLayers: copiedLayers,
            utf8: utf8,
            language: language,
            snapshotVersion: snapshotVersion
        )
    }

    /// Runs the language's bundled highlight query restricted to
    /// `byteRange`, returning capture spans clipped to that range. Passing
    /// the visible viewport's byte range lets `SyntaxEngine` prioritize
    /// what is currently on screen without walking the whole tree first.
    public func captures(inByteRange byteRange: Range<Int>) -> [SyntaxCapture] {
        let layers = [SyntaxTreeLayer(treeBox: treeBox, language: language)] + additionalLayers
        var results: [SyntaxCapture] = []
        for layer in layers {
            appendCaptures(
                from: layer,
                inByteRange: byteRange,
                into: &results
            )
            if results.count >= Self.maximumStructuralResults {
                break
            }
        }
        return results
    }

    private func appendCaptures(
        from layer: SyntaxTreeLayer,
        inByteRange byteRange: Range<Int>,
        into results: inout [SyntaxCapture]
    ) {
        guard case .success(let queryBox) = TSQueryStore.shared.highlightsQuery(for: layer.language) else {
            // Already logged (once, cached) by `TSQueryStore` at compile
            // time; returning no captures here just means this call site
            // keeps showing plain text instead of hanging or crashing.
            return
        }
        guard let cursor = ts_query_cursor_new() else {
            SyntaxCoreLog.parsing.error("ts_query_cursor_new() returned NULL (out of memory?)")
            return
        }
        defer { ts_query_cursor_delete(cursor) }

        ts_query_cursor_set_byte_range(
            cursor,
            UInt32(clamping: byteRange.lowerBound),
            UInt32(clamping: byteRange.upperBound)
        )
        ts_query_cursor_exec(cursor, queryBox.pointer, ts_tree_root_node(layer.treeBox.pointer))

        let evaluator = TreeSitterPredicateEvaluator(query: queryBox.pointer, utf8: utf8)
        var match = TSQueryMatch()

        while ts_query_cursor_next_match(cursor, &match) {
            guard evaluator.matches(match) else {
                continue
            }
            guard match.capture_count > 0, let captures = match.captures else {
                continue
            }
            let matchCaptures = UnsafeBufferPointer(start: captures, count: Int(match.capture_count))
            for capture in matchCaptures {
                let start = Int(ts_node_start_byte(capture.node))
                let end = Int(ts_node_end_byte(capture.node))
                guard end > start else {
                    continue
                }
                var nameLength: UInt32 = 0
                guard let namePointer = ts_query_capture_name_for_id(
                    queryBox.pointer,
                    capture.index,
                    &nameLength
                ) else {
                    continue
                }
                let name = String(
                    decoding: UnsafeBufferPointer(start: namePointer, count: Int(nameLength)).map { UInt8(bitPattern: $0) },
                    as: UTF8.self
                )
                results.append(SyntaxCapture(name: name, utf8Range: start..<end))
                if results.count >= Self.maximumStructuralResults {
                    return
                }
            }
        }
    }

    /// Structural fold ranges derived from any named node spanning two or
    /// more source lines. This is grammar-agnostic (it works uniformly
    /// across all seven launch languages without per-language node-type
    /// lists) and mirrors how folding actually reads: any block, body, or
    /// aggregate that visually spans multiple lines is a fold candidate.
    public func foldRanges() -> [FoldRange] {
        var results: [FoldRange] = []
        // Start from the root's children, not the root itself: folding the
        // entire file top-level node is never a useful affordance, and a
        // trailing newline routinely makes the root span two rows even for
        // a single-statement file, which would otherwise mark line 0
        // foldable in files that have nothing meaningful to fold.
        let childCount = ts_node_named_child_count(rootNode)
        for index in 0..<childCount {
            collectFoldRanges(node: ts_node_named_child(rootNode, index), into: &results)
            if results.count >= Self.maximumStructuralResults {
                break
            }
        }
        return results
    }

    private func collectFoldRanges(node: TSNode, into results: inout [FoldRange]) {
        guard results.count < Self.maximumStructuralResults else {
            return
        }
        if ts_node_is_named(node) {
            let startRow = Int(ts_node_start_point(node).row)
            let endRow = Int(ts_node_end_point(node).row)
            if endRow > startRow {
                results.append(FoldRange(headerLine: startRow, endLine: endRow))
            }
        }

        let childCount = ts_node_named_child_count(node)
        for index in 0..<childCount {
            collectFoldRanges(node: ts_node_named_child(node, index), into: &results)
            if results.count >= Self.maximumStructuralResults {
                return
            }
        }
    }

    /// Named ancestors of the node at `byteOffset` that span more than one
    /// line, outermost first, used to render sticky scope headers. Adjacent
    /// ancestors that start on the same source line (a common wrapper
    /// pattern, e.g. a declaration node immediately wrapping its body node)
    /// collapse into a single header so the same line is never pinned
    /// twice.
    public func enclosingScopes(atByteOffset byteOffset: Int, maximumDepth: Int = 8) -> [ScopeHeader] {
        guard byteOffset >= 0, byteOffset <= utf8.count else {
            return []
        }
        let clamped = UInt32(clamping: byteOffset)
        var node = ts_node_descendant_for_byte_range(rootNode, clamped, clamped)

        var scopes: [ScopeHeader] = []
        var lastStartLine: Int?
        while !ts_node_is_null(node) {
            let parent = ts_node_parent(node)
            defer { node = parent }
            // The root represents the whole document, not a meaningful
            // lexical scope. Pinning it would incorrectly turn line zero
            // (often an import) into a sticky header throughout the file.
            guard !ts_node_is_null(parent) else {
                continue
            }
            guard ts_node_is_named(node) else {
                continue
            }
            let startRow = Int(ts_node_start_point(node).row)
            let endRow = Int(ts_node_end_point(node).row)
            guard endRow > startRow else {
                continue
            }
            if let lastStartLine, lastStartLine == startRow {
                continue
            }
            scopes.append(ScopeHeader(startLine: startRow, endLine: endRow))
            lastStartLine = startRow
        }
        return Array(scopes.reversed().prefix(maximumDepth))
    }
}

extension UInt32 {
    fileprivate init(clamping value: Int) {
        if value < 0 {
            self = 0
        } else if value > Int(UInt32.max) {
            self = UInt32.max
        } else {
            self = UInt32(value)
        }
    }
}
