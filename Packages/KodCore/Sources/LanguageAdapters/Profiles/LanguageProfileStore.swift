import DiagnosticsCore
import Foundation

public extension Notification.Name {
    static let kodLanguageProfilesDidChange = Notification.Name(
        "kod.languageProfilesDidChange"
    )
}

public enum LanguageProfileStoreLoadStatus: Sendable, Equatable {
    case fresh
    case restored
    case rebuiltAfterQuarantine(reason: String)
}

public enum LanguageProfileStoreError: Error, Sendable, Equatable {
    case duplicateProfileIdentifier(String)
    case profileNotFound(String)
    case defaultProfileExpected(String)
    case customProfileExpected(String)
    case immutableIdentity
    case modificationOrderExhausted
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
        case .customProfileExpected(let identifier):
            "Language profile \(identifier) is not a custom profile."
        case .immutableIdentity:
            "A language profile's identifier, origin, and default revision cannot be changed."
        case .modificationOrderExhausted:
            "Language profile modification ordering is exhausted."
        }
    }
}

private struct PersistedLanguageProfileRecord: Codable, Sendable {
    var profile: LanguageProfile
    var isCustomized: Bool
}

private struct PersistedLanguageProfileState: Codable, Sendable {
    static let currentSchemaVersion = 1

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
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported language profile schema version \(schemaVersion)"
            )
        }
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
                guard record.profile.origin == .default || record.isCustomized else {
                    throw LanguageProfileStoreError
                        .customProfileExpected(record.profile.identifier)
                }
                return record
            }
        } catch {
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
    private let defaults: UserDefaults
    private let persistenceKey: String
    private let overrideStore: LanguageServerOverrideStore
    private var defaultProfilesByIdentifier: [String: LanguageProfile]
    private var recordsByIdentifier: [String: PersistedLanguageProfileRecord] = [:]
    private var nextModifiedOrder: UInt64 = 1
    private var didMigrateGlobalOverrides = false
    private var changeObservers: [
        UUID: @MainActor @Sendable () -> Void
    ] = [:]

    public let quarantine: CorruptStateQuarantine
    public private(set) var loadStatus: LanguageProfileStoreLoadStatus = .fresh

    public init(
        defaultProfiles: [LanguageProfile] = DefaultLanguageProfiles.all,
        defaults: UserDefaults = .standard,
        overrideStore: LanguageServerOverrideStore? = nil,
        persistenceKey: String = "kod.language-profiles"
    ) throws {
        self.defaults = defaults
        self.persistenceKey = persistenceKey
        self.overrideStore = overrideStore
            ?? LanguageServerOverrideStore(defaults: defaults)
        self.quarantine = CorruptStateQuarantine(defaults: defaults)

        let validatedDefaults = try defaultProfiles.map { profile in
            let profile = try profile.validated()
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
        switch quarantine.decode(
            PersistedLanguageProfileState.self,
            forKey: persistenceKey
        ) {
        case .restored(let state):
            restoredState = state
            loadStatus = .restored
        case .absent:
            restoredState = nil
            loadStatus = .fresh
        case .quarantined(let reason):
            restoredState = nil
            loadStatus = .rebuiltAfterQuarantine(reason: reason)
        }

        merge(restoredState: restoredState)
        let migratedIdentifiers = try migrateGlobalOverridesIfNeeded()
        try persist()
        for identifier in migratedIdentifiers {
            self.overrideStore.clearGlobalOverride(languageKey: identifier)
        }
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

    @discardableResult
    public func observeChanges(
        _ observer: @escaping @MainActor @Sendable () -> Void
    ) -> UUID {
        let identifier = UUID()
        changeObservers[identifier] = observer
        return identifier
    }

    public func removeChangeObserver(_ identifier: UUID) {
        changeObservers.removeValue(forKey: identifier)
    }

    @discardableResult
    public func createCustomProfile(
        _ proposedProfile: LanguageProfile
    ) throws -> LanguageProfile {
        var profile = try proposedProfile.validated()
        guard profile.origin == .custom else {
            throw LanguageProfileStoreError
                .customProfileExpected(profile.identifier)
        }
        guard recordsByIdentifier[profile.identifier] == nil else {
            throw LanguageProfileStoreError
                .duplicateProfileIdentifier(profile.identifier)
        }
        profile.lastModifiedOrder = try takeNextModifiedOrder()
        try commit(
            replacing: profile.identifier,
            with: PersistedLanguageProfileRecord(
                profile: profile,
                isCustomized: true
            )
        )
        return profile
    }

    @discardableResult
    public func updateProfile(
        _ proposedProfile: LanguageProfile
    ) throws -> LanguageProfile {
        var profile = try proposedProfile.validated()
        guard let existing = recordsByIdentifier[profile.identifier] else {
            throw LanguageProfileStoreError.profileNotFound(profile.identifier)
        }
        guard profile.origin == existing.profile.origin,
              profile.defaultRevision == existing.profile.defaultRevision else {
            throw LanguageProfileStoreError.immutableIdentity
        }
        profile.lastModifiedOrder = try takeNextModifiedOrder()
        try commit(
            replacing: profile.identifier,
            with: PersistedLanguageProfileRecord(
                profile: profile,
                isCustomized: true
            )
        )
        return profile
    }

    @discardableResult
    public func setEnabled(
        _ isEnabled: Bool,
        identifier: String
    ) throws -> LanguageProfile {
        guard var profile = profile(identifier: identifier) else {
            throw LanguageProfileStoreError.profileNotFound(identifier)
        }
        profile.isEnabled = isEnabled
        return try updateProfile(profile)
    }

    @discardableResult
    public func resetDefaultProfile(identifier: String) throws -> LanguageProfile {
        let identifier = identifier.lowercased()
        guard var defaultProfile = defaultProfilesByIdentifier[identifier] else {
            if recordsByIdentifier[identifier] == nil {
                throw LanguageProfileStoreError.profileNotFound(identifier)
            }
            throw LanguageProfileStoreError.defaultProfileExpected(identifier)
        }
        defaultProfile.lastModifiedOrder = try takeNextModifiedOrder()
        try commit(
            replacing: identifier,
            with: PersistedLanguageProfileRecord(
                profile: defaultProfile,
                isCustomized: false
            )
        )
        return defaultProfile
    }

    public func deleteCustomProfile(identifier: String) throws {
        let identifier = identifier.lowercased()
        guard let record = recordsByIdentifier[identifier] else {
            throw LanguageProfileStoreError.profileNotFound(identifier)
        }
        guard record.profile.origin == .custom else {
            throw LanguageProfileStoreError.customProfileExpected(identifier)
        }
        var proposedRecords = recordsByIdentifier
        proposedRecords.removeValue(forKey: identifier)
        try persist(records: proposedRecords)
        recordsByIdentifier = proposedRecords
        postChange()
    }

    private func merge(restoredState: PersistedLanguageProfileState?) {
        let restoredRecords = restoredState?.records ?? []
        var merged: [String: PersistedLanguageProfileRecord] = [:]

        for record in restoredRecords {
            let identifier = record.profile.identifier
            if let currentDefault = defaultProfilesByIdentifier[identifier] {
                if record.isCustomized {
                    merged[identifier] = record
                } else {
                    var refreshedDefault = currentDefault
                    refreshedDefault.lastModifiedOrder =
                        record.profile.lastModifiedOrder
                    merged[identifier] = PersistedLanguageProfileRecord(
                        profile: refreshedDefault,
                        isCustomized: false
                    )
                }
            } else if record.profile.origin == .custom {
                merged[identifier] = record
            } else if record.isCustomized {
                var retiredProfile = record.profile
                retiredProfile.origin = .custom
                merged[identifier] = PersistedLanguageProfileRecord(
                    profile: retiredProfile,
                    isCustomized: true
                )
            }
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
            guard let override = overrideStore.globalOverride(
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
            record.profile.lastModifiedOrder = try takeNextModifiedOrder()
            record.profile = try record.profile.validated()
            record.isCustomized = true
            recordsByIdentifier[identifier] = record
            migratedIdentifiers.append(identifier)
        }
        didMigrateGlobalOverrides = true
        return migratedIdentifiers
    }

    private func takeNextModifiedOrder() throws -> UInt64 {
        guard nextModifiedOrder < UInt64.max else {
            throw LanguageProfileStoreError.modificationOrderExhausted
        }
        defer { nextModifiedOrder += 1 }
        return nextModifiedOrder
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        defaults.set(try encoder.encode(state), forKey: persistenceKey)
    }

    private func postChange() {
        for observer in changeObservers.values {
            observer()
        }
        NotificationCenter.default.post(
            name: .kodLanguageProfilesDidChange,
            object: self
        )
    }
}
