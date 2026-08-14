import Foundation
import SettingsCore
import SourceModel

public enum LanguageProfileMatchKey: Sendable, Hashable {
    case exactFileName(String)
    case fileExtension(String)
    case contentMatcher(LanguageContentMatcher)
}

public struct ResolvedLanguageProfile: Sendable, Equatable {
    public let profile: LanguageProfile
    public let association: LanguageFileAssociation
    public let matchKey: LanguageProfileMatchKey

    public init(
        profile: LanguageProfile,
        association: LanguageFileAssociation,
        matchKey: LanguageProfileMatchKey
    ) {
        self.profile = profile
        self.association = association
        self.matchKey = matchKey
    }

    public var syntax: SyntaxDefinitionReference {
        association.syntax
    }

    public var languageID: String? {
        profile.languageServer?.languageID(for: association.identifier)
    }
}

public struct LanguageProfileConflict: Sendable, Equatable {
    public let matchKey: LanguageProfileMatchKey
    public let profileIdentifiers: [String]
    public let winningProfileIdentifier: String

    public init(
        matchKey: LanguageProfileMatchKey,
        profileIdentifiers: [String],
        winningProfileIdentifier: String
    ) {
        self.matchKey = matchKey
        self.profileIdentifiers = profileIdentifiers
        self.winningProfileIdentifier = winningProfileIdentifier
    }
}

public struct LanguageProfileRegistrySnapshot: Sendable {
    public let profiles: [LanguageProfile]
    public let conflicts: [LanguageProfileConflict]

    private let profilesByIdentifier: [String: LanguageProfile]
    private let exactFileNames: [String: [ResolvedLanguageProfile]]
    private let fileExtensions: [String: [ResolvedLanguageProfile]]
    private let contentMatchers: [
        LanguageContentMatcher: [ResolvedLanguageProfile]
    ]

    public init(profiles: [LanguageProfile]) {
        let enabledProfiles = profiles
            .filter(\.isEnabled)
            .sorted(by: Self.precedes)
        self.profiles = enabledProfiles
        self.profilesByIdentifier = Dictionary(
            enabledProfiles.map { ($0.identifier, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )

        var exactFileNames: [String: [ResolvedLanguageProfile]] = [:]
        var fileExtensions: [String: [ResolvedLanguageProfile]] = [:]
        var contentMatchers: [
            LanguageContentMatcher: [ResolvedLanguageProfile]
        ] = [:]
        for profile in enabledProfiles {
            for association in profile.associations {
                for fileName in association.exactFileNames {
                    exactFileNames[fileName, default: []].append(
                        ResolvedLanguageProfile(
                            profile: profile,
                            association: association,
                            matchKey: .exactFileName(fileName)
                        )
                    )
                }
                for fileExtension in association.fileExtensions {
                    fileExtensions[fileExtension, default: []].append(
                        ResolvedLanguageProfile(
                            profile: profile,
                            association: association,
                            matchKey: .fileExtension(fileExtension)
                        )
                    )
                }
                for matcher in association.contentMatchers {
                    contentMatchers[matcher, default: []].append(
                        ResolvedLanguageProfile(
                            profile: profile,
                            association: association,
                            matchKey: .contentMatcher(matcher)
                        )
                    )
                }
            }
        }
        self.exactFileNames = exactFileNames
        self.fileExtensions = fileExtensions
        self.contentMatchers = contentMatchers
        self.conflicts = Self.makeConflicts(
            exactFileNames: exactFileNames,
            fileExtensions: fileExtensions,
            contentMatchers: contentMatchers
        )
    }

    public func profile(identifier: String) -> LanguageProfile? {
        profilesByIdentifier[identifier.lowercased()]
    }

    public func resolve(url: URL) -> ResolvedLanguageProfile? {
        let fileName = url.lastPathComponent.lowercased()
        if let match = exactFileNames[fileName]?.first {
            return match
        }
        let fileExtension = url.pathExtension.lowercased()
        guard !fileExtension.isEmpty else {
            return nil
        }
        return fileExtensions[fileExtension]?.first
    }

    public func resolve(snapshot: SourceSnapshot) -> ResolvedLanguageProfile? {
        if let pathMatch = resolve(url: snapshot.url) {
            return pathMatch
        }
        for matcher in LanguageContentMatcher.allCasesInResolutionOrder {
            guard Self.matches(matcher, text: snapshot.text) else {
                continue
            }
            if let match = contentMatchers[matcher]?.first {
                return match
            }
        }
        return nil
    }

    public func conflicts(
        involving profileIdentifier: String
    ) -> [LanguageProfileConflict] {
        conflicts.filter {
            $0.profileIdentifiers.contains(profileIdentifier.lowercased())
        }
    }

    public func conflicts(
        for proposedProfile: LanguageProfile
    ) throws -> [LanguageProfileConflict] {
        let proposedProfile = try proposedProfile.validated()
        var proposedProfiles = profiles.filter {
            $0.identifier != proposedProfile.identifier
        }
        proposedProfiles.append(proposedProfile)
        return LanguageProfileRegistrySnapshot(profiles: proposedProfiles)
            .conflicts(involving: proposedProfile.identifier)
    }

    private static func precedes(
        _ lhs: LanguageProfile,
        _ rhs: LanguageProfile
    ) -> Bool {
        if lhs.lastModifiedOrder != rhs.lastModifiedOrder {
            return lhs.lastModifiedOrder > rhs.lastModifiedOrder
        }
        return lhs.identifier < rhs.identifier
    }

    private static func makeConflicts(
        exactFileNames: [String: [ResolvedLanguageProfile]],
        fileExtensions: [String: [ResolvedLanguageProfile]],
        contentMatchers: [
            LanguageContentMatcher: [ResolvedLanguageProfile]
        ]
    ) -> [LanguageProfileConflict] {
        var conflicts: [LanguageProfileConflict] = []
        for (fileName, matches) in exactFileNames where matches.count > 1 {
            conflicts.append(
                conflict(
                    matchKey: .exactFileName(fileName),
                    matches: matches
                )
            )
        }
        for (fileExtension, matches) in fileExtensions where matches.count > 1 {
            conflicts.append(
                conflict(
                    matchKey: .fileExtension(fileExtension),
                    matches: matches
                )
            )
        }
        for (matcher, matches) in contentMatchers where matches.count > 1 {
            conflicts.append(
                conflict(
                    matchKey: .contentMatcher(matcher),
                    matches: matches
                )
            )
        }
        return conflicts.sorted {
            sortKey(for: $0.matchKey) < sortKey(for: $1.matchKey)
        }
    }

    private static func conflict(
        matchKey: LanguageProfileMatchKey,
        matches: [ResolvedLanguageProfile]
    ) -> LanguageProfileConflict {
        LanguageProfileConflict(
            matchKey: matchKey,
            profileIdentifiers: matches.map(\.profile.identifier),
            winningProfileIdentifier: matches[0].profile.identifier
        )
    }

    private static func sortKey(for key: LanguageProfileMatchKey) -> String {
        switch key {
        case .exactFileName(let value):
            "0:\(value)"
        case .fileExtension(let value):
            "1:\(value)"
        case .contentMatcher(let matcher):
            "2:\(matcher.rawValue)"
        }
    }

    private static func matches(
        _ matcher: LanguageContentMatcher,
        text: String
    ) -> Bool {
        switch matcher {
        case .shellShebang:
            let firstLine = text.prefix(512)
                .split(whereSeparator: \.isNewline)
                .first?
                .lowercased() ?? ""
            guard firstLine.hasPrefix("#!") else {
                return false
            }
            return firstLine
                .split(whereSeparator: \.isWhitespace)
                .contains { token in
                    let executable = token
                        .split(separator: "/")
                        .last
                        .map(String.init) ?? String(token)
                    return executable == "sh" || executable == "bash"
                }
        }
    }
}

private extension LanguageContentMatcher {
    static let allCasesInResolutionOrder: [LanguageContentMatcher] = [
        .shellShebang
    ]
}

/// The runtime view of `LanguageProfileStore`: resolves an open file to
/// exactly one profile/association.
///
/// **Reload ownership:** the store observer installed here is the sole
/// reload trigger. `LanguageProfileStore` notifies every observer inside
/// its own mutation commit, so the registry's snapshot is already
/// current before this registry notifies its own observers. Consumers that
/// resolve through the registry observe the registry, not the underlying
/// store, so callback ordering in the store can never expose a stale snapshot.
/// Callers must therefore never call `reload()` themselves — an extra call is
/// redundant work, and relying on one hides the invariant that store mutation
/// is what refreshes this registry. `reload()` stays available only for tests
/// and for a store mutated before this registry existed.
@MainActor
public final class LanguageProfileRegistry {
    public let store: LanguageProfileStore
    public private(set) var snapshot: LanguageProfileRegistrySnapshot

    private var storeObserver: SettingsObservation?
    private var changeObservers: [
        UUID: @MainActor @Sendable () -> Void
    ] = [:]

    public init(store: LanguageProfileStore) {
        self.store = store
        self.snapshot = LanguageProfileRegistrySnapshot(
            profiles: store.profiles
        )
        self.storeObserver = store.observeChanges { [weak self] in
            self?.reload()
        }
    }

    /// Rebuilds the snapshot from the store. The store observer above is
    /// deliberately the only caller.
    private func reload() {
        snapshot = LanguageProfileRegistrySnapshot(profiles: store.profiles)
        for observer in changeObservers.values {
            observer()
        }
    }

    @discardableResult
    public func observeChanges(
        _ observer: @escaping @MainActor @Sendable () -> Void
    ) -> SettingsObservation {
        let id = UUID()
        changeObservers[id] = observer
        return SettingsObservation { [weak self] in
            Task { @MainActor [weak self] in
                self?.changeObservers.removeValue(forKey: id)
            }
        }
    }

    public func resolve(url: URL) -> ResolvedLanguageProfile? {
        snapshot.resolve(url: url)
    }

    public func resolve(
        snapshot sourceSnapshot: SourceSnapshot
    ) -> ResolvedLanguageProfile? {
        snapshot.resolve(snapshot: sourceSnapshot)
    }

    public func conflicts(
        for proposedProfile: LanguageProfile
    ) throws -> [LanguageProfileConflict] {
        try snapshot.conflicts(for: proposedProfile)
    }
}
