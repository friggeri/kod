import Foundation
import SourceModel

// Provider-bound result identity (SPEC 6.1/6.3). A cross-file LSP result
// — a definition, a workspace symbol, a call/type hierarchy item — is only
// interpretable in the context of the exact language service instance and
// server generation that produced it: its `character` offsets are in that
// server's negotiated position encoding, and its opaque hierarchy `data`
// is meaningful to that process alone. Routing such a result by its target
// file URL instead can pick a different profile's server (a cross-language
// definition), or the same profile's *replacement* server after a restart,
// and then converts ranges with the wrong encoding or sends opaque data to
// a process that never issued it.

/// Stable identity of one live language provider: a logical profile
/// identity (`swift`, `typescript`, …) plus the identity of the concrete
/// service instance serving it. The logical part stays constant across a
/// service's own restarts; the instance part changes whenever the service
/// is replaced by a new one, so handles bound to a discarded service can
/// never be routed to its successor.
public struct LanguageProviderID: Hashable, Sendable, CustomStringConvertible {
    /// The logical provider identity — a `LanguageProfile.identifier` in
    /// the app, or the configured language id when no profile applies.
    public let profileIdentifier: String
    /// The concrete service instance behind that logical identity.
    public let instance: UUID

    public init(profileIdentifier: String, instance: UUID = UUID()) {
        self.profileIdentifier = profileIdentifier
        self.instance = instance
    }

    public var description: String {
        "\(profileIdentifier)#\(instance.uuidString)"
    }
}

/// Everything needed to interpret and re-route one cross-file result
/// without ever consulting its target URL: which provider produced it,
/// which server generation it came from, and the position encoding that
/// generation negotiated.
public struct LanguageProviderBinding: Equatable, Sendable {
    public let providerID: LanguageProviderID
    /// The provider's connection generation at the time the result was
    /// produced. Incremented by every start/restart/stop, so a handle from
    /// before a restart is detectably stale.
    public let generation: Int
    public let positionEncoding: SourcePositionEncoding

    public init(
        providerID: LanguageProviderID,
        generation: Int,
        positionEncoding: SourcePositionEncoding
    ) {
        self.providerID = providerID
        self.generation = generation
        self.positionEncoding = positionEncoding
    }

    /// Converts a wire range produced by this provider into a UTF-8 byte
    /// range inside `snapshot`, using the encoding this provider actually
    /// negotiated. Pure: never looks a service up by the target file's URL,
    /// so a cross-language target is converted with its *originating*
    /// server's encoding rather than the target file's.
    public func utf8Range(
        for range: LSPRange,
        in snapshot: SourceSnapshot
    ) -> Range<Int>? {
        guard let start = try? snapshot.utf8Offset(
            for: SourcePosition(
                line: range.start.line,
                character: range.start.character
            ),
            encoding: positionEncoding
        ), let end = try? snapshot.utf8Offset(
            for: SourcePosition(
                line: range.end.line,
                character: range.end.character
            ),
            encoding: positionEncoding
        ), start <= end else {
            return nil
        }
        return start..<end
    }
}

/// A cross-file location that remembers the provider it came from: the
/// navigable half of every provider-bound result.
public struct ProviderBoundLocation: Equatable, Sendable {
    public let provider: LanguageProviderBinding
    public let url: URL
    public let range: LSPRange

    public init(provider: LanguageProviderBinding, url: URL, range: LSPRange) {
        self.provider = provider
        self.url = url
        self.range = range
    }

    /// Converts this location's range against `snapshot` using the
    /// originating provider's negotiated encoding.
    public func utf8Range(in snapshot: SourceSnapshot) -> Range<Int>? {
        provider.utf8Range(for: range, in: snapshot)
    }
}

/// A result that carries its originating provider binding.
public protocol ProviderBoundResult {
    var provider: LanguageProviderBinding { get }
}

/// Typed failures for routing a provider-bound handle back to the service
/// that produced it. Never silently degraded into an empty result: a
/// hierarchy expansion that cannot reach its originating server is a real,
/// reportable condition, not "no results".
public enum LanguageProviderRoutingError: Error, Equatable, Sendable {
    /// No live service is registered for this provider: it was stopped,
    /// replaced, or trust was revoked.
    case providerUnavailable(LanguageProviderID)
    /// The provider is still live but has restarted (or stopped and
    /// started) since the handle was produced, so the handle's opaque data
    /// and ranges no longer describe anything the current server knows.
    case staleProviderResult(
        providerID: LanguageProviderID,
        resultGeneration: Int,
        currentGeneration: Int
    )
    /// A handle produced by one provider was submitted to another. Only
    /// reachable through direct service use; the router itself never
    /// misroutes.
    case providerMismatch(
        expected: LanguageProviderID,
        actual: LanguageProviderID
    )
}

/// Provider-ID-to-service routing table. Generic over the service type so
/// it stays platform-neutral and can be exercised directly with a pure
/// fake, rather than only through a live language service.
public struct LanguageProviderRouter<Service>: Sendable where Service: Sendable {
    private var servicesByProviderID: [LanguageProviderID: Service] = [:]

    public init() {}

    public var providerIDs: Set<LanguageProviderID> {
        Set(servicesByProviderID.keys)
    }

    public mutating func register(_ service: Service, for id: LanguageProviderID) {
        servicesByProviderID[id] = service
    }

    @discardableResult
    public mutating func unregister(_ id: LanguageProviderID) -> Service? {
        servicesByProviderID.removeValue(forKey: id)
    }

    public mutating func removeAll() {
        servicesByProviderID.removeAll()
    }

    public func service(for id: LanguageProviderID) -> Service? {
        servicesByProviderID[id]
    }

    /// Routes a bound result to its originating service, throwing rather
    /// than falling back to any other provider.
    public func service(
        for binding: LanguageProviderBinding
    ) throws -> Service {
        guard let service = servicesByProviderID[binding.providerID] else {
            throw LanguageProviderRoutingError.providerUnavailable(
                binding.providerID
            )
        }
        return service
    }
}
