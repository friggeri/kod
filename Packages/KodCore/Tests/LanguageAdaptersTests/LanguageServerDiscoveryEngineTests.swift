import Darwin
import Foundation
import WorkspaceCore
import XCTest
@testable import LanguageAdapters

/// Exercises SPEC 6.5's deterministic discovery precedence in isolation
/// (workspace override > registered profile executable > global override
/// > language-specific tool > login-shell PATH > package-manager
/// location) using synthetic profiles, independent of any shipped
/// default profile or real executable.
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
        makeLanguageAdaptersTestOverrideStore()
    }

    /// A real, always-executable binary to point overrides/fake PATH
    /// entries at, so `isExecutableFile` checks succeed deterministically
    /// regardless of what happens to be installed on the test machine.
    private static let alwaysPresentExecutable = URL(fileURLWithPath: "/bin/echo")

    /// A shipped-shaped profile: only default profiles may declare the
    /// `xcrun` tier, so the language-specific tier is exercised through
    /// one, with its probe injected rather than launching a real tool.
    private func makeProfile(
        identifier: String = "test-lang",
        displayName: String = "Test Language",
        origin: LanguageProfileOrigin = .default,
        executableNames: [String] = ["never-found-binary"],
        arguments: [String] = [],
        versionArguments: [String]? = nil,
        discoveryStrategies: [LanguageServerDiscoveryStrategy] = [
            .xcrun(tool: "test-tool"),
            .path,
            .packageManagerLocations
        ],
        minimumMajorVersion: Int? = nil,
        selectedExecutable: RegisteredLanguageServerExecutable? = nil
    ) throws -> LanguageProfile {
        try LanguageProfile(
            identifier: identifier,
            displayName: displayName,
            origin: origin,
            defaultRevision: 1,
            associations: [
                LanguageFileAssociation(
                    identifier: identifier,
                    fileExtensions: ["testlang"],
                    syntax: .plainText
                )
            ],
            languageServer: LanguageServerConfiguration(
                defaultLanguageID: identifier,
                executableCandidates: [
                    LanguageServerExecutableCandidate(
                        identifier: "candidate",
                        executableNames: executableNames,
                        arguments: arguments,
                        versionArguments: versionArguments,
                        discoveryStrategies: discoveryStrategies,
                        minimumMajorVersion: minimumMajorVersion
                    )
                ],
                selectedExecutable: selectedExecutable
            )
        ).validated()
    }

    func testWorkspaceOverrideWinsOverEverythingElse() throws {
        let (identity, _) = try makeIdentity()
        let overrideStore = makeOverrideStore()
        try overrideStore.setWorkspaceOverride(url: Self.alwaysPresentExecutable, arguments: ["--workspace"], languageKey: "test-lang", identity: identity)
        try overrideStore.setGlobalOverride(url: Self.alwaysPresentExecutable, arguments: ["--global"], languageKey: "test-lang")

        let result = try LanguageServerDiscoveryEngine.resolve(
            profile: makeProfile(
                selectedExecutable: RegisteredLanguageServerExecutable(
                    path: Self.alwaysPresentExecutable.path,
                    arguments: ["--registered"]
                )
            ),
            overrideStore: overrideStore,
            identity: identity,
            loginShellPath: { nil },
            packageManagerDirectories: [],
            xcrunProbe: { _ in Self.alwaysPresentExecutable },
            rustupProbe: { _ in nil }
        )
        XCTAssertEqual(result.source, .workspaceOverride)
        XCTAssertEqual(result.arguments, ["--workspace"])
    }

    func testRegisteredProfileExecutableWinsOverGlobalOverride() throws {
        let (identity, _) = try makeIdentity()
        let overrideStore = makeOverrideStore()
        try overrideStore.setGlobalOverride(url: Self.alwaysPresentExecutable, arguments: ["--global"], languageKey: "test-lang")

        let result = try LanguageServerDiscoveryEngine.resolve(
            profile: makeProfile(
                selectedExecutable: RegisteredLanguageServerExecutable(
                    path: Self.alwaysPresentExecutable.path,
                    arguments: ["--registered"]
                )
            ),
            overrideStore: overrideStore,
            identity: identity,
            loginShellPath: { nil },
            packageManagerDirectories: [],
            xcrunProbe: { _ in Self.alwaysPresentExecutable },
            rustupProbe: { _ in nil }
        )
        XCTAssertEqual(result.source, .registeredProfile)
        XCTAssertEqual(result.arguments, ["--registered"])
    }

    func testGlobalOverrideWinsWhenNoWorkspaceOverrideOrRegisteredExecutable() throws {
        let (identity, _) = try makeIdentity()
        let overrideStore = makeOverrideStore()
        try overrideStore.setGlobalOverride(url: Self.alwaysPresentExecutable, arguments: ["--global"], languageKey: "test-lang")

        let result = try LanguageServerDiscoveryEngine.resolve(
            profile: makeProfile(),
            overrideStore: overrideStore,
            identity: identity,
            loginShellPath: { nil },
            packageManagerDirectories: [],
            xcrunProbe: { _ in Self.alwaysPresentExecutable },
            rustupProbe: { _ in nil }
        )
        XCTAssertEqual(result.source, .globalOverride)
        XCTAssertEqual(result.arguments, ["--global"])
    }

    func testLanguageSpecificProbeWinsWhenNoOverrides() throws {
        let (identity, _) = try makeIdentity()

        let result = try LanguageServerDiscoveryEngine.resolve(
            profile: makeProfile(arguments: ["--candidate"]),
            overrideStore: makeOverrideStore(),
            identity: identity,
            loginShellPath: { nil },
            packageManagerDirectories: [],
            xcrunProbe: { _ in Self.alwaysPresentExecutable },
            rustupProbe: { _ in nil }
        )
        XCTAssertEqual(result.source, .languageSpecificTool)
        XCTAssertEqual(
            result.arguments,
            ["--candidate"],
            "A specialized tier must still launch the candidate's own fixed arguments"
        )
    }

    func testLoginShellPathWinsWhenNoOverridesOrProbe() throws {
        let (identity, _) = try makeIdentity()

        let result = try LanguageServerDiscoveryEngine.resolve(
            profile: makeProfile(executableNames: ["echo"]),
            overrideStore: makeOverrideStore(),
            identity: identity,
            loginShellPath: { "/bin:/usr/bin" },
            packageManagerDirectories: [],
            xcrunProbe: { _ in nil },
            rustupProbe: { _ in nil }
        )
        XCTAssertEqual(result.source, .loginShellPath)
        XCTAssertEqual(result.url.path, "/bin/echo")
    }

    func testRelativeLoginShellPathEntriesAreIgnored() throws {
        let (identity, _) = try makeIdentity()

        let result = try LanguageServerDiscoveryEngine.resolve(
            profile: makeProfile(executableNames: ["echo"]),
            overrideStore: makeOverrideStore(),
            identity: identity,
            loginShellPath: { "relative-bin:/bin" },
            packageManagerDirectories: [],
            xcrunProbe: { _ in nil },
            rustupProbe: { _ in nil }
        )
        XCTAssertEqual(result.url.path, "/bin/echo")
    }

    func testPackageManagerLocationIsTheLastResortBeforeFailure() throws {
        let (identity, _) = try makeIdentity()

        let result = try LanguageServerDiscoveryEngine.resolve(
            profile: makeProfile(executableNames: ["echo"]),
            overrideStore: makeOverrideStore(),
            identity: identity,
            loginShellPath: { nil },
            packageManagerDirectories: [URL(fileURLWithPath: "/bin")],
            xcrunProbe: { _ in nil },
            rustupProbe: { _ in nil }
        )
        XCTAssertEqual(result.source, .packageManagerLocation)
        XCTAssertEqual(result.url.path, "/bin/echo")
    }

    func testDefaultPackageManagerLocationsIncludePnpmBinDirectory() {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/pnpm/bin")
        XCTAssertTrue(LanguageServerDiscoveryEngine.defaultPackageManagerDirectories().contains(expected))
    }

    func testDefaultPackageManagerLocationsIncludeDefaultGoBinDirectory() {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("go/bin")
        XCTAssertTrue(
            LanguageServerDiscoveryEngine.defaultPackageManagerDirectories()
                .contains(expected)
        )
    }

    func testLoginShellPathCaptureUsesAnInteractiveLoginShell() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let shell = root.appendingPathComponent("fake-shell")
        try """
        #!/bin/sh
        [ "$1" = "-l" ] && [ "$2" = "-i" ] && [ "$3" = "-c" ] || exit 2
        /bin/sh -c "$4"
        """.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: shell.path
        )

        XCTAssertNotNil(LoginShellPathCapture.capture(shellURL: shell))
    }

    func testLoginShellPathCaptureTerminatesDescendantsThatRetainStdout() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let pidFile = root.appendingPathComponent("shell-child.pid")
        let shell = root.appendingPathComponent("forking-shell")
        try """
        #!/bin/sh
        [ "$1" = "-l" ] && [ "$2" = "-i" ] && [ "$3" = "-c" ] || exit 2
        (
          trap '' TERM
          exec sleep 30
        ) &
        echo $! > "\(pidFile.path)"
        /bin/sh -c "$4"
        """.write(
            to: shell,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: shell.path
        )

        XCTAssertNotNil(
            LoginShellPathCapture.capture(
                shellURL: shell,
                timeout: 1
            )
        )
        let childPID = try XCTUnwrap(
            Int32(
                String(contentsOf: pidFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        for _ in 0..<20 where Darwin.kill(childPID, 0) == 0 {
            usleep(25_000)
        }
        XCTAssertNotEqual(
            Darwin.kill(childPID, 0),
            0,
            "Login-shell capture must not leave descendants running"
        )
    }

    func testNotFoundReportsEveryAttemptedTier() throws {
        let (identity, _) = try makeIdentity()

        do {
            _ = try LanguageServerDiscoveryEngine.resolve(
                profile: makeProfile(
                    executableNames: ["definitely-does-not-exist-anywhere"]
                ),
                overrideStore: makeOverrideStore(),
                identity: identity,
                loginShellPath: { nil },
                packageManagerDirectories: [],
                xcrunProbe: { _ in nil },
                rustupProbe: { _ in nil }
            )
            XCTFail("Expected notFound")
        } catch LanguageServerDiscoveryError.notFound(let name, let attempted) {
            XCTAssertEqual(name, "Test Language")
            XCTAssertEqual(
                attempted,
                [
                    .workspaceOverride,
                    .registeredProfile,
                    .globalOverride,
                    .languageSpecificTool,
                    .loginShellPath,
                    .packageManagerLocation
                ]
            )
        }
    }

    func testOverrideNamingANonExecutablePathFailsExplicitlyRatherThanFallingThrough() throws {
        let (identity, _) = try makeIdentity()
        let overrideStore = makeOverrideStore()
        let nonExecutable = URL(fileURLWithPath: "/definitely/does/not/exist")
        try overrideStore.setGlobalOverride(url: nonExecutable, arguments: [], languageKey: "test-lang")

        do {
            _ = try LanguageServerDiscoveryEngine.resolve(
                profile: makeProfile(executableNames: ["echo"]),
                overrideStore: overrideStore,
                identity: identity,
                loginShellPath: { "/bin" },
                packageManagerDirectories: [URL(fileURLWithPath: "/bin")],
                xcrunProbe: { _ in Self.alwaysPresentExecutable },
                rustupProbe: { _ in nil }
            )
            XCTFail("Expected overrideNotExecutable")
        } catch LanguageServerDiscoveryError.overrideNotExecutable(let url, let source) {
            XCTAssertEqual(url, nonExecutable)
            XCTAssertEqual(source, .globalOverride)
        }
    }

    func testVersionDetectionRunsTheResolvedExecutableItselfWithAFixedArgument() throws {
        let (identity, _) = try makeIdentity()

        let result = try LanguageServerDiscoveryEngine.resolve(
            profile: makeProfile(
                executableNames: ["echo"],
                versionArguments: ["hello-version"]
            ),
            overrideStore: makeOverrideStore(),
            identity: identity,
            loginShellPath: { "/bin" },
            packageManagerDirectories: [],
            xcrunProbe: { _ in nil },
            rustupProbe: { _ in nil }
        )
        XCTAssertEqual(result.version, "hello-version")
    }

    func testVersionDetectionTimesOutForAHungExecutable() throws {
        let (identity, _) = try makeIdentity()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let server = root.appendingPathComponent("hung-lsp")
        try "#!/bin/sh\nexec sleep 30\n".write(
            to: server,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: server.path
        )
        let start = Date()

        let result = try LanguageServerDiscoveryEngine.resolve(
            profile: makeProfile(
                executableNames: ["hung-lsp"],
                versionArguments: ["--version"]
            ),
            overrideStore: makeOverrideStore(),
            identity: identity,
            loginShellPath: { root.path },
            packageManagerDirectories: [],
            xcrunProbe: { _ in nil },
            rustupProbe: { _ in nil }
        )

        XCTAssertNil(result.version)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    func testVersionDetectionTimesOutForContinuousStdout() throws {
        let (identity, _) = try makeIdentity()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let server = root.appendingPathComponent("noisy-lsp")
        try """
        #!/bin/sh
        while :; do
          printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
        done
        """.write(
            to: server,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: server.path
        )
        let start = Date()

        let result = try LanguageServerDiscoveryEngine.resolve(
            profile: makeProfile(
                executableNames: ["noisy-lsp"],
                versionArguments: ["--version"]
            ),
            overrideStore: makeOverrideStore(),
            identity: identity,
            loginShellPath: { root.path },
            packageManagerDirectories: [],
            xcrunProbe: { _ in nil },
            rustupProbe: { _ in nil }
        )

        XCTAssertNil(result.version)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    func testVersionProbeTerminatesDescendantsThatRetainStdout() throws {
        let (identity, _) = try makeIdentity()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let pidFile = root.appendingPathComponent("child.pid")
        let server = root.appendingPathComponent("forking-lsp")
        try """
        #!/bin/sh
        (
          trap '' TERM
          exec sleep 30
        ) &
        echo $! > "$1"
        exit 0
        """.write(
            to: server,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: server.path
        )
        let start = Date()

        let result = try LanguageServerDiscoveryEngine.resolve(
            profile: makeProfile(
                executableNames: ["forking-lsp"],
                versionArguments: [pidFile.path]
            ),
            overrideStore: makeOverrideStore(),
            identity: identity,
            loginShellPath: { root.path },
            packageManagerDirectories: [],
            xcrunProbe: { _ in nil },
            rustupProbe: { _ in nil }
        )

        XCTAssertNil(result.version)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        let childPID = try XCTUnwrap(
            Int32(
                String(contentsOf: pidFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        for _ in 0..<20 where Darwin.kill(childPID, 0) == 0 {
            usleep(25_000)
        }
        XCTAssertNotEqual(
            Darwin.kill(childPID, 0),
            0,
            "The version probe must not leave descendants running"
        )
    }

    // MARK: - Override storage (SPEC 6.5: outside the repository)

    func testOverrideStoreRoundTripsGlobalAndWorkspaceScopedOverridesIndependently() throws {
        let (identity, _) = try makeIdentity()
        let (otherIdentity, _) = try makeIdentity()
        let overrideStore = makeOverrideStore()

        try overrideStore.setGlobalOverride(url: Self.alwaysPresentExecutable, arguments: ["--global"], languageKey: "lang")
        try overrideStore.setWorkspaceOverride(url: Self.alwaysPresentExecutable, arguments: ["--workspace"], languageKey: "lang", identity: identity)

        guard case .value(let global, _) =
                try overrideStore.globalOverride(languageKey: "lang"),
              case .value(let workspace, _) =
                try overrideStore.workspaceOverride(
                    languageKey: "lang",
                    identity: identity
                ) else {
            return XCTFail("Expected both overrides")
        }
        XCTAssertEqual(global.arguments, ["--global"])
        XCTAssertEqual(workspace.arguments, ["--workspace"])
        // A different workspace never sees another workspace's override.
        XCTAssertEqual(
            try overrideStore.workspaceOverride(
                languageKey: "lang",
                identity: otherIdentity
            ),
            .absent
        )

        try overrideStore.clearWorkspaceOverride(languageKey: "lang", identity: identity)
        XCTAssertEqual(
            try overrideStore.workspaceOverride(
                languageKey: "lang",
                identity: identity
            ),
            .absent
        )
        guard case .value = try overrideStore.globalOverride(
            languageKey: "lang"
        ) else {
            return XCTFail(
                "Clearing the workspace override must not clear the global one"
            )
        }

        try overrideStore.clearGlobalOverride(languageKey: "lang")
        XCTAssertEqual(
            try overrideStore.globalOverride(languageKey: "lang"),
            .absent
        )
    }
}
