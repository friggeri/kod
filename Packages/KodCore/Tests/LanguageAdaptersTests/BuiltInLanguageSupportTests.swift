import Foundation
import LanguageClient
import SourceModel
import WorkspaceCore
import XCTest
@testable import LanguageAdapters

final class BuiltInLanguageSupportTests: XCTestCase {
    func testRegistryRoutesEveryFirstWaveLanguage() throws {
        let snapshot = LanguageProfileRegistrySnapshot(
            profiles: DefaultLanguageProfiles.all
        )
        let cases: [(String, String, String)] = [
            ("/tmp/script.sh", "shellscript", "shellscript"),
            ("/tmp/README.md", "markdown", "markdown"),
            ("/tmp/config.json", "json", "json"),
            ("/tmp/config.yml", "yaml", "yaml"),
            ("/tmp/config.toml", "toml", "toml")
        ]

        for (path, expectedProfile, expectedLanguageID) in cases {
            let url = URL(fileURLWithPath: path)
            let resolved = try XCTUnwrap(snapshot.resolve(url: url))
            XCTAssertEqual(resolved.profile.identifier, expectedProfile, path)
            XCTAssertEqual(resolved.languageID, expectedLanguageID, path)
        }

        let profileURL = URL(fileURLWithPath: "/tmp/.bashrc")
        XCTAssertEqual(
            try XCTUnwrap(snapshot.resolve(url: profileURL))
                .profile.identifier,
            "shellscript"
        )
    }

    func testRegistryRoutesExtensionlessShellScriptsByShebang() throws {
        let snapshot = SourceSnapshot(
            text: "#!/usr/bin/env bash\nprintf 'hello\\n'\n",
            url: URL(fileURLWithPath: "/tmp/build")
        )

        let registry = LanguageProfileRegistrySnapshot(
            profiles: DefaultLanguageProfiles.all
        )
        XCTAssertEqual(
            try XCTUnwrap(registry.resolve(snapshot: snapshot))
                .profile.identifier,
            "shellscript"
        )
    }

    func testJSONProfileDiscoversStandaloneServerFromPnpmBin() throws {
        let pnpmBin = try makeTemporaryDirectory()
            .appendingPathComponent("Library/pnpm/bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: pnpmBin,
            withIntermediateDirectories: true
        )
        let standalone = try makeExecutable(
            named: "vscode-json-languageserver",
            in: pnpmBin
        )

        let result = try LanguageServerDiscoveryEngine.resolve(
            profile: DefaultLanguageProfiles.json,
            overrideStore: makeOverrideStore(),
            identity: nil,
            loginShellPath: { nil },
            packageManagerDirectories: [pnpmBin],
            xcrunProbe: { _ in nil },
            rustupProbe: { _ in nil }
        )

        XCTAssertEqual(result.url, standalone)
        XCTAssertEqual(result.source, .packageManagerLocation)
        XCTAssertEqual(result.arguments, ["--stdio"])
    }

    func testJSONProfileKeepsPreferredNameAndSupportsStandaloneName() throws {
        let candidate = try XCTUnwrap(
            DefaultLanguageProfiles.json.languageServer?
                .executableCandidates.first
        )
        XCTAssertEqual(
            candidate.executableNames,
            ["vscode-json-language-server", "vscode-json-languageserver"]
        )
        XCTAssertEqual(candidate.arguments, ["--stdio"])
        XCTAssertNil(
            candidate.versionArguments,
            "This server errors out on any invocation without a transport flag"
        )
    }

    func testTOMLFallsBackToTaploWhenTombiIsUnavailable() throws {
        let directory = try makeTemporaryDirectory()
        let taplo = try makeExecutable(named: "taplo", in: directory)

        let result = try LanguageServerDiscoveryEngine.resolve(
            profile: DefaultLanguageProfiles.toml,
            overrideStore: makeOverrideStore(),
            identity: nil,
            loginShellPath: { directory.path },
            packageManagerDirectories: [],
            xcrunProbe: { _ in nil },
            rustupProbe: { _ in nil }
        )

        XCTAssertEqual(result.url, taplo)
        XCTAssertEqual(result.arguments, ["lsp", "stdio"])
    }

    func testTOMLPrefersTombiWithItsOwnCandidateArguments() throws {
        let directory = try makeTemporaryDirectory()
        let tombi = try makeExecutable(named: "tombi", in: directory)
        _ = try makeExecutable(named: "taplo", in: directory)

        let result = try LanguageServerDiscoveryEngine.resolve(
            profile: DefaultLanguageProfiles.toml,
            overrideStore: makeOverrideStore(),
            identity: nil,
            loginShellPath: { directory.path },
            packageManagerDirectories: [],
            xcrunProbe: { _ in nil },
            rustupProbe: { _ in nil }
        )

        XCTAssertEqual(result.url, tombi)
        XCTAssertEqual(result.arguments, ["lsp"])
    }

    func testShellCheckIsConfiguredOnlyWithResolvedAbsoluteExecutable() throws {
        let directory = try makeTemporaryDirectory()
        let shellCheck = try makeExecutable(
            named: "shellcheck",
            in: directory
        )

        let resolved = ShellCheckSupport.discoverShellCheck(
            loginShellPath: "relative-bin:\(directory.path)",
            packageManagerDirectories: []
        )
        XCTAssertEqual(resolved, shellCheck)

        let shipped = try XCTUnwrap(
            DefaultLanguageProfiles.shell.languageServer?.workspaceConfiguration
        )
        XCTAssertEqual(
            shipped["bashIde"],
            .object([
                "shellcheckPath": .string(""),
                "shfmt": .object(["path": .string("")])
            ]),
            "The shipped profile is the only place this configuration is defined"
        )
        XCTAssertEqual(
            ShellCheckSupport.resolvedWorkspaceConfiguration(
                shipped,
                shellCheckURL: resolved
            ),
            [
                "bashIde": .object([
                    "shellcheckPath": .string(shellCheck.path),
                    "shfmt": .object(["path": .string("")])
                ])
            ]
        )
        XCTAssertEqual(
            ShellCheckSupport.resolvedWorkspaceConfiguration(
                shipped,
                shellCheckURL: nil
            ),
            shipped
        )
    }

    func testShellCheckHelperNeverInventsConfigurationTheProfileDidNotShip() {
        XCTAssertTrue(
            ShellCheckSupport.resolvedWorkspaceConfiguration(
                [:],
                shellCheckURL: URL(fileURLWithPath: "/usr/local/bin/shellcheck")
            ).isEmpty
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuiltInLanguageSupportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func makeExecutable(named name: String, in directory: URL) throws -> URL {
        let executable = directory.appendingPathComponent(name)
        try "#!/bin/sh\necho 1.0.0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return executable
    }

    private func makeOverrideStore() throws -> LanguageServerOverrideStore {
        makeLanguageAdaptersTestOverrideStore()
    }
}
