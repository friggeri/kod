import Foundation
import WorkspaceCore
import XCTest
@testable import LanguageAdapters

/// Exercises SPEC 6.5's deterministic discovery precedence in isolation
/// (workspace override > global override > language-specific tool >
/// login-shell PATH > package-manager location), independent of any
/// concrete adapter or real executable.
final class LanguageServerDiscoveryEngineTests: XCTestCase {
    private func makeIdentity() throws -> (WorkspaceIdentity, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return (try WorkspaceIdentity(root: root), root)
    }

    private func makeOverrideStore() -> LanguageServerOverrideStore {
        let suiteName = "LanguageServerDiscoveryEngineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return LanguageServerOverrideStore(defaults: defaults)
    }

    /// A real, always-executable binary to point overrides/fake PATH
    /// entries at, so `isExecutableFile` checks succeed deterministically
    /// regardless of what happens to be installed on the test machine.
    private static let alwaysPresentExecutable = URL(fileURLWithPath: "/bin/echo")

    func testWorkspaceOverrideWinsOverEverythingElse() throws {
        let (identity, _) = try makeIdentity()
        let overrideStore = makeOverrideStore()
        overrideStore.setWorkspaceOverride(url: Self.alwaysPresentExecutable, arguments: ["--workspace"], languageKey: "test-lang", identity: identity)
        overrideStore.setGlobalOverride(url: Self.alwaysPresentExecutable, arguments: ["--global"], languageKey: "test-lang")

        let result = try LanguageServerDiscoveryEngine.resolve(
            languageKey: "test-lang",
            languageDisplayName: "Test Language",
            executableNames: ["never-found-binary"],
            arguments: [],
            versionArguments: nil,
            languageSpecificProbe: { Self.alwaysPresentExecutable },
            overrideStore: overrideStore,
            identity: identity,
            loginShellPath: { nil },
            packageManagerDirectories: []
        )
        XCTAssertEqual(result.source, .workspaceOverride)
        XCTAssertEqual(result.arguments, ["--workspace"])
    }

    func testGlobalOverrideWinsWhenNoWorkspaceOverride() throws {
        let (identity, _) = try makeIdentity()
        let overrideStore = makeOverrideStore()
        overrideStore.setGlobalOverride(url: Self.alwaysPresentExecutable, arguments: ["--global"], languageKey: "test-lang")

        let result = try LanguageServerDiscoveryEngine.resolve(
            languageKey: "test-lang",
            languageDisplayName: "Test Language",
            executableNames: ["never-found-binary"],
            arguments: [],
            versionArguments: nil,
            languageSpecificProbe: { Self.alwaysPresentExecutable },
            overrideStore: overrideStore,
            identity: identity,
            loginShellPath: { nil },
            packageManagerDirectories: []
        )
        XCTAssertEqual(result.source, .globalOverride)
    }

    func testLanguageSpecificProbeWinsWhenNoOverrides() throws {
        let (identity, _) = try makeIdentity()
        let overrideStore = makeOverrideStore()

        let result = try LanguageServerDiscoveryEngine.resolve(
            languageKey: "test-lang",
            languageDisplayName: "Test Language",
            executableNames: ["never-found-binary"],
            arguments: [],
            versionArguments: nil,
            languageSpecificProbe: { Self.alwaysPresentExecutable },
            overrideStore: overrideStore,
            identity: identity,
            loginShellPath: { nil },
            packageManagerDirectories: []
        )
        XCTAssertEqual(result.source, .languageSpecificTool)
    }

    func testLoginShellPathWinsWhenNoOverridesOrProbe() throws {
        let (identity, _) = try makeIdentity()
        let overrideStore = makeOverrideStore()

        let result = try LanguageServerDiscoveryEngine.resolve(
            languageKey: "test-lang",
            languageDisplayName: "Test Language",
            executableNames: ["echo"],
            arguments: [],
            versionArguments: nil,
            languageSpecificProbe: { nil },
            overrideStore: overrideStore,
            identity: identity,
            loginShellPath: { "/bin:/usr/bin" },
            packageManagerDirectories: []
        )
        XCTAssertEqual(result.source, .loginShellPath)
        XCTAssertEqual(result.url.path, "/bin/echo")
    }

    func testPackageManagerLocationIsTheLastResortBeforeFailure() throws {
        let (identity, _) = try makeIdentity()
        let overrideStore = makeOverrideStore()

        let result = try LanguageServerDiscoveryEngine.resolve(
            languageKey: "test-lang",
            languageDisplayName: "Test Language",
            executableNames: ["echo"],
            arguments: [],
            versionArguments: nil,
            languageSpecificProbe: { nil },
            overrideStore: overrideStore,
            identity: identity,
            loginShellPath: { nil },
            packageManagerDirectories: [URL(fileURLWithPath: "/bin")]
        )
        XCTAssertEqual(result.source, .packageManagerLocation)
        XCTAssertEqual(result.url.path, "/bin/echo")
    }

    func testManagedInstallIsTheFinalTierAfterEveryOtherFails() throws {
        let (identity, _) = try makeIdentity()
        let overrideStore = makeOverrideStore()
        let managedResult = DiscoveredExecutable(
            url: Self.alwaysPresentExecutable,
            arguments: ["--managed"],
            version: "1.2.3 (arm64, Kod-managed)",
            source: .managedInstall
        )

        let result = try LanguageServerDiscoveryEngine.resolve(
            languageKey: "test-lang",
            languageDisplayName: "Test Language",
            executableNames: ["definitely-does-not-exist-anywhere"],
            arguments: [],
            versionArguments: nil,
            languageSpecificProbe: { nil },
            managedInstallProbe: { managedResult },
            overrideStore: overrideStore,
            identity: identity,
            loginShellPath: { nil },
            packageManagerDirectories: []
        )
        XCTAssertEqual(result, managedResult)
    }

    func testManagedInstallProbeReturningNilStillReportsNotFound() throws {
        let (identity, _) = try makeIdentity()
        let overrideStore = makeOverrideStore()

        do {
            _ = try LanguageServerDiscoveryEngine.resolve(
                languageKey: "test-lang",
                languageDisplayName: "Test Language",
                executableNames: ["definitely-does-not-exist-anywhere"],
                arguments: [],
                versionArguments: nil,
                languageSpecificProbe: { nil },
                managedInstallProbe: { nil },
                overrideStore: overrideStore,
                identity: identity,
                loginShellPath: { nil },
                packageManagerDirectories: []
            )
            XCTFail("Expected notFound")
        } catch LanguageServerDiscoveryError.notFound(let name, let attempted) {
            XCTAssertEqual(name, "Test Language")
            XCTAssertEqual(attempted, [.workspaceOverride, .globalOverride, .languageSpecificTool, .loginShellPath, .packageManagerLocation, .managedInstall])
        }
    }

    func testNotFoundReportsEveryAttemptedTier() throws {
        let (identity, _) = try makeIdentity()
        let overrideStore = makeOverrideStore()

        do {
            _ = try LanguageServerDiscoveryEngine.resolve(
                languageKey: "test-lang",
                languageDisplayName: "Test Language",
                executableNames: ["definitely-does-not-exist-anywhere"],
                arguments: [],
                versionArguments: nil,
                languageSpecificProbe: { nil },
                overrideStore: overrideStore,
                identity: identity,
                loginShellPath: { nil },
                packageManagerDirectories: []
            )
            XCTFail("Expected notFound")
        } catch LanguageServerDiscoveryError.notFound(let name, let attempted) {
            XCTAssertEqual(name, "Test Language")
            XCTAssertEqual(attempted, [.workspaceOverride, .globalOverride, .languageSpecificTool, .loginShellPath, .packageManagerLocation])
        }
    }

    func testOverrideNamingANonExecutablePathFailsExplicitlyRatherThanFallingThrough() throws {
        let (identity, _) = try makeIdentity()
        let overrideStore = makeOverrideStore()
        let nonExecutable = URL(fileURLWithPath: "/definitely/does/not/exist")
        overrideStore.setGlobalOverride(url: nonExecutable, arguments: [], languageKey: "test-lang")

        do {
            _ = try LanguageServerDiscoveryEngine.resolve(
                languageKey: "test-lang",
                languageDisplayName: "Test Language",
                executableNames: ["echo"],
                arguments: [],
                versionArguments: nil,
                languageSpecificProbe: { Self.alwaysPresentExecutable },
                overrideStore: overrideStore,
                identity: identity,
                loginShellPath: { "/bin" },
                packageManagerDirectories: [URL(fileURLWithPath: "/bin")]
            )
            XCTFail("Expected overrideNotExecutable")
        } catch LanguageServerDiscoveryError.overrideNotExecutable(let url, let source) {
            XCTAssertEqual(url, nonExecutable)
            XCTAssertEqual(source, .globalOverride)
        }
    }

    func testVersionDetectionRunsTheResolvedExecutableItselfWithAFixedArgument() throws {
        let (identity, _) = try makeIdentity()
        let overrideStore = makeOverrideStore()

        let result = try LanguageServerDiscoveryEngine.resolve(
            languageKey: "test-lang",
            languageDisplayName: "Test Language",
            executableNames: ["echo"],
            arguments: [],
            versionArguments: ["hello-version"],
            languageSpecificProbe: { nil },
            overrideStore: overrideStore,
            identity: identity,
            loginShellPath: { "/bin" },
            packageManagerDirectories: []
        )
        XCTAssertEqual(result.version, "hello-version")
    }

    // MARK: - Override storage (SPEC 6.5: outside the repository)

    func testOverrideStoreRoundTripsGlobalAndWorkspaceScopedOverridesIndependently() throws {
        let (identity, _) = try makeIdentity()
        let (otherIdentity, _) = try makeIdentity()
        let overrideStore = makeOverrideStore()

        overrideStore.setGlobalOverride(url: Self.alwaysPresentExecutable, arguments: ["--global"], languageKey: "lang")
        overrideStore.setWorkspaceOverride(url: Self.alwaysPresentExecutable, arguments: ["--workspace"], languageKey: "lang", identity: identity)

        XCTAssertEqual(overrideStore.globalOverride(languageKey: "lang")?.arguments, ["--global"])
        XCTAssertEqual(overrideStore.workspaceOverride(languageKey: "lang", identity: identity)?.arguments, ["--workspace"])
        // A different workspace never sees another workspace's override.
        XCTAssertNil(overrideStore.workspaceOverride(languageKey: "lang", identity: otherIdentity))

        overrideStore.clearWorkspaceOverride(languageKey: "lang", identity: identity)
        XCTAssertNil(overrideStore.workspaceOverride(languageKey: "lang", identity: identity))
        XCTAssertNotNil(overrideStore.globalOverride(languageKey: "lang"), "Clearing the workspace override must not clear the global one")

        overrideStore.clearGlobalOverride(languageKey: "lang")
        XCTAssertNil(overrideStore.globalOverride(languageKey: "lang"))
    }
}
