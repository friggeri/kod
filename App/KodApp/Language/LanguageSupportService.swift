import Combine
import Foundation
import LanguageAdapters
import SettingsCore
import SourceModel
import SyntaxCore

extension Notification.Name {
    static let kodLanguageSupportChanged = Notification.Name(
        "KodLanguageSupportChanged"
    )
}

/// Distinguishes why `.kodLanguageSupportChanged` was posted, so
/// observers can react precisely instead of treating every change the
/// same way.
enum LanguageSupportChangeKind: String {
    /// A shipped profile's command changed — i.e. Kod should replace any
    /// running service with one using the new executable and arguments.
    case profileConfiguration
    /// `LanguageSupportService.refresh()` discovered that a profile's
    /// executable, previously unavailable, is now available — i.e.
    /// nothing about the profile changed, only whether Kod can find it.
    case executableDiscovery
}

extension Notification {
    /// The profile identifier a `.kodLanguageSupportChanged` notification
    /// concerns. `nil` for any other notification.
    var languageSupportChangedKey: String? {
        userInfo?["languageKey"] as? String
    }

    /// The reason a `.kodLanguageSupportChanged` notification was posted.
    /// Defaults to `.profileConfiguration` for older/unknown payloads so
    /// existing observers keep their current (safe) behavior.
    var languageSupportChangeKind: LanguageSupportChangeKind {
        (userInfo?["changeKind"] as? String)
            .flatMap(LanguageSupportChangeKind.init(rawValue:))
            ?? .profileConfiguration
    }
}

enum LanguageSupportServerState: Equatable {
    case syntaxOnly
    case checking
    case available(DiscoveredExecutable)
    case missing(String)

    var isAvailable: Bool {
        if case .available = self {
            return true
        }
        return false
    }
}

struct LanguageSupportItem: Identifiable, Equatable {
    let profile: LanguageProfile
    var serverState: LanguageSupportServerState

    var id: String {
        profile.identifier
    }
}

enum LanguageServerExecutableSelection {
    static func arguments(
        for url: URL,
        configuration: LanguageServerConfiguration?,
        fallback: [String]
    ) -> [String] {
        configuration?.executableCandidates.first(where: {
            $0.executableNames.contains(url.lastPathComponent)
        })?.arguments ?? configuration?.selectedExecutable?.arguments
            ?? configuration?.executableCandidates.first?.arguments
            ?? fallback
    }
}

@MainActor
final class LanguageSupportService: ObservableObject {
    typealias Discovery = @Sendable (
        LanguageProfile,
        LanguageServerOverrideStore
    ) throws -> DiscoveredExecutable
    private typealias ContextualDiscovery = @Sendable (
        LanguageProfile,
        LanguageServerOverrideStore,
        String?
    ) throws -> DiscoveredExecutable

    static let serverDirectoryURL: URL = {
        guard let url = URL(
            string: "https://microsoft.github.io/language-server-protocol/implementors/servers/"
        ) else {
            preconditionFailure("The language server directory URL is invalid")
        }
        return url
    }()

    @Published private(set) var items: [LanguageSupportItem] = []
    @Published private(set) var refreshingProfileIdentifiers: Set<String> = []
    @Published private(set) var focusedProfileIdentifier: String?
    @Published private(set) var focusRequestRevision = 0
    @Published var errorMessage: String?

    let profileStore: LanguageProfileStore
    let profileRegistry: LanguageProfileRegistry
    let overrideStore: LanguageServerOverrideStore

    private let discovery: ContextualDiscovery
    private let requiresLoginShellPathCapture: Bool
    private let loginShellPathCapture: @Sendable () -> String?
    private let statusCacheStore: LanguageServerStatusCacheStore?
    private var cachedStatuses: [String: CachedLanguageServerStatus] = [:]
    private var profileRefreshFingerprints: [
        String: LanguageProfileRefreshFingerprint
    ] = [:]
    private var profileObserver: SettingsObservation?
    private var refreshGenerations: [String: UInt64] = [:]
    private var activeRefreshes: [UUID: Set<String>] = [:]

    init(
        profileStore: LanguageProfileStore,
        overrideStore: LanguageServerOverrideStore,
        statusCacheStore: LanguageServerStatusCacheStore? = nil,
        loginShellPathCapture: @escaping @Sendable () -> String? = {
            LoginShellPathCapture.capture()
        },
        discovery: Discovery? = nil
    ) {
        self.profileStore = profileStore
        self.profileRegistry = LanguageProfileRegistry(store: profileStore)
        self.overrideStore = overrideStore
        self.statusCacheStore = statusCacheStore
        self.loginShellPathCapture = loginShellPathCapture
        if let discovery {
            self.requiresLoginShellPathCapture = false
            self.discovery = { profile, overrideStore, _ in
                try discovery(profile, overrideStore)
            }
        } else {
            self.requiresLoginShellPathCapture = true
            self.discovery = { profile, overrideStore, loginShellPath in
                try LanguageServerDiscoveryEngine.resolve(
                    profile: profile,
                    overrideStore: overrideStore,
                    identity: nil,
                    loginShellPath: { loginShellPath }
                )
            }
        }
        if let statusCacheStore {
            do {
                cachedStatuses = try statusCacheStore.load()
            } catch {
                cachedStatuses = [:]
                errorMessage = error.localizedDescription
            }
        }
        pruneCachedStatuses()
        profileRefreshFingerprints = Self.refreshFingerprints(
            for: profileStore.profiles
        )
        rebuildItems(preservingPriorStates: false)
        self.profileObserver = profileStore.observeChanges { [weak self] in
            guard let self else {
                return
            }
            self.supersedeRefreshesForChangedProfiles()
            self.pruneCachedStatuses()
            self.rebuildItems(preservingPriorStates: false)
        }
    }

    func refresh(profileIdentifier: String? = nil) async {
        guard !Task.isCancelled else {
            return
        }
        let profiles = profileStore.profiles.filter { profile in
            profile.languageServer != nil
                && (
                    profileIdentifier == nil
                        || profile.identifier == profileIdentifier
                )
        }
        guard !profiles.isEmpty else {
            return
        }
        let profileIdentifiers = Set(profiles.map(\.identifier))
        let operationIdentifier = UUID()
        activeRefreshes[operationIdentifier] = profileIdentifiers
        updateRefreshingProfileIdentifiers()
        defer {
            activeRefreshes.removeValue(forKey: operationIdentifier)
            updateRefreshingProfileIdentifiers()
        }
        var generations: [String: UInt64] = [:]
        for identifier in profileIdentifiers {
            refreshGenerations[identifier, default: 0] &+= 1
            generations[identifier] = refreshGenerations[identifier]
        }
        let loginShellPath: String?
        if requiresLoginShellPathCapture {
            let loginShellPathCapture = loginShellPathCapture
            loginShellPath = await Task.detached(priority: .utility) {
                loginShellPathCapture()
            }.value
        } else {
            loginShellPath = nil
        }
        guard !Task.isCancelled else {
            return
        }
        let discovery = discovery
        let overrideStore = overrideStore
        let results = await withTaskGroup(
            of: LanguageProfileDiscoveryResult?.self,
            returning: [LanguageProfileDiscoveryResult].self
        ) { group in
            for profile in profiles {
                group.addTask {
                    guard !Task.isCancelled else {
                        return nil
                    }
                    do {
                        let result = LanguageProfileDiscoveryResult(
                            profileIdentifier: profile.identifier,
                            executable: try discovery(
                                profile,
                                overrideStore,
                                loginShellPath
                            ),
                            errorDescription: nil
                        )
                        return Task.isCancelled ? nil : result
                    } catch {
                        guard !Task.isCancelled else {
                            return nil
                        }
                        return LanguageProfileDiscoveryResult(
                            profileIdentifier: profile.identifier,
                            executable: nil,
                            errorDescription: error.localizedDescription
                        )
                    }
                }
            }
            var values: [LanguageProfileDiscoveryResult] = []
            for await value in group {
                if let value {
                    values.append(value)
                }
            }
            return values
        }
        guard !Task.isCancelled else {
            return
        }

        var identifiersWithNewlyAvailableExecutables: [String] = []
        var cacheChanged = false
        var updatedItems = items
        for result in results {
            let identifier = result.profileIdentifier
            guard refreshGenerations[identifier]
                    == generations[identifier],
                  let index = updatedItems.firstIndex(where: {
                      $0.id == identifier
                  }) else {
                continue
            }
            let profile = updatedItems[index].profile
            guard profile.languageServer != nil else {
                updatedItems[index].serverState = .syntaxOnly
                continue
            }
            let previousState = updatedItems[index].serverState
            if let executable = result.executable {
                updatedItems[index].serverState = .available(executable)
                cachedStatuses[identifier] = .available(
                    executable,
                    profile: profile
                )
                cacheChanged = true
                if !previousState.isAvailable {
                    identifiersWithNewlyAvailableExecutables.append(
                        identifier
                    )
                }
            } else {
                updatedItems[index].serverState = .missing(
                    result.errorDescription
                        ?? String(
                            localized: "No compatible language server was found."
                        )
                )
                cachedStatuses[identifier] = .missing(
                        profile: profile
                )
                cacheChanged = true
            }
        }
        if updatedItems != items {
            items = updatedItems
        }
        if cacheChanged {
            persistCachedStatuses()
        }
        for identifier in identifiersWithNewlyAvailableExecutables {
            postExecutableDiscoveryChange(for: identifier)
        }
    }

    func isRefreshing(profileIdentifier: String) -> Bool {
        refreshingProfileIdentifiers.contains(profileIdentifier)
    }

    func setCommand(
        _ command: String,
        profileIdentifier: String
    ) throws {
        let executable = try LanguageServerCommandLine.parse(command)
        if let executable {
            try Self.validateExecutable(atPath: executable.path)
        }
        guard var profile = profileStore.profile(
            identifier: profileIdentifier
        ) else {
            throw LanguageProfileStoreError.profileNotFound(profileIdentifier)
        }
        guard var configuration = profile.languageServer else {
            throw LanguageServerDiscoveryError.profileHasNoLanguageServer(
                profile.displayName
            )
        }
        configuration.selectedExecutable = executable
        profile.languageServer = configuration
        _ = try profileStore.updateProfile(profile)
        invalidateCachedStatus(profileIdentifier: profileIdentifier)
        postProfileConfigurationChange(for: profileIdentifier)
    }

    func setSelectedExecutable(
        profileIdentifier: String,
        url: URL
    ) throws {
        try Self.validateExecutable(atPath: url.path)
        guard var profile = profileStore.profile(
            identifier: profileIdentifier
        ) else {
            throw LanguageProfileStoreError.profileNotFound(profileIdentifier)
        }
        guard var configuration = profile.languageServer else {
            throw LanguageServerDiscoveryError.profileHasNoLanguageServer(
                profile.displayName
            )
        }
        let arguments = LanguageServerExecutableSelection.arguments(
            for: url,
            configuration: configuration,
            fallback: []
        )
        configuration.selectedExecutable =
            RegisteredLanguageServerExecutable(
                path: url.standardizedFileURL.path,
                arguments: arguments
            )
        profile.languageServer = configuration
        _ = try profileStore.updateProfile(profile)
        invalidateCachedStatus(profileIdentifier: profileIdentifier)
        postProfileConfigurationChange(for: profileIdentifier)
    }

    func focusProfile(identifier: String?) {
        focusedProfileIdentifier = identifier
        focusRequestRevision += 1
    }

    func syntaxLanguage(for snapshot: SourceSnapshot) -> SyntaxLanguage? {
        guard let resolved = profileRegistry.resolve(snapshot: snapshot) else {
            return nil
        }
        switch resolved.syntax {
        case .treeSitter(let language):
            return language
        case .plainText:
            return nil
        }
    }

    func report(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    private func rebuildItems(
        preservingPriorStates: Bool = true
    ) {
        let priorStates = preservingPriorStates
            ? Dictionary(
                uniqueKeysWithValues: items.map {
                    ($0.id, $0.serverState)
                }
            )
            : [:]
        items = profileStore.profiles.map { profile in
            LanguageSupportItem(
                profile: profile,
                serverState: Self.serverState(
                    for: profile,
                    priorState: priorStates[profile.identifier],
                    cachedState: cachedStatuses[
                        profile.identifier
                    ]?.serverState(for: profile)
                )
            )
        }
    }

    private func updateRefreshingProfileIdentifiers() {
        refreshingProfileIdentifiers = activeRefreshes.values.reduce(
            into: []
        ) { identifiers, active in
            identifiers.formUnion(active)
        }
    }

    private static func serverState(
        for profile: LanguageProfile,
        priorState: LanguageSupportServerState?,
        cachedState: LanguageSupportServerState?
    ) -> LanguageSupportServerState {
        guard profile.languageServer != nil else {
            return .syntaxOnly
        }
        switch priorState {
        case .available, .checking, .missing:
            return priorState ?? .checking
        case .syntaxOnly, nil:
            return cachedState ?? .checking
        }
    }

    private func pruneCachedStatuses() {
        let previousStatuses = cachedStatuses
        let profilesByIdentifier = Dictionary(
            uniqueKeysWithValues: profileStore.profiles.map {
                ($0.identifier, $0)
            }
        )
        cachedStatuses = cachedStatuses.filter { identifier, status in
            guard let profile = profilesByIdentifier[identifier],
                  profile.languageServer != nil else {
                return false
            }
            return status.serverState(for: profile) != nil
        }
        if cachedStatuses != previousStatuses {
            persistCachedStatuses()
        }
    }

    private func supersedeRefreshesForChangedProfiles() {
        let currentFingerprints = Self.refreshFingerprints(
            for: profileStore.profiles
        )
        let identifiers = Set(profileRefreshFingerprints.keys)
            .union(currentFingerprints.keys)
        for identifier in identifiers
        where profileRefreshFingerprints[identifier]
            != currentFingerprints[identifier] {
            refreshGenerations[identifier, default: 0] &+= 1
        }
        profileRefreshFingerprints = currentFingerprints
    }

    private static func refreshFingerprints(
        for profiles: [LanguageProfile]
    ) -> [String: LanguageProfileRefreshFingerprint] {
        Dictionary(
            uniqueKeysWithValues: profiles.map { profile in
                (
                    profile.identifier,
                    LanguageProfileRefreshFingerprint(
                        defaultRevision: profile.defaultRevision,
                        selectedExecutable:
                            profile.languageServer?.selectedExecutable,
                        hasLanguageServer: profile.languageServer != nil
                    )
                )
            }
        )
    }

    private func invalidateCachedStatus(profileIdentifier: String) {
        guard cachedStatuses.removeValue(
            forKey: profileIdentifier
        ) != nil else {
            return
        }
        persistCachedStatuses()
        if let index = items.firstIndex(where: {
            $0.id == profileIdentifier
        }) {
            items[index].serverState = .checking
        }
    }

    private func persistCachedStatuses() {
        guard let statusCacheStore else {
            return
        }
        do {
            try statusCacheStore.save(cachedStatuses)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Posted when Command changes. UI observers refresh prompts; the profile
    /// registry observes the store and the workspace coordinator observes that
    /// registry so lifecycle replacement happens exactly once.
    private func postProfileConfigurationChange(for profileIdentifier: String) {
        postChange(for: profileIdentifier, kind: .profileConfiguration)
    }

    /// Posted only when a completed `refresh()` finds that
    /// `profileIdentifier`'s executable, previously unavailable, is now
    /// available. Observers must retry/restart the affected language
    /// service without reloading the profile registry or calling
    /// `refresh()` again, to avoid a notify → refresh → notify loop.
    private func postExecutableDiscoveryChange(for profileIdentifier: String) {
        postChange(for: profileIdentifier, kind: .executableDiscovery)
    }

    private func postChange(
        for profileIdentifier: String,
        kind: LanguageSupportChangeKind
    ) {
        NotificationCenter.default.post(
            name: .kodLanguageSupportChanged,
            object: self,
            userInfo: [
                "languageKey": profileIdentifier,
                "changeKind": kind.rawValue
            ]
        )
    }

    private static func validateExecutable(atPath path: String) throws {
        let resolvedPath = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: resolvedPath
        )
        guard attributes?[.type] as? FileAttributeType == .typeRegular,
              FileManager.default.isExecutableFile(atPath: resolvedPath) else {
            throw LanguageProfileExecutableError.notExecutable(path)
        }
    }

}

private struct LanguageProfileRefreshFingerprint: Equatable {
    let defaultRevision: Int
    let selectedExecutable: RegisteredLanguageServerExecutable?
    let hasLanguageServer: Bool
}

private struct LanguageProfileDiscoveryResult: Sendable {
    let profileIdentifier: String
    let executable: DiscoveredExecutable?
    let errorDescription: String?
}

private enum LanguageProfileExecutableError: LocalizedError {
    case notExecutable(String)

    var errorDescription: String? {
        switch self {
        case .notExecutable(let path):
            String(localized: "The selected file is not executable: \(path)")
        }
    }
}
