import Foundation

// Cross-file results that carry the provider binding they were produced
// under (SPEC 6.1/6.3). None of these is guaranteed to point inside a
// snapshot Kod currently holds — or even inside a file the producing
// provider owns — so they stay in wire form and are resolved to byte
// offsets only once (if) a caller opens the target file, always through
// `provider`'s negotiated encoding rather than whatever server happens
// to own that file.

/// A `workspace/symbol` or cross-file `definition`/`references`/
/// hierarchy result, kept in wire form (URI + LSP position) since Kod
/// does not necessarily have the target file's `SourceSnapshot` loaded
/// yet; a caller resolves it to a byte offset only once (if) it actually
/// opens that file — through the `provider` binding that produced it, so
/// the resolution uses the originating server's negotiated encoding
/// rather than whatever server happens to own the target file.
public struct WorkspaceSymbolLocation: Equatable, Sendable, ProviderBoundResult {
    public let provider: LanguageProviderBinding
    public let url: URL
    public let range: LSPRange
    public let name: String
    public let kind: SymbolKind
    public let containerName: String?

    public init(
        provider: LanguageProviderBinding,
        url: URL,
        range: LSPRange,
        name: String,
        kind: SymbolKind,
        containerName: String?
    ) {
        self.provider = provider
        self.url = url
        self.range = range
        self.name = name
        self.kind = kind
        self.containerName = containerName
    }

    public var location: ProviderBoundLocation {
        ProviderBoundLocation(provider: provider, url: url, range: range)
    }
}

/// A structurally-validated cross-file navigation target: a same-process
/// absolute `file://` URI with a non-negative, non-inverted range, bound
/// to the provider that produced it. Used for definition/declaration/
/// type-definition/implementation/references, none of which are guaranteed
/// to point inside the currently open snapshot — or even inside a file
/// this provider owns — so full UTF-8 byte-offset validation happens once
/// (if) a caller actually opens the target file's own snapshot, always
/// through `provider`'s negotiated encoding.
public struct NavigationTarget: Equatable, Sendable, ProviderBoundResult {
    public let provider: LanguageProviderBinding
    public let url: URL
    public let range: LSPRange

    public init(provider: LanguageProviderBinding, url: URL, range: LSPRange) {
        self.provider = provider
        self.url = url
        self.range = range
    }

    public var location: ProviderBoundLocation {
        ProviderBoundLocation(provider: provider, url: url, range: range)
    }
}

/// A `CallHierarchyItem`/`TypeHierarchyItem`, structurally validated like
/// `NavigationTarget` (its `uri`/`range` need not be inside the currently
/// open snapshot) with its opaque `data` preserved verbatim so it can be
/// sent back unmodified in a follow-up `incomingCalls`/`outgoingCalls`/
/// `supertypes`/`subtypes` request — but only ever to the provider
/// generation named by `provider`, since opaque data means nothing to any
/// other server process.
public struct ValidatedHierarchyItem: Equatable, Sendable, ProviderBoundResult {
    public let provider: LanguageProviderBinding
    public let name: String
    public let kind: SymbolKind
    public let detail: String?
    public let url: URL
    public let range: LSPRange
    public let selectionRange: LSPRange
    public let data: JSONValue?

    public init(
        provider: LanguageProviderBinding,
        name: String,
        kind: SymbolKind,
        detail: String?,
        url: URL,
        range: LSPRange,
        selectionRange: LSPRange,
        data: JSONValue?
    ) {
        self.provider = provider
        self.name = name
        self.kind = kind
        self.detail = detail
        self.url = url
        self.range = range
        self.selectionRange = selectionRange
        self.data = data
    }

    public var location: ProviderBoundLocation {
        ProviderBoundLocation(provider: provider, url: url, range: range)
    }

    /// The narrower "name" range, which is what navigation selects.
    public var selectionLocation: ProviderBoundLocation {
        ProviderBoundLocation(
            provider: provider,
            url: url,
            range: selectionRange
        )
    }
}

/// `fromRanges` are call sites inside `from`'s own document, in the same
/// provider generation and encoding as `from` itself.
public struct ValidatedIncomingCall: Equatable, Sendable, ProviderBoundResult {
    public let from: ValidatedHierarchyItem
    public let fromRanges: [LSPRange]

    public init(from: ValidatedHierarchyItem, fromRanges: [LSPRange]) {
        self.from = from
        self.fromRanges = fromRanges
    }

    public var provider: LanguageProviderBinding {
        from.provider
    }

    public var fromLocations: [ProviderBoundLocation] {
        fromRanges.map {
            ProviderBoundLocation(provider: from.provider, url: from.url, range: $0)
        }
    }
}

/// Per LSP, an outgoing call's `fromRanges` are call sites inside the
/// *requested* item's document rather than `to`'s, so they are left as
/// wire ranges here; `to.provider` still names the generation and
/// encoding they were produced in.
public struct ValidatedOutgoingCall: Equatable, Sendable, ProviderBoundResult {
    public let to: ValidatedHierarchyItem
    public let fromRanges: [LSPRange]

    public init(to: ValidatedHierarchyItem, fromRanges: [LSPRange]) {
        self.to = to
        self.fromRanges = fromRanges
    }

    public var provider: LanguageProviderBinding {
        to.provider
    }
}
