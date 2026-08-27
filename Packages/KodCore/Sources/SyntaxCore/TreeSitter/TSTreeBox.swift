import CTreeSitter
import Foundation

/// Owns one `TSTree*`'s lifetime.
///
/// Deliberately **not** `Sendable`. Tree-sitter's own API documentation is
/// explicit that "syntax trees are not thread safe" and that a tree must
/// be copied (`ts_tree_copy`) before being used on more than one thread —
/// a finished, never-edited tree is no exception, because every tree
/// shares refcounted `Subtree` storage whose retain/release is not
/// atomic. Two isolation domains merely *reading* the same tree can
/// therefore corrupt that shared refcount, so this box models exclusive
/// ownership and `copy()` is the only way to obtain a second, independent
/// handle.
final class TSTreeBox {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    /// An independent tree that another isolation domain may use freely.
    /// `ts_tree_copy` is a cheap shallow copy, but it retains the shared
    /// root subtree non-atomically, so it must be called from whichever
    /// domain currently owns `self` — never concurrently with any other
    /// use of this tree. Returns `nil` if the allocation fails.
    func copy() -> sending TSTreeBox? {
        guard let copied = ts_tree_copy(pointer) else {
            return nil
        }
        return Self.adopting(copied)
    }

    /// Wraps a freshly-allocated `TSTree*` that nothing else references
    /// yet, which is exactly what `ts_tree_copy` returns, so the box
    /// genuinely belongs to no existing isolation region.
    ///
    /// Region isolation cannot derive that itself: `OpaquePointer` is not
    /// `Sendable`, so anything built from one is conservatively treated as
    /// staying in the caller's region. The `nonisolated(unsafe)` here is
    /// the narrowest possible escape hatch — it applies to one
    /// provably-fresh allocation, unlike an `@unchecked Sendable`
    /// conformance on the type, which would also (wrongly) permit sharing
    /// the *same* tree across domains.
    private static func adopting(_ pointer: OpaquePointer) -> sending TSTreeBox {
        nonisolated(unsafe) let box = TSTreeBox(pointer: pointer)
        return box
    }

    deinit {
        ts_tree_delete(pointer)
    }
}

/// Owns a `TSQuery*`'s lifetime, one per language, compiled once and reused
/// for every parse in that language. Unlike a tree, a compiled query is
/// immutable after `ts_query_new` and holds no mutable shared state (all
/// per-execution state lives in a `TSQueryCursor`, which is created,
/// used, and destroyed inside a single call), so sharing one across
/// isolation domains is safe.
final class TSQueryBox: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        ts_query_delete(pointer)
    }
}

enum TreeSitterParseError: Error, Equatable {
    case parserAllocationFailed
    case languageIncompatible
    case invalidIncludedRanges
    case parseProducedNoTree
}

enum TreeSitterQueryError: Error, Equatable {
    case queryAllocationFailed
    case invalidQuery(offset: Int, kind: String)
    case missingResource(String)
}

/// Thin, ARC-friendly wrapper around the C parsing entry point. Kod always
/// performs a fresh, non-incremental parse of the entire snapshot: Kod is a
/// read-only viewer, so a changed file arrives as a wholesale new
/// `SourceSnapshot` (from an external write), not as a sequence of
/// keystroke edits Tree-sitter could apply to a previous tree. Reusing a
/// prior tree via `ts_tree_edit` would require synthesizing edit deltas we
/// do not have, so a full re-parse per changed snapshot is both simpler and
/// correct; `SyntaxEngine` still avoids redundant work by keying results on
/// the snapshot version and cancelling stale requests.
enum TreeSitterParser {
    static func parse(
        utf8: Data,
        language: SyntaxLanguage,
        includedRanges: [TSRange] = []
    ) throws -> TSTreeBox {
        guard let parser = ts_parser_new() else {
            throw TreeSitterParseError.parserAllocationFailed
        }
        defer { ts_parser_delete(parser) }

        guard ts_parser_set_language(parser, language.tsLanguage) else {
            throw TreeSitterParseError.languageIncompatible
        }
        if !includedRanges.isEmpty {
            let accepted = includedRanges.withUnsafeBufferPointer { ranges in
                ts_parser_set_included_ranges(
                    parser,
                    ranges.baseAddress,
                    UInt32(ranges.count)
                )
            }
            guard accepted else {
                throw TreeSitterParseError.invalidIncludedRanges
            }
        }

        let tree: OpaquePointer? = utf8.withUnsafeBytes { rawBuffer in
            let base = rawBuffer.bindMemory(to: CChar.self).baseAddress
            return ts_parser_parse_string(parser, nil, base, UInt32(rawBuffer.count))
        }

        guard let tree else {
            throw TreeSitterParseError.parseProducedNoTree
        }
        return TSTreeBox(pointer: tree)
    }
}
