import Combine
import Foundation
import LanguageAdapters
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
    /// A profile's configuration was edited, enabled/disabled, reset,
    /// deleted, or given an explicit executable — i.e. anything that can
    /// change *what* Kod should launch or *how* files map to it.
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
    case notConfigured
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
    let syntaxDescription: String
    let conflicts: [LanguageProfileConflict]
    var serverState: LanguageSupportServerState

    var id: String {
        profile.identifier
    }
}

enum LanguageProfileSaveResult: Equatable {
    case saved(LanguageProfile)
    case requiresConflictConfirmation([LanguageProfileConflict])
}

struct LanguageAssociationDraft: Identifiable, Equatable {
    let id: UUID
    var identifier: String
    var fileExtensions: String
    var exactFileNames: String
    var syntaxLanguage: SyntaxLanguage?
    var languageID: String
    var contentMatchers: [LanguageContentMatcher]

    init(
        id: UUID = UUID(),
        identifier: String,
        fileExtensions: String,
        exactFileNames: String,
        syntaxLanguage: SyntaxLanguage?,
        languageID: String,
        contentMatchers: [LanguageContentMatcher] = []
    ) {
        self.id = id
        self.identifier = identifier
        self.fileExtensions = fileExtensions
        self.exactFileNames = exactFileNames
        self.syntaxLanguage = syntaxLanguage
        self.languageID = languageID
        self.contentMatchers = contentMatchers
    }
}

struct LanguageProfileDraft: Identifiable, Equatable {
    let id: UUID
    let originalProfile: LanguageProfile?
    var identifier: String
    var displayName: String
    var isEnabled: Bool
    var associations: [LanguageAssociationDraft]
    var languageServerEnabled: Bool
    var defaultLanguageID: String
    var executablePath: String
    var arguments: [String]

    init(profile: LanguageProfile) {
        let configuration = profile.languageServer
        self.id = UUID()
        self.originalProfile = profile
        self.identifier = profile.identifier
        self.displayName = profile.displayName
        self.isEnabled = profile.isEnabled
        self.associations = profile.associations.map { association in
            let syntaxLanguage: SyntaxLanguage?
            switch association.syntax {
            case .treeSitter(let language):
                syntaxLanguage = language
            case .plainText:
                syntaxLanguage = nil
            }
            return LanguageAssociationDraft(
                identifier: association.identifier,
                fileExtensions: association.fileExtensions.joined(
                    separator: ", "
                ),
                exactFileNames: association.exactFileNames.joined(
                    separator: ", "
                ),
                syntaxLanguage: syntaxLanguage,
                languageID: configuration?.languageID(
                    for: association.identifier
                ) ?? "",
                contentMatchers: association.contentMatchers
            )
        }
        self.languageServerEnabled = configuration != nil
        self.defaultLanguageID = configuration?.defaultLanguageID ?? ""
        self.executablePath = configuration?.selectedExecutable?.path ?? ""
        self.arguments = configuration?.selectedExecutable?.arguments ?? []
    }

    init(prefilling url: URL? = nil) {
        let fileExtension = url?.pathExtension.lowercased() ?? ""
        let fileName = url?.lastPathComponent.lowercased() ?? ""
        let name = fileExtension.isEmpty
            ? (fileName.isEmpty
                ? String(localized: "Custom Language")
                : fileName)
            : fileExtension.uppercased()
        self.id = UUID()
        self.originalProfile = nil
        self.identifier = "custom-\(UUID().uuidString.lowercased())"
        self.displayName = name
        self.isEnabled = true
        self.associations = [
            LanguageAssociationDraft(
                identifier: "files",
                fileExtensions: fileExtension,
                exactFileNames: fileExtension.isEmpty ? fileName : "",
                syntaxLanguage: nil,
                languageID: ""
            )
        ]
        self.languageServerEnabled = false
        self.defaultLanguageID = fileExtension
        self.executablePath = ""
        self.arguments = []
    }

    func makeProfile() throws -> LanguageProfile {
        let associations = associations.enumerated().map {
            index,
            draft in
            let identifier = draft.identifier.isEmpty
                ? "files-\(index + 1)"
                : draft.identifier
            let syntax: SyntaxDefinitionReference = draft.syntaxLanguage.map {
                .treeSitter($0)
            } ?? .plainText
            return LanguageFileAssociation(
                identifier: identifier,
                fileExtensions: Self.list(from: draft.fileExtensions),
                exactFileNames: Self.list(from: draft.exactFileNames),
                contentMatchers: draft.contentMatchers,
                syntax: syntax
            )
        }

        var languageServer: LanguageServerConfiguration?
        if languageServerEnabled {
            let defaultLanguageID =
                self.defaultLanguageID.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            var configuration = originalProfile?.languageServer
                ?? LanguageServerConfiguration(
                    defaultLanguageID: defaultLanguageID,
                    executableCandidates: []
                )
            configuration.defaultLanguageID = defaultLanguageID
            configuration.languageIDOverrides = zip(
                associations,
                self.associations
            ).reduce(into: [:]) { overrides, pair in
                let (association, draft) = pair
                let languageID = draft.languageID.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !languageID.isEmpty,
                      languageID != defaultLanguageID else {
                    return
                }
                overrides[association.identifier] = languageID
            }
            let path = executablePath.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            configuration.selectedExecutable = path.isEmpty
                ? nil
                : RegisteredLanguageServerExecutable(
                    path: path,
                    arguments: arguments
                )
            languageServer = configuration
        }

        let profile = LanguageProfile(
            identifier: identifier,
            displayName: displayName,
            isEnabled: isEnabled,
            origin: originalProfile?.origin ?? .custom,
            defaultRevision: originalProfile?.defaultRevision ?? 1,
            lastModifiedOrder: originalProfile?.lastModifiedOrder ?? 0,
            associations: associations,
            languageServer: languageServer
        )
        return try profile.validated()
    }

    private static func list(from value: String) -> [String] {
        value
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }
}

@MainActor
final class LanguageSupportService: ObservableObject {
    typealias Discovery = @Sendable (
        LanguageProfile,
        LanguageServerOverrideStore
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
    @Published private(set) var isRefreshing = false
    @Published var requestedProfileDraft: LanguageProfileDraft?
    @Published var focusedProfileIdentifier: String?
    @Published var errorMessage: String?

    let profileStore: LanguageProfileStore
    let profileRegistry: LanguageProfileRegistry
    let overrideStore: LanguageServerOverrideStore

    private let discovery: Discovery
    private var profileObserver: UUID?
    /// Strictly increases on every `refresh()` call so a slower,
    /// superseded refresh can detect it finished after a newer one and
    /// avoid overwriting/notifying with its now-stale results.
    private var refreshGeneration = 0

    convenience init() {
        let overrideStore = LanguageServerOverrideStore()
        do {
            let profileStore = try LanguageProfileStore(
                overrideStore: overrideStore
            )
            self.init(
                profileStore: profileStore,
                overrideStore: overrideStore
            )
        } catch {
            preconditionFailure(
                "Could not initialize language profiles: \(error)"
            )
        }
    }

    init(
        profileStore: LanguageProfileStore,
        overrideStore: LanguageServerOverrideStore,
        discovery: @escaping Discovery = { profile, overrideStore in
            try LanguageServerDiscoveryEngine.resolve(
                profile: profile,
                overrideStore: overrideStore,
                identity: nil
            )
        }
    ) {
        self.profileStore = profileStore
        self.profileRegistry = LanguageProfileRegistry(store: profileStore)
        self.overrideStore = overrideStore
        self.discovery = discovery
        rebuildItems()
        self.profileObserver = profileStore.observeChanges { [weak self] in
            guard let self else {
                return
            }
            self.profileRegistry.reload()
            self.rebuildItems()
            Task {
                await self.refresh()
            }
        }
    }

    func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isRefreshing = true
        defer {
            // Only clear `isRefreshing` if no newer refresh has since
            // started; otherwise this stale completion would incorrectly
            // report the newer, still-running refresh as finished.
            if generation == refreshGeneration {
                isRefreshing = false
            }
        }
        rebuildItems()

        let profiles = profileStore.profiles.filter {
            $0.isEnabled && $0.languageServer != nil
        }
        let discovery = discovery
        let overrideStore = overrideStore
        let results = await withTaskGroup(
            of: LanguageProfileDiscoveryResult.self,
            returning: [LanguageProfileDiscoveryResult].self
        ) { group in
            for profile in profiles {
                group.addTask {
                    do {
                        return LanguageProfileDiscoveryResult(
                            profileIdentifier: profile.identifier,
                            executable: try discovery(profile, overrideStore),
                            errorDescription: nil
                        )
                    } catch {
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
                values.append(value)
            }
            return values
        }

        guard generation == refreshGeneration else {
            // A newer refresh has already started (or finished) since
            // this one began; its results supersede ours, so this
            // slower/stale refresh must not overwrite `items` or notify.
            return
        }

        let resultsByIdentifier = Dictionary(
            uniqueKeysWithValues: results.map {
                ($0.profileIdentifier, $0)
            }
        )
        var identifiersWithNewlyAvailableExecutables: [String] = []
        for index in items.indices {
            let profile = items[index].profile
            guard profile.isEnabled, profile.languageServer != nil else {
                items[index].serverState = .notConfigured
                continue
            }
            let previousState = items[index].serverState
            if let executable = resultsByIdentifier[
                profile.identifier
            ]?.executable {
                items[index].serverState = .available(executable)
                if !previousState.isAvailable {
                    identifiersWithNewlyAvailableExecutables.append(
                        profile.identifier
                    )
                }
            } else {
                items[index].serverState = .missing(
                    resultsByIdentifier[profile.identifier]?.errorDescription
                        ?? String(
                            localized: "No compatible language server was found."
                        )
                )
            }
        }
        for identifier in identifiersWithNewlyAvailableExecutables {
            postExecutableDiscoveryChange(for: identifier)
        }
    }

    func beginAddingProfile(prefilling url: URL? = nil) {
        requestedProfileDraft = LanguageProfileDraft(prefilling: url)
    }

    func beginEditingProfile(identifier: String) {
        guard let profile = profileStore.profile(identifier: identifier) else {
            errorMessage = LanguageProfileStoreError.profileNotFound(
                identifier
            ).localizedDescription
            return
        }
        requestedProfileDraft = LanguageProfileDraft(profile: profile)
    }

    func save(
        draft: LanguageProfileDraft,
        confirmConflicts: Bool = false
    ) throws -> LanguageProfileSaveResult {
        let profile = try draft.makeProfile()
        let conflicts = try profileRegistry.snapshot.conflicts(
            for: profile
        )
        if !conflicts.isEmpty, !confirmConflicts {
            return .requiresConflictConfirmation(conflicts)
        }

        let saved: LanguageProfile
        if draft.originalProfile == nil {
            saved = try profileStore.createCustomProfile(profile)
        } else {
            saved = try profileStore.updateProfile(profile)
        }
        requestedProfileDraft = nil
        focusedProfileIdentifier = saved.identifier
        postProfileConfigurationChange(for: saved.identifier)
        return .saved(saved)
    }

    func setEnabled(_ isEnabled: Bool, identifier: String) throws {
        _ = try profileStore.setEnabled(isEnabled, identifier: identifier)
        postProfileConfigurationChange(for: identifier)
    }

    func resetDefault(identifier: String) throws {
        _ = try profileStore.resetDefaultProfile(identifier: identifier)
        postProfileConfigurationChange(for: identifier)
    }

    func deleteCustom(identifier: String) throws {
        try profileStore.deleteCustomProfile(identifier: identifier)
        postProfileConfigurationChange(for: identifier)
    }

    func setSelectedExecutable(
        profileIdentifier: String,
        url: URL
    ) throws {
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw LanguageProfileExecutableError.notExecutable(url.path)
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
        let arguments = configuration.executableCandidates.first(where: {
            $0.executableNames.contains(url.lastPathComponent)
        })?.arguments ?? configuration.selectedExecutable?.arguments
            ?? configuration.executableCandidates.first?.arguments
            ?? []
        configuration.selectedExecutable =
            RegisteredLanguageServerExecutable(
                path: url.standardizedFileURL.path,
                arguments: arguments
            )
        profile.languageServer = configuration
        _ = try profileStore.updateProfile(profile)
        postProfileConfigurationChange(for: profileIdentifier)
    }

    func useAutoDetectedExecutable(profileIdentifier: String) throws {
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
        configuration.selectedExecutable = nil
        profile.languageServer = configuration
        _ = try profileStore.updateProfile(profile)
        postProfileConfigurationChange(for: profileIdentifier)
    }

    func focusProfile(identifier: String?) {
        focusedProfileIdentifier = identifier
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

    private func rebuildItems() {
        let snapshot = LanguageProfileRegistrySnapshot(
            profiles: profileStore.profiles
        )
        let priorStates = Dictionary(
            uniqueKeysWithValues: items.map { ($0.id, $0.serverState) }
        )
        items = profileStore.profiles.map { profile in
            LanguageSupportItem(
                profile: profile,
                syntaxDescription: Self.syntaxDescription(profile),
                conflicts: snapshot.conflicts(
                    involving: profile.identifier
                ),
                serverState: priorStates[profile.identifier]
                    ?? (profile.languageServer == nil
                        ? .notConfigured
                        : .checking)
            )
        }
    }

    /// Posted for profile CRUD/enable/reset/executable-selection changes.
    /// Observers (e.g. `WorkspaceViewController`) treat this as a reason
    /// to reload the profile registry and, if a service is already
    /// running for `profileIdentifier`, restart it.
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

    private static func syntaxDescription(
        _ profile: LanguageProfile
    ) -> String {
        profile.associations.map { association in
            let patterns = association.fileExtensions.map { "*.\($0)" }
                + association.exactFileNames
            let syntaxName: String
            switch association.syntax {
            case .treeSitter(let language):
                syntaxName = language.displayName
            case .plainText:
                syntaxName = String(localized: "Plain Text")
            }
            return "\(patterns.joined(separator: ", ")): \(syntaxName)"
        }
        .joined(separator: " • ")
    }
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
