import Foundation
import SettingsCore
import XCTest
@testable import LanguageAdapters

final class LanguageProfileStoreTests: XCTestCase {
    func testDefaultProfilesValidateAndRoundTrip() throws {
        for profile in DefaultLanguageProfiles.all {
            let validated = try profile.validated()
            let data = try JSONEncoder().encode(validated)
            let decoded = try JSONDecoder().decode(
                LanguageProfile.self,
                from: data
            )
            XCTAssertEqual(decoded, validated, profile.identifier)
        }
    }

    @MainActor
    func testNewAndUpdatedUnmodifiedDefaultsMergeOnUpgrade() throws {
        let defaults = makeDefaults()
        var swiftV1 = DefaultLanguageProfiles.swift
        swiftV1.displayName = "Swift v1"
        swiftV1.defaultRevision = 1
        _ = try LanguageProfileStore(
            defaultProfiles: [swiftV1],
            repository: defaults
        )

        var swiftV2 = swiftV1
        swiftV2.displayName = "Swift v2"
        swiftV2.defaultRevision = 2
        let upgraded = try LanguageProfileStore(
            defaultProfiles: [swiftV2, DefaultLanguageProfiles.markdown],
            repository: defaults
        )

        XCTAssertEqual(
            upgraded.profile(identifier: "swift")?.displayName,
            "Swift v2"
        )
        XCTAssertEqual(
            upgraded.profile(identifier: "swift")?.defaultRevision,
            2
        )
        XCTAssertNotNil(upgraded.profile(identifier: "markdown"))
        XCTAssertEqual(upgraded.isCustomized(identifier: "swift"), false)
    }

    @MainActor
    func testCommandOverrideSurvivesUpgradeUntilReset() throws {
        let defaults = makeDefaults()
        var swiftV1 = DefaultLanguageProfiles.swift
        swiftV1.defaultRevision = 1
        let store = try LanguageProfileStore(
            defaultProfiles: [swiftV1],
            repository: defaults
        )
        var customized = try XCTUnwrap(store.profile(identifier: "swift"))
        customized.languageServer?.selectedExecutable =
            RegisteredLanguageServerExecutable(
                path: "/usr/bin/true",
                arguments: ["--stdio"]
            )
        _ = try store.updateProfile(customized)

        var swiftV2 = swiftV1
        swiftV2.displayName = "Shipped Swift v2"
        swiftV2.defaultRevision = 2
        let upgraded = try LanguageProfileStore(
            defaultProfiles: [swiftV2],
            repository: defaults
        )

        XCTAssertEqual(
            upgraded.profile(identifier: "swift")?.displayName,
            "Shipped Swift v2"
        )
        XCTAssertEqual(
            upgraded.profile(identifier: "swift")?.defaultRevision,
            2
        )
        XCTAssertEqual(
            upgraded.profile(identifier: "swift")?
                .languageServer?.selectedExecutable,
            customized.languageServer?.selectedExecutable
        )
        XCTAssertEqual(upgraded.isCustomized(identifier: "swift"), true)

        var cleared = try XCTUnwrap(
            upgraded.profile(identifier: "swift")
        )
        cleared.languageServer?.selectedExecutable = nil
        let reset = try upgraded.updateProfile(cleared)
        XCTAssertEqual(reset.displayName, "Shipped Swift v2")
        XCTAssertNil(reset.languageServer?.selectedExecutable)
        XCTAssertEqual(upgraded.isCustomized(identifier: "swift"), false)

        var swiftV3 = swiftV2
        swiftV3.displayName = "Shipped Swift v3"
        swiftV3.defaultRevision = 3
        let reloaded = try LanguageProfileStore(
            defaultProfiles: [swiftV3],
            repository: defaults
        )
        XCTAssertEqual(
            reloaded.profile(identifier: "swift")?.displayName,
            "Shipped Swift v3"
        )
        XCTAssertEqual(
            reloaded.profile(identifier: "swift")?
                .languageServer?.selectedExecutable,
            nil
        )
    }

    @MainActor
    func testRetiredCustomizedDefaultIsDiscarded() throws {
        let defaults = makeDefaults()
        let store = try LanguageProfileStore(
            defaultProfiles: [DefaultLanguageProfiles.markdown],
            repository: defaults
        )
        var markdown = try XCTUnwrap(store.profile(identifier: "markdown"))
        markdown.displayName = "My Notes"
        _ = try store.updateProfile(markdown)

        let upgraded = try LanguageProfileStore(
            defaultProfiles: [DefaultLanguageProfiles.swift],
            repository: defaults
        )
        XCTAssertNil(upgraded.profile(identifier: "markdown"))
    }

    @MainActor
    func testGlobalExecutableOverrideMigratesOnce() throws {
        let defaults = makeDefaults()
        let overrideStore = LanguageServerOverrideStore(
            repository: defaults
        )
        try overrideStore.setGlobalOverride(
            url: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["custom", "--stdio"],
            languageKey: "swift"
        )

        let store = try LanguageProfileStore(
            defaultProfiles: [DefaultLanguageProfiles.swift],
            repository: defaults,
            overrideStore: overrideStore
        )

        let selected = try XCTUnwrap(
            store.profile(identifier: "swift")?
                .languageServer?
                .selectedExecutable
        )
        XCTAssertEqual(selected.path, "/usr/bin/env")
        XCTAssertEqual(selected.arguments, ["custom", "--stdio"])
        XCTAssertEqual(
            try overrideStore.globalOverride(languageKey: "swift"),
            .absent
        )
        XCTAssertEqual(store.isCustomized(identifier: "swift"), true)

        try overrideStore.setGlobalOverride(
            url: URL(fileURLWithPath: "/bin/echo"),
            arguments: [],
            languageKey: "swift"
        )
        let reloaded = try LanguageProfileStore(
            defaultProfiles: [DefaultLanguageProfiles.swift],
            repository: defaults,
            overrideStore: overrideStore
        )
        XCTAssertEqual(
            reloaded.profile(identifier: "swift")?
                .languageServer?
                .selectedExecutable?
                .path,
            "/usr/bin/env"
        )
        guard case .value = try overrideStore.globalOverride(
            languageKey: "swift"
        ) else {
            return XCTFail("The post-migration override must remain")
        }
    }

    @MainActor
    func testCorruptStateIsQuarantinedAndDefaultsAreRebuilt() throws {
        let defaults = makeDefaults()
        try defaults.keyValueStore.setValue(
            .data(Data("not valid profile json".utf8)),
            forKey: "kod.language-profiles"
        )

        let store = try LanguageProfileStore(
            defaultProfiles: [DefaultLanguageProfiles.swift],
            repository: defaults
        )

        guard case .rebuiltAfterQuarantine = store.loadStatus else {
            return XCTFail("Expected quarantined load status")
        }
        XCTAssertNotNil(store.profile(identifier: "swift"))
        XCTAssertEqual(try store.quarantine.records().count, 1)
        XCTAssertEqual(
            try store.quarantine.records()[0].key,
            "kod.language-profiles"
        )

        let reloaded = try LanguageProfileStore(
            defaultProfiles: [DefaultLanguageProfiles.swift],
            repository: defaults
        )
        XCTAssertEqual(reloaded.loadStatus, .restored)
    }

    @MainActor
    func testSchemaV1MigrationDropsUnsupportedProfilesAndKeepsCurrentOverrides() throws {
        let defaults = makeDefaults()
        var customizedSwift = DefaultLanguageProfiles.swift
        customizedSwift.displayName = "My Swift"
        customizedSwift.lastModifiedOrder = 9
        customizedSwift.associations[0].fileExtensions.append("custom-swift")
        customizedSwift.languageServer?.selectedExecutable =
            RegisteredLanguageServerExecutable(
                path: "/usr/bin/true",
                arguments: ["--stdio"]
            )
        var retiredMarkdown = DefaultLanguageProfiles.markdown
        retiredMarkdown.displayName = "My Notes"
        retiredMarkdown.lastModifiedOrder = 8
        let legacyState = LegacyLanguageProfileState(
            schemaVersion: 1,
            nextModifiedOrder: 10,
            didMigrateGlobalOverrides: true,
            records: [
                .init(profile: customizedSwift, isCustomized: true),
                .init(profile: retiredMarkdown, isCustomized: true),
                .init(
                    profile: makeCustomProfile(
                        identifier: "justfile",
                        extensionValue: "just"
                    ),
                    isCustomized: true
                )
            ]
        )
        try defaults.keyValueStore.setValue(
            .data(try JSONEncoder().encode(legacyState)),
            forKey: "kod.language-profiles"
        )

        let migrated = try LanguageProfileStore(
            defaultProfiles: [DefaultLanguageProfiles.swift],
            repository: defaults
        )

        XCTAssertEqual(migrated.profiles.map(\.identifier), ["swift"])
        XCTAssertEqual(migrated.profile(identifier: "swift")?.displayName, "Swift")
        XCTAssertEqual(
            migrated.profile(identifier: "swift")?.associations,
            DefaultLanguageProfiles.swift.associations
        )
        XCTAssertEqual(
            migrated.profile(identifier: "swift")?
                .languageServer?.selectedExecutable,
            customizedSwift.languageServer?.selectedExecutable
        )
        XCTAssertEqual(migrated.isCustomized(identifier: "swift"), true)
        XCTAssertNil(migrated.profile(identifier: "markdown"))
        XCTAssertNil(migrated.profile(identifier: "justfile"))

        guard case .data(let persistedData) = try defaults.keyValueStore.value(
            forKey: "kod.language-profiles"
        ) else {
            return XCTFail("Expected persisted language-profile data")
        }
        let persistedJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: persistedData) as? [String: Any]
        )
        let persistedPayload = try XCTUnwrap(
            persistedJSON["payload"] as? [String: Any]
        )
        XCTAssertEqual(persistedPayload["schemaVersion"] as? Int, 3)
    }

    @MainActor
    func testSchemaV1MigrationRehydratesRemovedServerAsEnabledDefault() throws {
        let defaults = makeDefaults()
        var customizedSwift = DefaultLanguageProfiles.swift
        customizedSwift.languageServer = nil
        customizedSwift.lastModifiedOrder = 4
        let legacyState = LegacyLanguageProfileState(
            schemaVersion: 1,
            nextModifiedOrder: 5,
            didMigrateGlobalOverrides: true,
            records: [
                .init(profile: customizedSwift, isCustomized: true)
            ]
        )
        try defaults.keyValueStore.setValue(
            .data(try JSONEncoder().encode(legacyState)),
            forKey: "kod.language-profiles"
        )

        let migrated = try LanguageProfileStore(
            defaultProfiles: [DefaultLanguageProfiles.swift],
            repository: defaults
        )

        let server = try XCTUnwrap(
            migrated.profile(identifier: "swift")?.languageServer
        )
        XCTAssertEqual(
            server.executableCandidates,
            DefaultLanguageProfiles.swift.languageServer?.executableCandidates
        )
        XCTAssertNil(server.selectedExecutable)
        XCTAssertEqual(
            migrated.profile(identifier: "swift")?.lastModifiedOrder,
            DefaultLanguageProfiles.swift.lastModifiedOrder
        )
        XCTAssertEqual(migrated.isCustomized(identifier: "swift"), false)
    }

    @MainActor
    func testSchemaV2MigrationDropsDisabledAndFileOverridesButKeepsCommand() throws {
        let defaults = makeDefaults()
        var customizedSwift = DefaultLanguageProfiles.swift
        customizedSwift.associations[0].fileExtensions.append("hidden-swift")
        customizedSwift.languageServer?.selectedExecutable =
            RegisteredLanguageServerExecutable(
                path: "/usr/bin/true",
                arguments: ["--stdio"]
            )
        let legacyState = LegacyLanguageProfileState(
            schemaVersion: 2,
            nextModifiedOrder: 4,
            didMigrateGlobalOverrides: true,
            records: [
                .init(profile: customizedSwift, isCustomized: true)
            ]
        )
        let encoded = try JSONEncoder().encode(legacyState)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var records = try XCTUnwrap(object["records"] as? [[String: Any]])
        var profile = try XCTUnwrap(records[0]["profile"] as? [String: Any])
        var server = try XCTUnwrap(
            profile["languageServer"] as? [String: Any]
        )
        server["disabled"] = true
        profile["languageServer"] = server
        records[0]["profile"] = profile
        object["records"] = records
        try defaults.keyValueStore.setValue(
            .data(try JSONSerialization.data(withJSONObject: object)),
            forKey: "kod.language-profiles"
        )

        let migrated = try LanguageProfileStore(
            defaultProfiles: [DefaultLanguageProfiles.swift],
            repository: defaults
        )

        let profileAfterMigration = try XCTUnwrap(
            migrated.profile(identifier: "swift")
        )
        XCTAssertEqual(
            profileAfterMigration.associations,
            DefaultLanguageProfiles.swift.associations
        )
        XCTAssertEqual(
            profileAfterMigration.languageServer?.selectedExecutable,
            customizedSwift.languageServer?.selectedExecutable
        )
        XCTAssertEqual(migrated.isCustomized(identifier: "swift"), true)

        guard case .data(let persistedData) = try defaults.keyValueStore.value(
            forKey: "kod.language-profiles"
        ) else {
            return XCTFail("Expected persisted language-profile data")
        }
        let persistedText = try XCTUnwrap(
            String(data: persistedData, encoding: .utf8)
        )
        XCTAssertFalse(persistedText.contains("\"disabled\""))
    }

    @MainActor
    func testCommandUpdatePreservesFileMatchPriority() throws {
        let defaults = makeDefaults()
        let store = try LanguageProfileStore(
            defaultProfiles: [DefaultLanguageProfiles.swift],
            repository: defaults
        )
        var profile = try XCTUnwrap(store.profile(identifier: "swift"))
        let originalOrder = profile.lastModifiedOrder
        profile.languageServer?.selectedExecutable =
            RegisteredLanguageServerExecutable(
                path: "/usr/bin/true",
                arguments: ["--stdio"]
            )

        let commandUpdate = try store.updateProfile(profile)
        XCTAssertEqual(commandUpdate.lastModifiedOrder, originalOrder)
    }

    @MainActor
    func testChangeObservationIsOwnedByCancellationToken() throws {
        let repository = makeDefaults()
        let store = try LanguageProfileStore(
            defaultProfiles: [DefaultLanguageProfiles.swift],
            repository: repository
        )
        let counter = LanguageProfileObserverCounter()
        let observation = store.observeChanges {
            counter.increment()
        }

        var profile = try XCTUnwrap(store.profile(identifier: "swift"))
        profile.languageServer?.selectedExecutable =
            RegisteredLanguageServerExecutable(
                path: "/usr/bin/true",
                arguments: []
            )
        _ = try store.updateProfile(profile)
        XCTAssertEqual(counter.value, 1)

        observation.cancel()
        profile.languageServer?.selectedExecutable = nil
        _ = try store.updateProfile(profile)
        XCTAssertEqual(counter.value, 1)
    }

    private struct LegacyLanguageProfileRecord: Codable {
        let profile: LanguageProfile
        let isCustomized: Bool
    }

    private struct LegacyLanguageProfileState: Codable {
        let schemaVersion: Int
        let nextModifiedOrder: UInt64
        let didMigrateGlobalOverrides: Bool
        let records: [LegacyLanguageProfileRecord]
    }

    func testValidationRejectsUnsafeCustomConfiguration() {
        var profile = makeCustomProfile(
            identifier: "unsafe",
            extensionValue: "unsafe"
        )
        profile.languageServer = LanguageServerConfiguration(
            defaultLanguageID: "unsafe",
            executableCandidates: [
                LanguageServerExecutableCandidate(
                    identifier: "unsafe-lsp",
                    executableNames: ["unsafe-lsp"],
                    arguments: []
                )
            ],
            initializationOptions: .object(["arbitrary": .bool(true)])
        )

        XCTAssertThrowsError(try profile.validated()) { error in
            XCTAssertEqual(
                error as? LanguageProfileValidationError,
                .unsafeCustomConfiguration
            )
        }

    }

    func testValidationRejectsInternalGrammarAndAmbiguousAssociations() {
        var internalGrammar = makeCustomProfile(
            identifier: "inline",
            extensionValue: "inline"
        )
        internalGrammar.associations[0].syntax = .treeSitter(.markdownInline)
        XCTAssertThrowsError(try internalGrammar.validated()) { error in
            XCTAssertEqual(
                error as? LanguageProfileValidationError,
                .unsupportedProfileSyntax(.markdownInline)
            )
        }

        var ambiguous = makeCustomProfile(
            identifier: "ambiguous",
            extensionValue: "one"
        )
        ambiguous.associations.append(
            LanguageFileAssociation(
                identifier: "second",
                fileExtensions: ["ONE"],
                syntax: .plainText
            )
        )
        XCTAssertThrowsError(try ambiguous.validated()) { error in
            XCTAssertEqual(
                error as? LanguageProfileValidationError,
                .duplicateFileExtension("one")
            )
        }
    }

    @MainActor
    private final class LanguageProfileObserverCounter {
        private(set) var value = 0

        func increment() {
            value += 1
        }
    }

    private func makeDefaults() -> CodableSettingsRepository {
        CodableSettingsRepository(
            store: InMemorySettingsKeyValueStore()
        )
    }

    private func makeCustomProfile(
        identifier: String,
        extensionValue: String
    ) -> LanguageProfile {
        LanguageProfile(
            identifier: identifier,
            displayName: "Custom \(identifier)",
            origin: .custom,
            defaultRevision: 1,
            associations: [
                LanguageFileAssociation(
                    identifier: "main",
                    fileExtensions: [extensionValue],
                    syntax: .plainText
                )
            ]
        )
    }
}
