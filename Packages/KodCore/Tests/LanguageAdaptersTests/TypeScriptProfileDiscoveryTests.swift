import Foundation
import WorkspaceCore
import XCTest
@testable import LanguageAdapters

/// TypeScript is the one shipped profile with two ordered executable
/// candidates gated on a minimum major version (TypeScript 7's native
/// LSP, otherwise `typescript-language-server`). These assert the
/// profile's own candidate data drives that choice — there is no
/// TypeScript-specific discovery code left to test.
final class TypeScriptProfileDiscoveryTests: XCTestCase {
    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func makeOverrideStore() throws -> LanguageServerOverrideStore {
        makeLanguageAdaptersTestOverrideStore()
    }

    private func makeExecutable(named name: String, version: String, in directory: URL) throws -> URL {
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

    private func discover(
        identity: WorkspaceIdentity? = nil,
        overrideStore: LanguageServerOverrideStore,
        directory: URL
    ) throws -> DiscoveredExecutable {
        try LanguageServerDiscoveryEngine.resolve(
            profile: DefaultLanguageProfiles.typeScript,
            overrideStore: overrideStore,
            identity: identity,
            loginShellPath: { directory.path },
            packageManagerDirectories: [],
            xcrunProbe: { _ in nil },
            rustupProbe: { _ in nil }
        )
    }

    func testTypeScriptSevenNativeLSPIsPreferredOverLegacyServer() throws {
        let directory = try makeTemporaryDirectory()
        _ = try makeExecutable(named: "typescript-language-server", version: "5.3.0", in: directory)
        let native = try makeExecutable(named: "tsc", version: "Version 7.0.2", in: directory)

        let result = try discover(
            overrideStore: makeOverrideStore(),
            directory: directory
        )

        XCTAssertEqual(result.url, native)
        XCTAssertEqual(result.arguments, ["--lsp", "--stdio"])
    }

    func testLegacyServerIsUsedWhenTSCDoesNotProvideTheNativeLSP() throws {
        let directory = try makeTemporaryDirectory()
        let legacy = try makeExecutable(named: "typescript-language-server", version: "5.3.0", in: directory)
        _ = try makeExecutable(named: "tsc", version: "Version 6.0.3", in: directory)

        let result = try discover(
            overrideStore: makeOverrideStore(),
            directory: directory
        )

        XCTAssertEqual(result.url, legacy)
        XCTAssertEqual(result.arguments, ["--stdio"])
    }

    func testExplicitWorkspaceOverrideWinsOverNativeTypeScriptSeven() throws {
        let directory = try makeTemporaryDirectory()
        let override = try makeExecutable(named: "custom-typescript-lsp", version: "custom", in: directory)
        _ = try makeExecutable(named: "tsc", version: "Version 7.0.2", in: directory)
        let identity = try WorkspaceIdentity(root: directory)
        let store = try makeOverrideStore()
        try store.setWorkspaceOverride(
            url: override,
            arguments: ["--custom"],
            languageKey: DefaultLanguageProfiles.typeScript.identifier,
            identity: identity
        )

        let result = try discover(
            identity: identity,
            overrideStore: store,
            directory: directory
        )

        XCTAssertEqual(result.url, override)
        XCTAssertEqual(result.arguments, ["--custom"])
    }

    func testNativeCandidateGateLivesInTheProfile() throws {
        let candidate = try XCTUnwrap(
            DefaultLanguageProfiles.typeScript.languageServer?
                .executableCandidates.first
        )
        XCTAssertEqual(candidate.executableNames, ["tsc"])
        XCTAssertEqual(candidate.minimumMajorVersion, 7)
    }
}
