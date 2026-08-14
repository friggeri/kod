import Foundation
import SourceModel

/// One in-flight request, stamped with the provider binding it was
/// issued under and the exact connection object it was issued to.
/// Generic over the connection so the validation rules can be exercised
/// directly with a plain object rather than a live language server.
struct LanguageProviderRequest<Connection: AnyObject> {
    let connection: Connection
    let binding: LanguageProviderBinding
}

/// Validates that a provider-bound handle or an in-flight response still
/// belongs to the live server generation (SPEC 6.1/6.3).
///
/// Two distinct failures exist and both are reported, never silently
/// degraded into an empty result:
///
/// * A handle produced by a *different* provider — `providerMismatch`.
/// * A handle (or a response that was in flight across a suspension
///   point) from a generation this provider has since replaced by a
///   restart or a stop — `staleProviderResult`. Opaque hierarchy `data`
///   from a dead generation must never reach its successor process, and
///   ranges from it are in that process's negotiated encoding only.
///
/// Pure: it compares values the caller supplies, and holds no state of
/// its own beyond the provider identity it speaks for.
struct LanguageProviderRequestValidator {
    let providerID: LanguageProviderID

    init(providerID: LanguageProviderID) {
        self.providerID = providerID
    }

    /// The binding a request issued right now is stamped with.
    func binding(
        generation: Int,
        positionEncoding: SourcePositionEncoding
    ) -> LanguageProviderBinding {
        LanguageProviderBinding(
            providerID: providerID,
            generation: generation,
            positionEncoding: positionEncoding
        )
    }

    /// Rejects a handle this service cannot honor: one produced by a
    /// different provider, or by a superseded generation of this one.
    func requireCurrentProvider(
        _ binding: LanguageProviderBinding,
        currentGeneration: Int
    ) throws {
        guard binding.providerID == providerID else {
            throw LanguageProviderRoutingError.providerMismatch(
                expected: providerID,
                actual: binding.providerID
            )
        }
        try requireCurrentGeneration(
            binding.generation,
            currentGeneration: currentGeneration
        )
    }

    /// Rejects a request whose generation or connection has been
    /// replaced since it was captured — the check performed both before
    /// sending and after the response arrives.
    func requireCurrent<Connection: AnyObject>(
        _ request: LanguageProviderRequest<Connection>,
        currentGeneration: Int,
        currentConnection: Connection?
    ) throws {
        guard request.connection === currentConnection else {
            throw LanguageProviderRoutingError.staleProviderResult(
                providerID: providerID,
                resultGeneration: request.binding.generation,
                currentGeneration: currentGeneration
            )
        }
        try requireCurrentGeneration(
            request.binding.generation,
            currentGeneration: currentGeneration
        )
    }

    private func requireCurrentGeneration(
        _ generation: Int,
        currentGeneration: Int
    ) throws {
        guard generation == currentGeneration else {
            throw LanguageProviderRoutingError.staleProviderResult(
                providerID: providerID,
                resultGeneration: generation,
                currentGeneration: currentGeneration
            )
        }
    }
}

/// Builds the provider-bound, structurally validated results a service
/// hands out for cross-file navigation. Structural-only by design: these
/// targets need not point inside any snapshot Kod currently holds, so
/// full UTF-8 byte-offset validation happens once (if) a caller actually
/// opens the target file — always through the binding recorded here.
enum ProviderBoundResultBuilder {
    static func navigationTarget(
        _ location: LSPLocation,
        binding: LanguageProviderBinding
    ) -> NavigationTarget? {
        guard let url = location.uri.fileURL,
              LSPRangeNormalizer.isStructurallyValid(location.range) else {
            return nil
        }
        return NavigationTarget(provider: binding, url: url, range: location.range)
    }

    static func hierarchyItem(
        _ item: CallHierarchyItem,
        binding: LanguageProviderBinding
    ) -> ValidatedHierarchyItem? {
        hierarchyItem(
            name: item.name,
            kind: item.kind,
            detail: item.detail,
            uri: item.uri,
            range: item.range,
            selectionRange: item.selectionRange,
            data: item.data,
            binding: binding
        )
    }

    static func hierarchyItem(
        _ item: TypeHierarchyItem,
        binding: LanguageProviderBinding
    ) -> ValidatedHierarchyItem? {
        hierarchyItem(
            name: item.name,
            kind: item.kind,
            detail: item.detail,
            uri: item.uri,
            range: item.range,
            selectionRange: item.selectionRange,
            data: item.data,
            binding: binding
        )
    }

    /// Re-wraps a previously validated item back into its wire shape for
    /// a follow-up request, carrying its opaque `data` through completely
    /// unmodified (never inspected or reconstructed).
    static func wireCallHierarchyItem(
        _ item: ValidatedHierarchyItem
    ) -> CallHierarchyItem {
        CallHierarchyItem(
            name: item.name,
            kind: item.kind,
            detail: item.detail,
            uri: DocumentURI(fileURL: item.url),
            range: item.range,
            selectionRange: item.selectionRange,
            data: item.data
        )
    }

    static func wireTypeHierarchyItem(
        _ item: ValidatedHierarchyItem
    ) -> TypeHierarchyItem {
        TypeHierarchyItem(
            name: item.name,
            kind: item.kind,
            detail: item.detail,
            uri: DocumentURI(fileURL: item.url),
            range: item.range,
            selectionRange: item.selectionRange,
            data: item.data
        )
    }

    private static func hierarchyItem(
        name: String,
        kind: SymbolKind,
        detail: String?,
        uri: DocumentURI,
        range: LSPRange,
        selectionRange: LSPRange,
        data: JSONValue?,
        binding: LanguageProviderBinding
    ) -> ValidatedHierarchyItem? {
        guard let url = uri.fileURL,
              LSPRangeNormalizer.isStructurallyValid(range),
              LSPRangeNormalizer.isStructurallyValid(selectionRange) else {
            return nil
        }
        return ValidatedHierarchyItem(
            provider: binding,
            name: name,
            kind: kind,
            detail: detail,
            url: url,
            range: range,
            selectionRange: selectionRange,
            data: data
        )
    }
}
