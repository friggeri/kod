import Foundation
import LanguageClient
import WorkspaceCore
import XCTest
@testable import LanguageAdapters

/// Guards the consolidation invariant: `LanguageProfile` /
/// `DefaultLanguageProfiles` are the only place Kod defines language
/// configuration. There is no second static adapter catalog, the
/// specialized discovery helpers read profile data, and what the runtime
/// factory configures is exactly what the store persists.
final class DefaultLanguageProfileCatalogTests: XCTestCase {
    private static let languageAdaptersSourceDirectory: URL = {
        // Tests/LanguageAdaptersTests/<file> -> Tests -> KodCore
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LanguageAdapters")
    }()

    private func sourceFiles() throws -> [URL] {
        let directory = Self.languageAdaptersSourceDirectory
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        )
        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
    }

    // MARK: - One canonical definition per default language

    func testEveryDefaultProfileIsDefinedExactlyOnce() throws {
        let profiles = DefaultLanguageProfiles.all
        var identifiers = Set<String>()
        for profile in profiles {
            let validated = try profile.validated()
            XCTAssertEqual(
                validated.origin,
                .default,
                "\(profile.identifier) must ship as a default profile"
            )
            XCTAssertTrue(
                identifiers.insert(profile.identifier).inserted,
                "Duplicate default profile identifier: \(profile.identifier)"
            )
        }

        let snapshot = LanguageProfileRegistrySnapshot(profiles: profiles)
        XCTAssertEqual(
            snapshot.conflicts,
            [],
            "No extension, filename, or content matcher may be claimed twice"
        )
        XCTAssertEqual(
            identifiers,
            [
                "swift", "typescript", "html", "css", "python", "rust",
                "shellscript", "markdown", "json", "yaml", "toml", "c",
                "go", "java", "ruby", "lua", "graphql", "xml"
            ],
            "Every previously supported language must still be shipped"
        )
    }

    func testEveryDeclaredDefaultProfileIsListedInTheCatalog() throws {
        let source = try String(
            contentsOf: Self.languageAdaptersSourceDirectory
                .appendingPathComponent("Profiles/DefaultLanguageProfiles.swift"),
            encoding: .utf8
        )
        let declaredNames = source
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("public static let "),
                      trimmed.hasSuffix("= LanguageProfile(") else {
                    return nil
                }
                return trimmed
                    .dropFirst("public static let ".count)
                    .split(separator: " ")
                    .first
                    .map(String.init)
            }
        XCTAssertEqual(
            declaredNames.count,
            DefaultLanguageProfiles.all.count,
            "Declared profiles: \(declaredNames)"
        )

        let listStart = try XCTUnwrap(source.range(of: "public static let all: [LanguageProfile] = ["))
        let listEnd = try XCTUnwrap(source.range(of: "]", range: listStart.upperBound..<source.endIndex))
        let listBody = source[listStart.upperBound..<listEnd.lowerBound]
        let listedNames = Set(
            listBody
                .split(whereSeparator: { $0 == "," || $0.isNewline })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
        XCTAssertEqual(listedNames, Set(declaredNames))
    }

    func testEveryDefaultProfileWithAServerHasExactlyOneInstallationGuide() {
        for profile in DefaultLanguageProfiles.all
        where profile.languageServer != nil {
            XCTAssertNotNil(
                DefaultLanguageServerInstallationGuides.guide(for: profile),
                "Missing installation guidance for \(profile.identifier)"
            )
        }
        XCTAssertEqual(
            DefaultLanguageServerInstallationGuides.all.count,
            DefaultLanguageProfiles.all.filter { $0.languageServer != nil }.count
        )
    }

    // MARK: - No legacy adapter catalog remains

    func testNoLegacyStaticAdapterSurfaceRemains() throws {
        let bannedSymbols = [
            "protocol LanguageAdapter",
            ": LanguageAdapter",
            "LanguageServerExecutableProfile",
            "executableProfiles",
            "lspLanguageId("
        ]
        for file in try sourceFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(
                file.lastPathComponent.contains("Adapter"),
                "Legacy adapter file still present: \(file.lastPathComponent)"
            )
            for symbol in bannedSymbols {
                XCTAssertFalse(
                    source.contains(symbol),
                    "\(file.lastPathComponent) still declares legacy adapter surface: \(symbol)"
                )
            }
        }
    }

    // MARK: - Specialized discovery reads profile candidates

    func testSpecializedToolProbesReceiveOnlyProfileCandidateData() throws {
        let requestedTools = LockedStrings()
        let requestedComponents = LockedStrings()
        let overrideStore = try makeOverrideStore()

        for profile in DefaultLanguageProfiles.all {
            _ = try? LanguageServerDiscoveryEngine.resolve(
                profile: profile,
                overrideStore: overrideStore,
                identity: nil,
                loginShellPath: { nil },
                packageManagerDirectories: [],
                xcrunProbe: { tool in
                    requestedTools.append(tool)
                    return nil
                },
                rustupProbe: { component in
                    requestedComponents.append(component)
                    return nil
                }
            )
        }

        XCTAssertEqual(requestedTools.snapshot(), ["sourcekit-lsp"])
        XCTAssertEqual(requestedComponents.snapshot(), ["rust-analyzer"])

        let swiftServer = try XCTUnwrap(
            DefaultLanguageProfiles.swift.languageServer
        )
        let swiftCandidateTools = swiftServer.executableCandidates
            .flatMap(\.discoveryStrategies)
            .compactMap { strategy -> String? in
                if case .xcrun(let tool) = strategy {
                    return tool
                }
                return nil
            }
        XCTAssertEqual(
            requestedTools.snapshot(),
            swiftCandidateTools,
            "The probe must receive exactly the profile's own candidate data"
        )
    }

    func testShellCheckHelperReadsTheShippedProfileConfiguration() throws {
        let profile = DefaultLanguageProfiles.shell
        let configuration = try XCTUnwrap(profile.languageServer)
        XCTAssertEqual(configuration.supportNotes, [.shellCheckOptional])

        let shellCheck = URL(fileURLWithPath: "/usr/local/bin/shellcheck")
        let resolved = ShellCheckSupport.resolvedWorkspaceConfiguration(
            configuration.workspaceConfiguration,
            shellCheckURL: shellCheck
        )
        guard case .object(let section)? = resolved["bashIde"] else {
            return XCTFail("Expected the profile's own bashIde section")
        }
        XCTAssertEqual(section["shellcheckPath"], .string(shellCheck.path))
        XCTAssertEqual(section["shfmt"], .object(["path": .string("")]))
    }

    // MARK: - Runtime configuration equals persisted profile data

    @MainActor
    func testFactoryConfigurationMatchesPersistedProfileData() throws {
        let repository = makeLanguageAdaptersTestRepository()
        let store = try LanguageProfileStore(repository: repository)
        // A second store over the same repository reads the persisted
        // state back rather than the in-memory catalog.
        let reloaded = try LanguageProfileStore(repository: repository)

        for shipped in DefaultLanguageProfiles.all {
            let persisted = try XCTUnwrap(
                reloaded.profile(identifier: shipped.identifier)
            )
            XCTAssertEqual(
                persisted,
                try XCTUnwrap(store.profile(identifier: shipped.identifier))
            )
            let expected = try shipped.validated()
            XCTAssertEqual(persisted.associations, expected.associations)
            XCTAssertEqual(persisted.languageServer, expected.languageServer)

            guard let languageServer = persisted.languageServer else {
                continue
            }
            let configuration = LanguageProfileServiceFactory.makeConfiguration(
                languageServer: languageServer,
                profile: persisted,
                shellCheckURL: { nil }
            )
            XCTAssertEqual(
                configuration.languageId,
                languageServer.defaultLanguageID
            )
            XCTAssertEqual(
                configuration.semanticTokenTypes,
                languageServer.semanticTokenTypes
            )
            XCTAssertEqual(
                configuration.semanticTokenModifiers,
                languageServer.semanticTokenModifiers
            )
            XCTAssertEqual(
                configuration.initializationOptions,
                languageServer.initializationOptions
            )
            XCTAssertEqual(
                configuration.workspaceConfiguration,
                languageServer.workspaceConfiguration,
                "\(persisted.identifier) must launch with its persisted configuration"
            )

            for association in persisted.associations {
                let expectedLanguageID = languageServer.languageID(
                    for: association.identifier
                )
                for fileExtension in association.fileExtensions {
                    let url = URL(fileURLWithPath: "/tmp/sample.\(fileExtension)")
                    XCTAssertEqual(
                        configuration.languageIdForURL(url),
                        expectedLanguageID,
                        "\(persisted.identifier).\(fileExtension)"
                    )
                }
                for fileName in association.exactFileNames {
                    let url = URL(fileURLWithPath: "/tmp/\(fileName)")
                    XCTAssertEqual(
                        configuration.languageIdForURL(url),
                        expectedLanguageID,
                        "\(persisted.identifier)/\(fileName)"
                    )
                }
            }
        }
    }

    // MARK: - Custom profiles cannot gain shipped-only capabilities

    func testCustomProfilesCannotUseToolchainDiscoveryStrategies() {
        for strategy in [
            LanguageServerDiscoveryStrategy.xcrun(tool: "sourcekit-lsp"),
            LanguageServerDiscoveryStrategy.rustup(component: "rust-analyzer")
        ] {
            let profile = LanguageProfile(
                identifier: "sneaky",
                displayName: "Sneaky",
                origin: .custom,
                defaultRevision: 1,
                associations: [
                    LanguageFileAssociation(
                        identifier: "sneaky",
                        fileExtensions: ["sneaky"],
                        syntax: .plainText
                    )
                ],
                languageServer: LanguageServerConfiguration(
                    defaultLanguageID: "sneaky",
                    executableCandidates: [
                        LanguageServerExecutableCandidate(
                            identifier: "sneaky-lsp",
                            executableNames: ["sneaky-lsp"],
                            arguments: [],
                            discoveryStrategies: [strategy]
                        )
                    ]
                )
            )
            XCTAssertThrowsError(try profile.validated()) { error in
                XCTAssertEqual(
                    error as? LanguageProfileValidationError,
                    .unsafeCustomDiscoveryStrategy
                )
            }
        }
    }

    func testRetiringAShippedProfileStripsShippedOnlyCapabilities() throws {
        let retired = DefaultLanguageProfiles.swift.sanitizedAsCustomProfile()
        let validated = try retired.validated()
        XCTAssertEqual(validated.origin, .custom)
        let configuration = try XCTUnwrap(validated.languageServer)
        XCTAssertEqual(configuration.workspaceConfiguration, [:])
        XCTAssertNil(configuration.initializationOptions)
        XCTAssertEqual(configuration.networkAccess, .none)
        XCTAssertEqual(configuration.supportNotes, [])
        XCTAssertEqual(
            configuration.executableCandidates.flatMap(\.discoveryStrategies),
            [.path, .packageManagerLocations]
        )
        XCTAssertNil(DefaultLanguageServerInstallationGuides.guide(for: validated))

        let shell = try DefaultLanguageProfiles.shell
            .sanitizedAsCustomProfile()
            .validated()
        XCTAssertEqual(shell.languageServer?.supportNotes, [])
        XCTAssertEqual(shell.languageServer?.workspaceConfiguration, [:])

        let json = try DefaultLanguageProfiles.json
            .sanitizedAsCustomProfile()
            .validated()
        XCTAssertEqual(
            json.languageServer?.networkAccess,
            LanguageServerNetworkAccess.none
        )
    }

    private func makeOverrideStore() throws -> LanguageServerOverrideStore {
        makeLanguageAdaptersTestOverrideStore()
    }
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
