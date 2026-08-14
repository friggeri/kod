import Foundation
import SourceModel

// The capability-gated read-only request surface (SPEC 6.1). Split out
// of `LanguageWorkspaceService.swift` so the actor's state machines and
// lifecycle stay readable; every method here still runs under the same
// actor isolation and goes through the same document, encoding, and
// provider validation helpers.

extension LanguageWorkspaceService {
    // MARK: - Requests

    public func hover(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> Hover? {
        let connection = try connected()
        try documents.requireOpenAndCurrent(snapshot)
        let encoding = await resolvedPositionEncoding()
        let position = try snapshot.position(forUTF8Offset: utf8Offset, encoding: encoding)

        let hover: Hover? = try await connection.sendRequest(
            .hover,
            params: HoverParams(
                textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: snapshot.url)),
                position: LSPPosition(line: position.line, character: position.character)
            ),
            priority: .interactive
        )
        guard let hover else {
            return nil
        }
        // A hover range outside the (possibly now-stale) snapshot is
        // discarded rather than shown against the wrong text (SPEC 6.3).
        if let range = hover.range,
           LSPRangeNormalizer.utf8Range(range, in: snapshot, encoding: encoding) == nil {
            return Hover(contents: hover.contents, range: nil)
        }
        return hover
    }

    public func definition(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> [NavigationTarget] {
        try await navigationRequest(
            .definition,
            snapshot: snapshot,
            utf8Offset: utf8Offset,
            priority: .interactive
        ) { (result: DefinitionResult) in
            result.locations
        }
    }

    public func declaration(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> [NavigationTarget] {
        let advertised = await capabilities()?.declarationProvider?.isEnabled == true
        guard await isAvailable(.declaration, staticallyAdvertised: advertised) else {
            throw LanguageWorkspaceServiceError.capabilityUnavailable("textDocument/declaration")
        }
        return try await navigationRequest(.declaration, snapshot: snapshot, utf8Offset: utf8Offset) { (result: DeclarationResult) in
            result.locations
        }
    }

    public func typeDefinition(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> [NavigationTarget] {
        let advertised = await capabilities()?.typeDefinitionProvider?.isEnabled == true
        guard await isAvailable(.typeDefinition, staticallyAdvertised: advertised) else {
            throw LanguageWorkspaceServiceError.capabilityUnavailable("textDocument/typeDefinition")
        }
        return try await navigationRequest(.typeDefinition, snapshot: snapshot, utf8Offset: utf8Offset) { (result: TypeDefinitionResult) in
            result.locations
        }
    }

    public func implementation(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> [NavigationTarget] {
        let advertised = await capabilities()?.implementationProvider?.isEnabled == true
        guard await isAvailable(.implementation, staticallyAdvertised: advertised) else {
            throw LanguageWorkspaceServiceError.capabilityUnavailable("textDocument/implementation")
        }
        return try await navigationRequest(.implementation, snapshot: snapshot, utf8Offset: utf8Offset) { (result: ImplementationResult) in
            result.locations
        }
    }

    private func navigationRequest<Result: Decodable & Sendable>(
        _ method: LanguageClientOutboundMethod,
        snapshot: SourceSnapshot,
        utf8Offset: Int,
        priority: LanguageClientRequestPriority = .normal,
        locations: (Result) -> [LSPLocation]
    ) async throws -> [NavigationTarget] {
        let connection = try connected()
        try documents.requireOpenAndCurrent(snapshot)
        let request = try await captureProviderRequest(connection: connection)
        let encoding = request.binding.positionEncoding
        let position = try snapshot.position(forUTF8Offset: utf8Offset, encoding: encoding)

        let result: Result = try await connection.sendRequest(
            method,
            params: TextDocumentPositionParams(
                textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: snapshot.url)),
                position: LSPPosition(line: position.line, character: position.character)
            ),
            priority: priority
        )
        try await validateProviderResponse(request)
        return locations(result).compactMap {
            ProviderBoundResultBuilder.navigationTarget($0, binding: request.binding)
        }
    }

    public func references(snapshot: SourceSnapshot, utf8Offset: Int, includeDeclaration: Bool) async throws -> [NavigationTarget] {
        let connection = try connected()
        try documents.requireOpenAndCurrent(snapshot)
        let request = try await captureProviderRequest(connection: connection)
        let encoding = request.binding.positionEncoding
        let position = try snapshot.position(forUTF8Offset: utf8Offset, encoding: encoding)

        let locations: ReferenceResult = try await connection.sendRequest(
            .references,
            params: ReferenceParams(
                textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: snapshot.url)),
                position: LSPPosition(line: position.line, character: position.character),
                context: ReferenceContext(includeDeclaration: includeDeclaration)
            )
        )
        try await validateProviderResponse(request)
        return (locations ?? []).compactMap {
            ProviderBoundResultBuilder.navigationTarget($0, binding: request.binding)
        }
    }

    public func documentHighlights(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> [ValidatedDocumentHighlight] {
        let advertised = await capabilities()?.documentHighlightProvider?.isEnabled == true
        guard await isAvailable(.documentHighlight, staticallyAdvertised: advertised) else {
            throw LanguageWorkspaceServiceError.capabilityUnavailable("textDocument/documentHighlight")
        }
        let connection = try connected()
        try documents.requireOpenAndCurrent(snapshot)
        let encoding = await resolvedPositionEncoding()
        let position = try snapshot.position(forUTF8Offset: utf8Offset, encoding: encoding)

        let highlights: DocumentHighlightResult = try await connection.sendRequest(
            .documentHighlight,
            params: TextDocumentPositionParams(
                textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: snapshot.url)),
                position: LSPPosition(line: position.line, character: position.character)
            )
        )
        return highlights.compactMap { highlight in
            guard let range = LSPRangeNormalizer.utf8Range(
                highlight.range,
                in: snapshot,
                encoding: encoding
            ) else {
                return nil
            }
            return ValidatedDocumentHighlight(utf8Range: range, kind: highlight.kind)
        }
    }

    public func documentSymbols(snapshot: SourceSnapshot) async throws -> [ValidatedDocumentSymbol] {
        let connection = try connected()
        try documents.requireOpenAndCurrent(snapshot)
        let encoding = await resolvedPositionEncoding()

        let result: DocumentSymbolResult = try await connection.sendRequest(
            .documentSymbol,
            params: DocumentSymbolParams(textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: snapshot.url)))
        )

        switch result {
        case .none:
            return []
        case .hierarchical(let symbols):
            return symbols.compactMap {
                LSPRangeNormalizer.validatedDocumentSymbol(
                    $0,
                    snapshot: snapshot,
                    encoding: encoding
                )
            }
        case .flat(let symbols):
            return symbols.compactMap {
                LSPRangeNormalizer.validatedDocumentSymbol(
                    $0,
                    snapshot: snapshot,
                    encoding: encoding
                )
            }
        }
    }

    public func workspaceSymbols(query: String) async throws -> [WorkspaceSymbolLocation] {
        let connection = try connected()
        let request = try await captureProviderRequest(connection: connection)
        let results: WorkspaceSymbolResult = try await connection.sendRequest(
            .workspaceSymbol,
            params: WorkspaceSymbolParams(query: query)
        )
        try await validateProviderResponse(request)
        return results.compactMap { info -> WorkspaceSymbolLocation? in
            // Defensive: never surface a "workspace" symbol whose server-
            // reported location falls outside the trusted workspace root.
            guard let url = confinement.confinedFileURL(for: info.location.uri) else {
                return nil
            }
            return WorkspaceSymbolLocation(
                provider: request.binding,
                url: url,
                range: info.location.range,
                name: info.name,
                kind: info.kind,
                containerName: info.containerName
            )
        }
    }

    /// Pull diagnostics (`textDocument/diagnostic`). Capability-gated:
    /// throws `.capabilityUnavailable` rather than silently returning
    /// nothing when the server never advertised `diagnosticProvider`, so
    /// callers can report the exact limitation instead of assuming "no
    /// problems" (per the no-silent-fallback requirement).
    public func pullDiagnostics(snapshot: SourceSnapshot) async throws -> [Diagnostic] {
        let connection = try connected()
        try documents.requireOpenAndCurrent(snapshot)
        guard await connection.serverCapabilities?.diagnosticProvider != nil else {
            throw LanguageWorkspaceServiceError.capabilityUnavailable("textDocument/diagnostic (pull diagnostics)")
        }
        let report: DocumentDiagnosticReport = try await connection.sendRequest(
            .diagnostic,
            params: DocumentDiagnosticParams(textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: snapshot.url)))
        )
        guard report.kind == "full" else {
            return []
        }
        return report.items ?? []
    }

    /// Capability-gated full semantic tokens for `snapshot`. Throws
    /// `.capabilityUnavailable` when the server never advertised
    /// `semanticTokensProvider.full`. Range/delta semantic tokens are not
    /// implemented in this phase; that limitation is reported the same
    /// way rather than silently downgraded to nothing.
    public func semanticTokens(snapshot: SourceSnapshot) async throws -> [SemanticToken] {
        let connection = try connected()
        try documents.requireOpenAndCurrent(snapshot)
        guard let provider = await connection.serverCapabilities?.semanticTokensProvider,
              provider.full?.isEnabled == true else {
            throw LanguageWorkspaceServiceError.capabilityUnavailable("textDocument/semanticTokens/full")
        }
        let legend = provider.legend
        let encoding = await resolvedPositionEncoding()

        let tokens: SemanticTokens = try await connection.sendRequest(
            .semanticTokensFull,
            params: SemanticTokensParams(textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: snapshot.url))),
            priority: .background
        )
        return LSPRangeNormalizer.semanticTokens(
            from: tokens,
            legend: legend,
            snapshot: snapshot,
            encoding: encoding
        )
    }

    public func foldingRanges(snapshot: SourceSnapshot) async throws -> [ValidatedFoldingRange] {
        let advertised = await capabilities()?.foldingRangeProvider?.isEnabled == true
        guard await isAvailable(.foldingRange, staticallyAdvertised: advertised) else {
            throw LanguageWorkspaceServiceError.capabilityUnavailable("textDocument/foldingRange")
        }
        let connection = try connected()
        try documents.requireOpenAndCurrent(snapshot)

        let ranges: FoldingRangeResult = try await connection.sendRequest(
            .foldingRange,
            params: FoldingRangeParams(textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: snapshot.url)))
        )
        return ranges.compactMap {
            LSPRangeNormalizer.validatedFoldingRange($0, snapshot: snapshot)
        }
    }

    public func selectionRanges(snapshot: SourceSnapshot, utf8Offsets: [Int]) async throws -> [ValidatedSelectionRange] {
        let advertised = await capabilities()?.selectionRangeProvider?.isEnabled == true
        guard await isAvailable(.selectionRange, staticallyAdvertised: advertised) else {
            throw LanguageWorkspaceServiceError.capabilityUnavailable("textDocument/selectionRange")
        }
        let connection = try connected()
        try documents.requireOpenAndCurrent(snapshot)
        let encoding = await resolvedPositionEncoding()
        let positions = try utf8Offsets.map { offset -> LSPPosition in
            let position = try snapshot.position(forUTF8Offset: offset, encoding: encoding)
            return LSPPosition(line: position.line, character: position.character)
        }

        let result: SelectionRangeResult = try await connection.sendRequest(
            .selectionRange,
            params: SelectionRangeParams(
                textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: snapshot.url)),
                positions: positions
            )
        )
        return result.compactMap {
            LSPRangeNormalizer.validatedSelectionRange(
                $0,
                snapshot: snapshot,
                encoding: encoding
            )
        }
    }

    public func documentLinks(snapshot: SourceSnapshot) async throws -> [ValidatedDocumentLink] {
        let advertised = await capabilities()?.documentLinkProvider?.isEnabled == true
        guard await isAvailable(.documentLink, staticallyAdvertised: advertised) else {
            throw LanguageWorkspaceServiceError.capabilityUnavailable("textDocument/documentLink")
        }
        let connection = try connected()
        try documents.requireOpenAndCurrent(snapshot)
        let encoding = await resolvedPositionEncoding()

        let links: DocumentLinkResult? = try await connection.sendRequest(
            .documentLink,
            params: DocumentLinkParams(textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: snapshot.url)))
        )
        return (links ?? []).compactMap { link -> ValidatedDocumentLink? in
            guard let safeLink = SafeDocumentLink.validating(link),
                  let range = LSPRangeNormalizer.utf8Range(
                    link.range,
                    in: snapshot,
                    encoding: encoding
                  ) else {
                return nil
            }
            return ValidatedDocumentLink(utf8Range: range, target: safeLink.target, tooltip: safeLink.tooltip)
        }
    }

    public func inlayHints(snapshot: SourceSnapshot, utf8Range requestedRange: Range<Int>) async throws -> [ValidatedInlayHint] {
        let advertised = await capabilities()?.inlayHintProvider?.isEnabled == true
        guard await isAvailable(.inlayHint, staticallyAdvertised: advertised) else {
            throw LanguageWorkspaceServiceError.capabilityUnavailable("textDocument/inlayHint")
        }
        let connection = try connected()
        try documents.requireOpenAndCurrent(snapshot)
        let encoding = await resolvedPositionEncoding()
        let startPosition = try snapshot.position(forUTF8Offset: requestedRange.lowerBound, encoding: encoding)
        let endPosition = try snapshot.position(forUTF8Offset: requestedRange.upperBound, encoding: encoding)

        let hints: InlayHintResult = try await connection.sendRequest(
            .inlayHint,
            params: InlayHintParams(
                textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: snapshot.url)),
                range: LSPRange(
                    start: LSPPosition(line: startPosition.line, character: startPosition.character),
                    end: LSPPosition(line: endPosition.line, character: endPosition.character)
                )
            )
        )
        return (hints ?? []).compactMap { hint -> ValidatedInlayHint? in
            guard let offset = LSPRangeNormalizer.utf8Offset(
                for: hint.position,
                in: snapshot,
                encoding: encoding
            ) else {
                return nil
            }
            return ValidatedInlayHint(
                utf8Offset: offset,
                label: hint.label.displayText,
                kind: hint.kind,
                paddingLeft: hint.paddingLeft ?? false,
                paddingRight: hint.paddingRight ?? false
            )
        }
    }

    /// Explicit-request-only signature help (SPEC 6.1): Kod calls this
    /// only in direct response to a user action on the currently
    /// selected symbol, never automatically while typing.
    ///
    /// Transport failures (timeout, disconnect, malformed response)
    /// propagate: `nil` here means the server answered with a valid empty
    /// result, never that the request failed silently.
    public func signatureHelp(snapshot: SourceSnapshot, utf8Offset: Int) async throws -> SignatureHelp? {
        let advertised = await capabilities()?.signatureHelpProvider?.isEnabled == true
        guard await isAvailable(.signatureHelp, staticallyAdvertised: advertised) else {
            throw LanguageWorkspaceServiceError.capabilityUnavailable("textDocument/signatureHelp")
        }
        let connection = try connected()
        try documents.requireOpenAndCurrent(snapshot)
        let encoding = await resolvedPositionEncoding()
        let position = try snapshot.position(forUTF8Offset: utf8Offset, encoding: encoding)

        return try await connection.sendRequest(
            .signatureHelp,
            params: SignatureHelpParams(
                textDocument: TextDocumentIdentifier(uri: DocumentURI(fileURL: snapshot.url)),
                position: LSPPosition(line: position.line, character: position.character)
            )
        )
    }
}
