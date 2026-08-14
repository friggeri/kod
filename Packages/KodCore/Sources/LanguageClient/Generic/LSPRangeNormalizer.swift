import Foundation
import SourceModel

/// Pure conversion from LSP wire coordinates into UTF-8 byte ranges
/// validated against one immutable `SourceSnapshot`, always through the
/// position encoding the producing server actually negotiated rather
/// than an assumed UTF-16 (SPEC 6.3).
///
/// Every function here is a total function of its arguments: no actor
/// state, no connection, no I/O. A range that does not resolve inside
/// the snapshot yields `nil` (and the caller discards the result) rather
/// than being clamped onto the wrong text.
enum LSPRangeNormalizer {
    // MARK: - Ranges

    static func utf8Range(
        _ range: LSPRange,
        in snapshot: SourceSnapshot,
        encoding: SourcePositionEncoding
    ) -> Range<Int>? {
        guard let start = utf8Offset(
            for: range.start,
            in: snapshot,
            encoding: encoding
        ), let end = utf8Offset(
            for: range.end,
            in: snapshot,
            encoding: encoding
        ), start <= end else {
            return nil
        }
        return start..<end
    }

    static func utf8Offset(
        for position: LSPPosition,
        in snapshot: SourceSnapshot,
        encoding: SourcePositionEncoding
    ) -> Int? {
        try? snapshot.utf8Offset(
            for: SourcePosition(
                line: position.line,
                character: position.character
            ),
            encoding: encoding
        )
    }

    /// Structural-only validation for a range that need not point inside
    /// any snapshot Kod currently holds (a cross-file navigation target,
    /// a hierarchy item): non-negative and non-inverted.
    static func isStructurallyValid(_ range: LSPRange) -> Bool {
        range.start.line >= 0 && range.start.character >= 0
            && range.end.line >= 0 && range.end.character >= 0
            && (range.start.line, range.start.character) <= (range.end.line, range.end.character)
    }

    // MARK: - Diagnostics

    /// Diagnostics whose range does not resolve inside `snapshot` are
    /// dropped rather than shown at the wrong offset (SPEC 6.3).
    static func normalizedDiagnostics(
        _ diagnostics: [Diagnostic],
        snapshot: SourceSnapshot,
        encoding: SourcePositionEncoding
    ) -> [NormalizedDiagnostic] {
        diagnostics.compactMap { diagnostic in
            guard let range = utf8Range(
                diagnostic.range,
                in: snapshot,
                encoding: encoding
            ) else {
                return nil
            }
            return NormalizedDiagnostic(
                snapshotVersion: snapshot.version,
                utf8Range: range,
                startLine: diagnostic.range.start.line,
                severity: diagnostic.severity,
                code: diagnostic.code,
                source: diagnostic.source,
                message: diagnostic.message
            )
        }
    }

    // MARK: - Document structure

    static func validatedDocumentSymbol(
        _ symbol: DocumentSymbol,
        snapshot: SourceSnapshot,
        encoding: SourcePositionEncoding
    ) -> ValidatedDocumentSymbol? {
        guard let range = utf8Range(symbol.range, in: snapshot, encoding: encoding),
              let selectionRange = utf8Range(
                symbol.selectionRange,
                in: snapshot,
                encoding: encoding
              ) else {
            return nil
        }
        let children = symbol.children.compactMap {
            validatedDocumentSymbol($0, snapshot: snapshot, encoding: encoding)
        }
        return ValidatedDocumentSymbol(
            name: symbol.name,
            detail: symbol.detail,
            kind: symbol.kind,
            utf8Range: range,
            utf8SelectionRange: selectionRange,
            children: children
        )
    }

    /// A flat `SymbolInformation` entry, which is only usable when it
    /// actually describes the requested document.
    static func validatedDocumentSymbol(
        _ information: SymbolInformation,
        snapshot: SourceSnapshot,
        encoding: SourcePositionEncoding
    ) -> ValidatedDocumentSymbol? {
        guard information.location.uri.fileURL == snapshot.url,
              let range = utf8Range(
                information.location.range,
                in: snapshot,
                encoding: encoding
              ) else {
            return nil
        }
        return ValidatedDocumentSymbol(
            name: information.name,
            detail: information.containerName,
            kind: information.kind,
            utf8Range: range,
            utf8SelectionRange: range,
            children: []
        )
    }

    static func validatedSelectionRange(
        _ range: SelectionRange,
        snapshot: SourceSnapshot,
        encoding: SourcePositionEncoding
    ) -> ValidatedSelectionRange? {
        guard let utf8Range = utf8Range(
            range.range,
            in: snapshot,
            encoding: encoding
        ) else {
            return nil
        }
        let parent = range.parent.flatMap {
            validatedSelectionRange($0, snapshot: snapshot, encoding: encoding)
        }
        return ValidatedSelectionRange(utf8Range: utf8Range, parent: parent)
    }

    /// Folding ranges are line-based, so they are validated against the
    /// snapshot's line count rather than converted through an encoding.
    static func validatedFoldingRange(
        _ range: FoldingRange,
        snapshot: SourceSnapshot
    ) -> ValidatedFoldingRange? {
        guard range.startLine >= 0,
              range.endLine >= range.startLine,
              range.endLine < snapshot.lineCount else {
            return nil
        }
        return ValidatedFoldingRange(
            startLine: range.startLine,
            endLine: range.endLine,
            kind: range.kind
        )
    }

    // MARK: - Semantic tokens

    /// Decodes a `semanticTokens/full` response's relative-encoded `data`
    /// array into absolute UTF-8 byte ranges. A token whose decoded range
    /// falls outside the snapshot is skipped, and an out-of-legend token
    /// type is reported as `"unknown"` rather than dropping the token.
    static func semanticTokens(
        from tokens: SemanticTokens,
        legend: ServerCapabilities.SemanticTokensOptions.Legend,
        snapshot: SourceSnapshot,
        encoding: SourcePositionEncoding
    ) -> [SemanticToken] {
        var results: [SemanticToken] = []
        results.reserveCapacity(tokens.data.count / 5)

        var line = 0
        var character = 0
        var index = 0
        let data = tokens.data
        while index + 4 < data.count {
            let deltaLine = Int(data[index])
            let deltaStart = Int(data[index + 1])
            let length = Int(data[index + 2])
            let typeIndex = Int(data[index + 3])
            let modifierBits = data[index + 4]
            index += 5

            line += deltaLine
            character = deltaLine == 0 ? character + deltaStart : deltaStart
            guard line >= 0, character >= 0, length >= 0 else {
                continue
            }

            guard let startOffset = try? snapshot.utf8Offset(
                for: SourcePosition(line: line, character: character),
                encoding: encoding
            ) else {
                continue
            }
            let endPosition = SourcePosition(line: line, character: character + length)
            guard let endOffset = try? snapshot.utf8Offset(for: endPosition, encoding: encoding),
                  startOffset < endOffset else {
                continue
            }

            let tokenType = legend.tokenTypes.indices.contains(typeIndex)
                ? legend.tokenTypes[typeIndex]
                : "unknown"
            var modifiers: [String] = []
            for bit in 0..<legend.tokenModifiers.count where modifierBits & (1 << bit) != 0 {
                modifiers.append(legend.tokenModifiers[bit])
            }
            results.append(
                SemanticToken(
                    utf8Range: startOffset..<endOffset,
                    tokenType: tokenType,
                    tokenModifiers: modifiers
                )
            )
        }
        return results
    }
}
