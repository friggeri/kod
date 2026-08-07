import Foundation

/// One versioned, installable managed server (or private runtime) as
/// described by the signed catalog (SPEC 6.5). `LanguageAdapterRegistry`
/// maps its own `languageKey`s onto a subset of these by `language`.
public struct ManagedServerCatalogEntry: Codable, Sendable, Equatable {
    /// Stable identifier, e.g. `"typescript-language-server"`,
    /// `"vscode-html-language-server"`, `"vscode-css-language-server"`,
    /// `"pyright"`, `"rust-analyzer"`, or `"node-runtime"` for the
    /// shared private Node runtime. Used as the on-disk directory name
    /// under `LanguageServers/` and as the `runtimeServerID` a
    /// dependent entry's `privateRuntime` points at.
    public let serverID: String

    /// The `LanguageAdapter.languageKey` this entry's server serves, or
    /// `nil` for a shared private runtime that is not itself a
    /// language server (e.g. `"node-runtime"`).
    public let language: String?

    public let version: SemanticVersion

    /// The lowest Kod app version that understands this entry's schema
    /// and can safely install/run it. `CatalogVerifier` filters out any
    /// entry whose `minimumKodVersion` exceeds the running Kod version,
    /// so an old Kod build talking to a newer catalog simply doesn't see
    /// entries it wouldn't know how to run, rather than crashing on an
    /// unrecognized field shape.
    public let minimumKodVersion: SemanticVersion

    /// Set by the release process to withdraw a specific version after
    /// publication (a vulnerability, a bad build) without needing to
    /// rotate the signing key. `ManagedInstallController` refuses to
    /// install, and reports as revoked, any entry with this set —
    /// including one a user already has active, which also becomes an
    /// "update required" state rather than continuing to run silently.
    public let revoked: Bool
    public let revocationReason: String?

    /// Per-architecture artifacts (at most one per `ManagedInstallArchitecture`
    /// — `CatalogVerifier` rejects a catalog with more than one artifact
    /// for the same architecture in one entry as malformed). A missing
    /// artifact for the running Mac's architecture is a normal,
    /// clearly-reported "unsupported combination" (SPEC 6.5), not an
    /// error.
    public let artifacts: [ManagedServerArtifact]

    /// Fixed launch arguments `LanguageAdapterRegistry` should use with
    /// this server once installed (mirrors the same field on
    /// `DiscoveredExecutable`/discovery-tier adapters, e.g. `["--stdio"]`).
    public let adapterArguments: [String]

    /// A fixed, catalog-declared environment-variable allowlist merged
    /// into the launched process's environment (SPEC 13.2: "Environment
    /// variables are allowlisted per adapter where practical") — e.g. a
    /// Node-based server may need `NODE_NO_WARNINGS=1`. Never derived
    /// from the opened workspace or the user's shell environment.
    public let adapterEnvironment: [String: String]

    public let privateRuntime: ManagedPrivateRuntimeRequirement?

    public init(
        serverID: String,
        language: String?,
        version: SemanticVersion,
        minimumKodVersion: SemanticVersion,
        revoked: Bool = false,
        revocationReason: String? = nil,
        artifacts: [ManagedServerArtifact],
        adapterArguments: [String] = [],
        adapterEnvironment: [String: String] = [:],
        privateRuntime: ManagedPrivateRuntimeRequirement? = nil
    ) {
        self.serverID = serverID
        self.language = language
        self.version = version
        self.minimumKodVersion = minimumKodVersion
        self.revoked = revoked
        self.revocationReason = revocationReason
        self.artifacts = artifacts
        self.adapterArguments = adapterArguments
        self.adapterEnvironment = adapterEnvironment
        self.privateRuntime = privateRuntime
    }

    private enum CodingKeys: String, CodingKey {
        case serverID, language, version, minimumKodVersion, revoked, revocationReason, artifacts, adapterArguments, adapterEnvironment, privateRuntime
    }

    /// A custom decode so a hand-authored or template-generated catalog
    /// JSON (`Scripts/managed-install-signing`'s reproducible generation
    /// process) can omit any field that has a sensible default here —
    /// `revoked`, `revocationReason`, `adapterArguments`,
    /// `adapterEnvironment`, `privateRuntime` — without needing every
    /// entry in a hand-written catalog to spell out `"revoked": false,
    /// "adapterArguments": [], "adapterEnvironment": {}` explicitly.
    /// Every field with no reasonable default (`serverID`, `language`,
    /// `version`, `minimumKodVersion`, `artifacts`) remains required —
    /// omitting one of those is still a decode error.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverID = try container.decode(String.self, forKey: .serverID)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        version = try container.decode(SemanticVersion.self, forKey: .version)
        minimumKodVersion = try container.decode(SemanticVersion.self, forKey: .minimumKodVersion)
        revoked = try container.decodeIfPresent(Bool.self, forKey: .revoked) ?? false
        revocationReason = try container.decodeIfPresent(String.self, forKey: .revocationReason)
        artifacts = try container.decode([ManagedServerArtifact].self, forKey: .artifacts)
        adapterArguments = try container.decodeIfPresent([String].self, forKey: .adapterArguments) ?? []
        adapterEnvironment = try container.decodeIfPresent([String: String].self, forKey: .adapterEnvironment) ?? [:]
        privateRuntime = try container.decodeIfPresent(ManagedPrivateRuntimeRequirement.self, forKey: .privateRuntime)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(serverID, forKey: .serverID)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encode(version, forKey: .version)
        try container.encode(minimumKodVersion, forKey: .minimumKodVersion)
        try container.encode(revoked, forKey: .revoked)
        try container.encodeIfPresent(revocationReason, forKey: .revocationReason)
        try container.encode(artifacts, forKey: .artifacts)
        try container.encode(adapterArguments, forKey: .adapterArguments)
        try container.encode(adapterEnvironment, forKey: .adapterEnvironment)
        try container.encodeIfPresent(privateRuntime, forKey: .privateRuntime)
    }

    public func artifact(for architecture: ManagedInstallArchitecture) -> ManagedServerArtifact? {
        artifacts.first { $0.architecture == architecture }
    }
}

/// The full signed catalog document body (the bytes that get signed are
/// this struct's canonical JSON encoding — see `CatalogCanonicalization`).
public struct ManagedServerCatalog: Codable, Sendable, Equatable {
    /// Schema version of the catalog document itself (not any one
    /// entry's `version`). Bumped only on a breaking format change.
    public let catalogFormatVersion: Int
    public let generatedAt: Date
    public let entries: [ManagedServerCatalogEntry]

    public init(catalogFormatVersion: Int = 1, generatedAt: Date, entries: [ManagedServerCatalogEntry]) {
        self.catalogFormatVersion = catalogFormatVersion
        self.generatedAt = generatedAt
        self.entries = entries
    }

    public func entry(serverID: String) -> ManagedServerCatalogEntry? {
        entries.first { $0.serverID == serverID }
    }

    public func latestEntry(language: String) -> ManagedServerCatalogEntry? {
        entries
            .filter { $0.language == language && !$0.revoked }
            .max { $0.version < $1.version }
    }
}
