import CTreeSitter
import Foundation

/// Owns a `TSTree*`'s lifetime. `TSTree` is safe to read from multiple
/// threads concurrently as long as no one is mutating it (Tree-sitter's own
/// contract), and Kod only ever reads finished trees after parsing, so this
/// box is `Sendable` by inspection despite wrapping a raw pointer.
final class TSTreeBox: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        ts_tree_delete(pointer)
    }
}

/// Owns a `TSQuery*`'s lifetime, one per language, compiled once and reused
/// for every parse in that language.
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
