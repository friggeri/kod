import Foundation
import SettingsCore
import SourceModel
import WorkspaceCore
import XCTest
@testable import LanguageAdapters

final class LanguageProfileRegistryTests: XCTestCase {
    func testCustomExtensionAndExactFilenameRouting() throws {
        let extensionProfile = try profile(
            identifier: "extension",
            order: 100,
            association: LanguageFileAssociation(
                identifier: "extension",
                fileExtensions: ["foo"],
                syntax: .treeSitter(.json)
            )
        ).validated()
        let exactProfile = try profile(
            identifier: "exact",
            order: 1,
            association: LanguageFileAssociation(
                identifier: "exact",
                exactFileNames: ["special.foo"],
                syntax: .treeSitter(.toml)
            )
        ).validated()
        let snapshot = LanguageProfileRegistrySnapshot(
            profiles: [extensionProfile, exactProfile]
        )

        let resolved = try XCTUnwrap(
            snapshot.resolve(
                url: URL(fileURLWithPath: "/tmp/special.foo")
            )
        )
        XCTAssertEqual(resolved.profile.identifier, "exact")
        XCTAssertEqual(resolved.syntax, .treeSitter(.toml))
        XCTAssertNil(
            snapshot.resolve(
                url: URL(fileURLWithPath: "/tmp/unknown.extension")
            )
        )
    }

    func testMostRecentlyEditedEnabledProfileWinsConflict() throws {
        let older = try profile(
            identifier: "older",
            order: 10,
            association: LanguageFileAssociation(
                identifier: "main",
                fileExtensions: ["shared"],
                syntax: .treeSitter(.json)
            )
        ).validated()
        let newer = try profile(
            identifier: "newer",
            order: 20,
            association: LanguageFileAssociation(
                identifier: "main",
                fileExtensions: ["shared"],
                syntax: .treeSitter(.yaml)
            )
        ).validated()
        var disabled = newer
        disabled.identifier = "disabled"
        disabled.isEnabled = false
        disabled.lastModifiedOrder = 30
        let snapshot = LanguageProfileRegistrySnapshot(
            profiles: [older, newer, disabled]
        )

        let resolved = try XCTUnwrap(
            snapshot.resolve(
                url: URL(fileURLWithPath: "/tmp/file.shared")
            )
        )
        XCTAssertEqual(resolved.profile.identifier, "newer")
        XCTAssertEqual(
            snapshot.conflicts,
            [
                LanguageProfileConflict(
                    matchKey: .fileExtension("shared"),
                    profileIdentifiers: ["newer", "older"],
                    winningProfileIdentifier: "newer"
                )
            ]
        )
    }

    func testStableIdentifierBreaksModificationOrderTie() throws {
        let alpha = try profile(
            identifier: "alpha",
            order: 5,
            association: LanguageFileAssociation(
                identifier: "main",
                fileExtensions: ["tie"],
                syntax: .treeSitter(.json)
            )
        ).validated()
        let beta = try profile(
            identifier: "beta",
            order: 5,
            association: LanguageFileAssociation(
                identifier: "main",
                fileExtensions: ["tie"],
                syntax: .treeSitter(.yaml)
            )
        ).validated()

        let resolved = try XCTUnwrap(
            LanguageProfileRegistrySnapshot(profiles: [beta, alpha])
                .resolve(url: URL(fileURLWithPath: "/tmp/file.tie"))
        )
        XCTAssertEqual(resolved.profile.identifier, "alpha")
    }

    func testShellContentMatcherIsBoundedAndOnlyUsedWithoutPathMatch() throws {
        let shell = try DefaultLanguageProfiles.shell.validated()
        let snapshot = LanguageProfileRegistrySnapshot(profiles: [shell])
        let extensionless = SourceSnapshot(
            text: "#!/usr/bin/env bash\nprintf 'ok\\n'\n",
            url: URL(fileURLWithPath: "/tmp/build")
        )
        let lateShebang = SourceSnapshot(
            text: String(repeating: " ", count: 600) + "#!/bin/bash\n",
            url: URL(fileURLWithPath: "/tmp/late")
        )

        XCTAssertEqual(
            snapshot.resolve(snapshot: extensionless)?.profile.identifier,
            "shellscript"
        )
        XCTAssertNil(snapshot.resolve(snapshot: lateShebang))
    }

    @MainActor
    func testRegistryReloadsSynchronouslyAfterStoreChange() throws {
        let defaults = makeDefaults()
        let store = try LanguageProfileStore(
            defaultProfiles: [],
            repository: defaults
        )
        let registry = LanguageProfileRegistry(store: store)
        var observedIdentifier: String?
        let observation = registry.observeChanges {
            observedIdentifier = registry.resolve(
                url: URL(fileURLWithPath: "/tmp/example.live")
            )?.profile.identifier
        }
        XCTAssertNil(
            registry.resolve(
                url: URL(fileURLWithPath: "/tmp/example.live")
            )
        )

        _ = try store.createCustomProfile(
            profile(
                identifier: "live",
                order: 0,
                association: LanguageFileAssociation(
                    identifier: "main",
                    fileExtensions: ["live"],
                    syntax: .plainText
                )
            )
        )

        XCTAssertEqual(
            registry.resolve(
                url: URL(fileURLWithPath: "/tmp/example.live")
            )?.profile.identifier,
            "live"
        )
        XCTAssertEqual(observedIdentifier, "live")
        withExtendedLifetime(observation) {}
    }

    func testRegisteredExecutablePrecedesAutoDetection() throws {
        var profile = try DefaultLanguageProfiles.markdown.validated()
        profile.languageServer?.selectedExecutable =
            RegisteredLanguageServerExecutable(
                path: "/bin/echo",
                arguments: ["registered"]
            )
        let result = try LanguageServerDiscoveryEngine.resolve(
            profile: profile,
            overrideStore: makeOverrideStore(),
            identity: nil,
            loginShellPath: { "/usr/bin" },
            packageManagerDirectories: [],
            xcrunProbe: { _ in nil },
            rustupProbe: { _ in nil }
        )

        XCTAssertEqual(result.source, .registeredProfile)
        XCTAssertEqual(result.url.path, "/bin/echo")
        XCTAssertEqual(result.arguments, ["registered"])
    }

    func testWorkspaceOverridePrecedesRegisteredExecutable() throws {
        let root = try makeTemporaryDirectory()
        let identity = try WorkspaceIdentity(root: root)
        let overrideStore = makeOverrideStore()
        try overrideStore.setWorkspaceOverride(
            url: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["workspace"],
            languageKey: "markdown",
            identity: identity
        )
        var profile = try DefaultLanguageProfiles.markdown.validated()
        profile.languageServer?.selectedExecutable =
            RegisteredLanguageServerExecutable(
                path: "/bin/echo",
                arguments: ["registered"]
            )

        let result = try LanguageServerDiscoveryEngine.resolve(
            profile: profile,
            overrideStore: overrideStore,
            identity: identity,
            loginShellPath: { nil },
            packageManagerDirectories: [],
            xcrunProbe: { _ in nil },
            rustupProbe: { _ in nil }
        )

        XCTAssertEqual(result.source, .workspaceOverride)
        XCTAssertEqual(result.url.path, "/usr/bin/env")
        XCTAssertEqual(result.arguments, ["workspace"])
    }

    func testCandidateVersionGateFallsThroughWithCandidateArguments() throws {
        let directory = try makeTemporaryDirectory()
        _ = try makeExecutable(
            named: "new-server",
            version: "Version 6.4.0",
            in: directory
        )
        let legacy = try makeExecutable(
            named: "legacy-server",
            version: "5.0.0",
            in: directory
        )
        var profile = profile(
            identifier: "versioned",
            order: 0,
            association: LanguageFileAssociation(
                identifier: "main",
                fileExtensions: ["versioned"],
                syntax: .plainText
            )
        )
        profile.languageServer = LanguageServerConfiguration(
            defaultLanguageID: "versioned",
            executableCandidates: [
                LanguageServerExecutableCandidate(
                    identifier: "native",
                    executableNames: ["new-server"],
                    arguments: ["--native"],
                    minimumMajorVersion: 7
                ),
                LanguageServerExecutableCandidate(
                    identifier: "legacy",
                    executableNames: ["legacy-server"],
                    arguments: ["--legacy"]
                )
            ]
        )

        let result = try LanguageServerDiscoveryEngine.resolve(
            profile: profile,
            overrideStore: makeOverrideStore(),
            identity: nil,
            loginShellPath: { directory.path },
            packageManagerDirectories: [],
            xcrunProbe: { _ in nil },
            rustupProbe: { _ in nil }
        )

        XCTAssertEqual(result.url, legacy)
        XCTAssertEqual(result.arguments, ["--legacy"])
    }

    private func profile(
        identifier: String,
        order: UInt64,
        association: LanguageFileAssociation
    ) -> LanguageProfile {
        LanguageProfile(
            identifier: identifier,
            displayName: identifier.capitalized,
            origin: .custom,
            defaultRevision: 1,
            lastModifiedOrder: order,
            associations: [association]
        )
    }

    private func makeDefaults() -> CodableSettingsRepository {
        CodableSettingsRepository(
            store: InMemorySettingsKeyValueStore()
        )
    }

    private func makeOverrideStore() -> LanguageServerOverrideStore {
        LanguageServerOverrideStore(repository: makeDefaults())
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LanguageProfileRegistryTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func makeExecutable(
        named name: String,
        version: String,
        in directory: URL
    ) throws -> URL {
        let executable = directory.appendingPathComponent(name)
        try """
        #!/bin/sh
        echo "\(version)"
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return executable
    }
}
