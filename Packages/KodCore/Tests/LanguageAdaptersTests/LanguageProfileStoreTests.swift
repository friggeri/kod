import Foundation
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
    func testSyntaxOnlyCustomProfilePersistsAndDeletes() throws {
        let defaults = makeDefaults()
        let store = try LanguageProfileStore(defaults: defaults)
        let custom = makeCustomProfile(
            identifier: "justfile",
            extensionValue: ".JUST"
        )

        let created = try store.createCustomProfile(custom)

        XCTAssertEqual(created.associations[0].fileExtensions, ["just"])
        XCTAssertNil(created.languageServer)
        XCTAssertEqual(store.isCustomized(identifier: "justfile"), true)

        let reloaded = try LanguageProfileStore(defaults: defaults)
        XCTAssertEqual(reloaded.profile(identifier: "justfile"), created)

        try reloaded.deleteCustomProfile(identifier: "justfile")
        XCTAssertNil(reloaded.profile(identifier: "justfile"))
    }

    @MainActor
    func testNewAndUpdatedUnmodifiedDefaultsMergeOnUpgrade() throws {
        let defaults = makeDefaults()
        var swiftV1 = DefaultLanguageProfiles.swift
        swiftV1.displayName = "Swift v1"
        swiftV1.defaultRevision = 1
        _ = try LanguageProfileStore(
            defaultProfiles: [swiftV1],
            defaults: defaults
        )

        var swiftV2 = swiftV1
        swiftV2.displayName = "Swift v2"
        swiftV2.defaultRevision = 2
        let upgraded = try LanguageProfileStore(
            defaultProfiles: [swiftV2, DefaultLanguageProfiles.markdown],
            defaults: defaults
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
    func testCustomizedDefaultSurvivesUpgradeUntilReset() throws {
        let defaults = makeDefaults()
        var swiftV1 = DefaultLanguageProfiles.swift
        swiftV1.defaultRevision = 1
        let store = try LanguageProfileStore(
            defaultProfiles: [swiftV1],
            defaults: defaults
        )
        var customized = try XCTUnwrap(store.profile(identifier: "swift"))
        customized.displayName = "My Swift"
        let saved = try store.updateProfile(customized)

        var swiftV2 = swiftV1
        swiftV2.displayName = "Shipped Swift v2"
        swiftV2.defaultRevision = 2
        let upgraded = try LanguageProfileStore(
            defaultProfiles: [swiftV2],
            defaults: defaults
        )

        XCTAssertEqual(
            upgraded.profile(identifier: "swift")?.displayName,
            "My Swift"
        )
        XCTAssertEqual(
            upgraded.profile(identifier: "swift")?.defaultRevision,
            saved.defaultRevision
        )
        XCTAssertEqual(upgraded.isCustomized(identifier: "swift"), true)

        let reset = try upgraded.resetDefaultProfile(identifier: "swift")
        XCTAssertEqual(reset.displayName, "Shipped Swift v2")
        XCTAssertGreaterThan(reset.lastModifiedOrder, saved.lastModifiedOrder)
        XCTAssertEqual(upgraded.isCustomized(identifier: "swift"), false)

        var swiftV3 = swiftV2
        swiftV3.displayName = "Shipped Swift v3"
        swiftV3.defaultRevision = 3
        let reloaded = try LanguageProfileStore(
            defaultProfiles: [swiftV3],
            defaults: defaults
        )
        XCTAssertEqual(
            reloaded.profile(identifier: "swift")?.displayName,
            "Shipped Swift v3"
        )
        XCTAssertEqual(
            reloaded.profile(identifier: "swift")?.lastModifiedOrder,
            reset.lastModifiedOrder
        )
    }

    @MainActor
    func testRetiredCustomizedDefaultBecomesDeletableCustomProfile() throws {
        let defaults = makeDefaults()
        let store = try LanguageProfileStore(
            defaultProfiles: [DefaultLanguageProfiles.markdown],
            defaults: defaults
        )
        var markdown = try XCTUnwrap(store.profile(identifier: "markdown"))
        markdown.displayName = "My Notes"
        _ = try store.updateProfile(markdown)

        let upgraded = try LanguageProfileStore(
            defaultProfiles: [DefaultLanguageProfiles.swift],
            defaults: defaults
        )
        let retired = try XCTUnwrap(
            upgraded.profile(identifier: "markdown")
        )
        XCTAssertEqual(retired.origin, .custom)

        try upgraded.deleteCustomProfile(identifier: "markdown")
        XCTAssertNil(upgraded.profile(identifier: "markdown"))
    }

    @MainActor
    func testGlobalExecutableOverrideMigratesOnce() throws {
        let defaults = makeDefaults()
        let overrideStore = LanguageServerOverrideStore(defaults: defaults)
        overrideStore.setGlobalOverride(
            url: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["custom", "--stdio"],
            languageKey: "swift"
        )

        let store = try LanguageProfileStore(
            defaultProfiles: [DefaultLanguageProfiles.swift],
            defaults: defaults,
            overrideStore: overrideStore
        )

        let selected = try XCTUnwrap(
            store.profile(identifier: "swift")?
                .languageServer?
                .selectedExecutable
        )
        XCTAssertEqual(selected.path, "/usr/bin/env")
        XCTAssertEqual(selected.arguments, ["custom", "--stdio"])
        XCTAssertNil(overrideStore.globalOverride(languageKey: "swift"))
        XCTAssertEqual(store.isCustomized(identifier: "swift"), true)

        overrideStore.setGlobalOverride(
            url: URL(fileURLWithPath: "/bin/echo"),
            arguments: [],
            languageKey: "swift"
        )
        let reloaded = try LanguageProfileStore(
            defaultProfiles: [DefaultLanguageProfiles.swift],
            defaults: defaults,
            overrideStore: overrideStore
        )
        XCTAssertEqual(
            reloaded.profile(identifier: "swift")?
                .languageServer?
                .selectedExecutable?
                .path,
            "/usr/bin/env"
        )
        XCTAssertNotNil(overrideStore.globalOverride(languageKey: "swift"))
    }

    @MainActor
    func testCorruptStateIsQuarantinedAndDefaultsAreRebuilt() throws {
        let defaults = makeDefaults()
        defaults.set(
            Data("not valid profile json".utf8),
            forKey: "kod.language-profiles"
        )

        let store = try LanguageProfileStore(
            defaultProfiles: [DefaultLanguageProfiles.swift],
            defaults: defaults
        )

        guard case .rebuiltAfterQuarantine = store.loadStatus else {
            return XCTFail("Expected quarantined load status")
        }
        XCTAssertNotNil(store.profile(identifier: "swift"))
        XCTAssertEqual(store.quarantine.ledger().count, 1)
        XCTAssertEqual(
            store.quarantine.ledger()[0].key,
            "kod.language-profiles"
        )

        let reloaded = try LanguageProfileStore(
            defaultProfiles: [DefaultLanguageProfiles.swift],
            defaults: defaults
        )
        XCTAssertEqual(reloaded.loadStatus, .restored)
    }

    @MainActor
    func testDefaultProfilesCannotBeDeletedAndCustomProfilesCannotBeReset() throws {
        let defaults = makeDefaults()
        let store = try LanguageProfileStore(
            defaultProfiles: [DefaultLanguageProfiles.swift],
            defaults: defaults
        )
        _ = try store.createCustomProfile(
            makeCustomProfile(identifier: "custom", extensionValue: "custom")
        )

        XCTAssertThrowsError(
            try store.deleteCustomProfile(identifier: "swift")
        ) { error in
            XCTAssertEqual(
                error as? LanguageProfileStoreError,
                .customProfileExpected("swift")
            )
        }
        XCTAssertThrowsError(
            try store.resetDefaultProfile(identifier: "custom")
        ) { error in
            XCTAssertEqual(
                error as? LanguageProfileStoreError,
                .defaultProfileExpected("custom")
            )
        }
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

    private func makeDefaults() -> UserDefaults {
        let suiteName = "LanguageProfileStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
        }
        return defaults
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
