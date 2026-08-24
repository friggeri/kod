import Foundation
import SettingsCore

public enum LanguageProfileStoreLoadStatus: Sendable, Equatable {
    case fresh
    case restored
    case rebuiltAfterQuarantine(reason: String)
}

public enum LanguageProfileStoreError: Error, Sendable, Equatable {
    case duplicateProfileIdentifier(String)
    case profileNotFound(String)
    case defaultProfileExpected(String)
    case immutableIdentity
}

extension LanguageProfileStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .duplicateProfileIdentifier(let identifier):
            "A language profile with identifier \(identifier) already exists."
        case .profileNotFound(let identifier):
            "Language profile \(identifier) was not found."
        case .defaultProfileExpected(let identifier):
            "Language profile \(identifier) is not a default profile."
        case .immutableIdentity:
            "A language profile's identifier, origin, and default revision cannot be changed."
        }
    }
}

private struct PersistedLanguageProfileRecord: Codable, Sendable {
    var profile: LanguageProfile
    var isCustomized: Bool
}

private struct PersistedLanguageProfileState: Codable, Sendable {
    static let currentSchemaVersion = 3

    var schemaVersion: Int
    var nextModifiedOrder: UInt64
    var didMigrateGlobalOverrides: Bool
    var records: [PersistedLanguageProfileRecord]

    init(
        nextModifiedOrder: UInt64,
        didMigrateGlobalOverrides: Bool,
        records: [PersistedLanguageProfileRecord]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.nextModifiedOrder = nextModifiedOrder
        self.didMigrateGlobalOverrides = didMigrateGlobalOverrides
        self.records = records
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case nextModifiedOrder
        case didMigrateGlobalOverrides
        case records
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try container.decode(
            Int.self,
            forKey: .schemaVersion
        )
        guard (1...Self.currentSchemaVersion).contains(
            decodedSchemaVersion
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription:
                    "Unsupported language profile schema version \(decodedSchemaVersion)"
            )
        }
        schemaVersion = Self.currentSchemaVersion
        nextModifiedOrder = try container.decode(
            UInt64.self,
            forKey: .nextModifiedOrder
        )
        didMigrateGlobalOverrides = try container.decode(
            Bool.self,
            forKey: .didMigrateGlobalOverrides
        )
        let decodedRecords = try container.decode(
            [PersistedLanguageProfileRecord].self,
            forKey: .records
        )

        var identifiers = Set<String>()
        do {
            records = try decodedRecords.map { record in
                var record = record
                record.profile = try record.profile.validated()
                guard identifiers.insert(record.profile.identifier).inserted else {
                    throw LanguageProfileStoreError
                        .duplicateProfileIdentifier(record.profile.identifier)
                }
                return record
            }
        } catch let error as LanguageProfileValidationError {
            throw DecodingError.dataCorruptedError(
                forKey: .records,
                in: container,
                debugDescription: String(describing: error)
            )
        } catch let error as LanguageProfileStoreError {
            throw DecodingError.dataCorruptedError(
                forKey: .records,
                in: container,
                debugDescription: String(describing: error)
            )
        }
    }
}

@MainActor
public final class LanguageProfileStore {
    private let repository: CodableSettingsRepository
    private let persistenceKey: String
    private let overrideStore: LanguageServerOverrideStore
    private var defaultProfilesByIdentifier: [String: LanguageProfile]
    private var recordsByIdentifier: [String: PersistedLanguageProfileRecord] = [:]
    private var nextModifiedOrder: UInt64 = 1
    private var didMigrateGlobalOverrides = false
    private var changeObservers: [UUID: ChangeObserver] = [:]

    public private(set) var loadStatus: LanguageProfileStoreLoadStatus = .fresh

    public convenience init(
        defaultProfiles: [LanguageProfile] = DefaultLanguageProfiles.all,
        repository: CodableSettingsRepository,
        persistenceKey: String = "kod.language-profiles"
    ) throws {
        try self.init(
            defaultProfiles: defaultProfiles,
            repository: repository,
            overrideStore: LanguageServerOverrideStore(
                repository: repository
            ),
            persistenceKey: persistenceKey
        )
    }

    public init(
        defaultProfiles: [LanguageProfile] = DefaultLanguageProfiles.all,
        repository: CodableSettingsRepository,
        overrideStore: LanguageServerOverrideStore,
        persistenceKey: String = "kod.language-profiles"
    ) throws {
        self.repository = repository
        self.persistenceKey = persistenceKey
        self.overrideStore = overrideStore

        let validatedDefaults = try defaultProfiles.map { proposedProfile in
            let profile = try proposedProfile.validated()
            guard profile.origin == .default else {
                throw LanguageProfileStoreError
                    .defaultProfileExpected(profile.identifier)
            }
            return profile
        }
        var defaultProfilesByIdentifier: [String: LanguageProfile] = [:]
        for profile in validatedDefaults {
            guard defaultProfilesByIdentifier[profile.identifier] == nil else {
                throw LanguageProfileStoreError
                    .duplicateProfileIdentifier(profile.identifier)
            }
            defaultProfilesByIdentifier[profile.identifier] = profile
        }
        self.defaultProfilesByIdentifier = defaultProfilesByIdentifier

        let restoredState: PersistedLanguageProfileState?
        switch try repository.read(persistedStateSetting) {
        case .value(let state, _):
            restoredState = state
            loadStatus = .restored
        case .absent:
            restoredState = nil
            loadStatus = .fresh
        case .quarantined(let record):
            restoredState = nil
            loadStatus = .rebuiltAfterQuarantine(reason: record.reason)
        }

        merge(restoredState: restoredState)
        let migrationWasNeeded = !didMigrateGlobalOverrides
        let migratedIdentifiers = try migrateGlobalOverridesIfNeeded()
        try persist()
        for identifier in migratedIdentifiers {
            try self.overrideStore.clearGlobalOverride(
                languageKey: identifier
            )
        }
        if migrationWasNeeded {
            didMigrateGlobalOverrides = true
            try persist()
        }
    }

    public var quarantine: SettingsQuarantine {
        repository.quarantine
    }

    public var profiles: [LanguageProfile] {
        recordsByIdentifier.values
            .map(\.profile)
            .sorted { lhs, rhs in
                if lhs.origin != rhs.origin {
                    return lhs.origin == .default
                }
                let nameOrdering = lhs.displayName.localizedCaseInsensitiveCompare(
                    rhs.displayName
                )
                if nameOrdering != .orderedSame {
                    return nameOrdering == .orderedAscending
                }
                return lhs.identifier < rhs.identifier
            }
    }

    public func profile(identifier: String) -> LanguageProfile? {
        recordsByIdentifier[identifier.lowercased()]?.profile
    }

    public func isCustomized(identifier: String) -> Bool? {
        recordsByIdentifier[identifier.lowercased()]?.isCustomized
    }

    /// Registers `observer`, called synchronously inside every successful
    /// mutation commit. The returned token owns the registration and cancels
    /// it when released.
    @discardableResult
    public func observeChanges(
        _ observer: @escaping @MainActor @Sendable () -> Void
    ) -> SettingsObservation {
        let identifier = UUID()
        let state = ChangeObserverState()
        changeObservers[identifier] = ChangeObserver(
            state: state,
            callback: observer
        )
        return SettingsObservation {
            state.cancel()
        }
    }

    @discardableResult
    public func updateProfile(
        _ proposedProfile: LanguageProfile
    ) throws -> LanguageProfile {
        let proposedProfile = try proposedProfile.validated()
        guard let existing = recordsByIdentifier[
            proposedProfile.identifier
        ] else {
            throw LanguageProfileStoreError.profileNotFound(
                proposedProfile.identifier
            )
        }
        guard proposedProfile.origin == existing.profile.origin,
              proposedProfile.defaultRevision
                == existing.profile.defaultRevision else {
            throw LanguageProfileStoreError.immutableIdentity
        }
        guard var profile = defaultProfilesByIdentifier[
            proposedProfile.identifier
        ] else {
            throw LanguageProfileStoreError.defaultProfileExpected(
                proposedProfile.identifier
            )
        }
        let selectedExecutable = proposedProfile.languageServer?
            .selectedExecutable
        if var configuration = profile.languageServer {
            configuration.selectedExecutable = selectedExecutable
            profile.languageServer = configuration
        }
        profile.lastModifiedOrder = existing.profile.lastModifiedOrder
        try commit(
            replacing: profile.identifier,
            with: PersistedLanguageProfileRecord(
                profile: profile,
                isCustomized: selectedExecutable != nil
            )
        )
        return profile
    }

    private func merge(restoredState: PersistedLanguageProfileState?) {
        let restoredRecords = restoredState?.records ?? []
        var merged: [String: PersistedLanguageProfileRecord] = [:]

        for record in restoredRecords {
            let identifier = record.profile.identifier
            guard record.profile.origin == .default,
                  var currentDefault = defaultProfilesByIdentifier[identifier] else {
                continue
            }

            let selectedExecutable = record.profile.languageServer?
                .selectedExecutable
            if var configuration = currentDefault.languageServer {
                configuration.selectedExecutable = selectedExecutable
                currentDefault.languageServer = configuration
            }
            merged[identifier] = PersistedLanguageProfileRecord(
                profile: currentDefault,
                isCustomized: selectedExecutable != nil
            )
        }

        for (identifier, defaultProfile) in defaultProfilesByIdentifier
            where merged[identifier] == nil {
            merged[identifier] = PersistedLanguageProfileRecord(
                profile: defaultProfile,
                isCustomized: false
            )
        }

        recordsByIdentifier = merged
        let highestUsedOrder = merged.values
            .map(\.profile.lastModifiedOrder)
            .max() ?? 0
        let restoredNextOrder = restoredState?.nextModifiedOrder ?? 1
        nextModifiedOrder = max(
            restoredNextOrder,
            highestUsedOrder == UInt64.max ? UInt64.max : highestUsedOrder + 1
        )
        didMigrateGlobalOverrides =
            restoredState?.didMigrateGlobalOverrides ?? false
    }

    private func migrateGlobalOverridesIfNeeded() throws -> [String] {
        guard !didMigrateGlobalOverrides else {
            return []
        }
        var migratedIdentifiers: [String] = []
        for identifier in defaultProfilesByIdentifier.keys.sorted() {
            guard case .value(let override, _) =
                    try overrideStore.globalOverride(
                        languageKey: identifier
                    ),
                  var record = recordsByIdentifier[identifier],
                  var configuration = record.profile.languageServer else {
                continue
            }
            configuration.selectedExecutable = RegisteredLanguageServerExecutable(
                path: override.url.path,
                arguments: override.arguments
            )
            record.profile.languageServer = configuration
            record.profile = try record.profile.validated()
            record.isCustomized = true
            recordsByIdentifier[identifier] = record
            migratedIdentifiers.append(identifier)
        }
        return migratedIdentifiers
    }

    private func commit(
        replacing identifier: String,
        with record: PersistedLanguageProfileRecord
    ) throws {
        var proposedRecords = recordsByIdentifier
        proposedRecords[identifier] = record
        try persist(records: proposedRecords)
        recordsByIdentifier = proposedRecords
        postChange()
    }

    private func persist(
        records: [String: PersistedLanguageProfileRecord]? = nil
    ) throws {
        let records = records ?? recordsByIdentifier
        let state = PersistedLanguageProfileState(
            nextModifiedOrder: nextModifiedOrder,
            didMigrateGlobalOverrides: didMigrateGlobalOverrides,
            records: records.values.sorted {
                $0.profile.identifier < $1.profile.identifier
            }
        )
        try repository.write(state, to: persistedStateSetting)
    }

    private func postChange() {
        changeObservers = changeObservers.filter { _, observer in
            observer.state.isActive
        }
        for observer in changeObservers.values where observer.state.isActive {
            observer.callback()
        }
    }

    private var persistedStateSetting: CodableSetting<PersistedLanguageProfileState> {
        CodableSetting(
            key: persistenceKey,
            currentVersion: 1,
            migrations: [
                .unversionedCodable(PersistedLanguageProfileState.self) {
                    $0
                }
            ]
        )
    }
}

private struct ChangeObserver {
    let state: ChangeObserverState
    let callback: @MainActor @Sendable () -> Void
}

private final class ChangeObserverState: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    var isActive: Bool {
        lock.lock()
        let value = active
        lock.unlock()
        return value
    }

    func cancel() {
        lock.lock()
        active = false
        lock.unlock()
    }
}
