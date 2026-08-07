import Foundation
import WorkspaceCore
import XCTest
@testable import LanguageAdapters

final class TypeScriptLanguageAdapterDiscoveryTests: XCTestCase {
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
        let suiteName = "TypeScriptLanguageAdapterDiscoveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return LanguageServerOverrideStore(defaults: defaults)
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

    func testTypeScriptSevenNativeLSPIsPreferredOverLegacyServer() throws {
        let directory = try makeTemporaryDirectory()
        _ = try makeExecutable(named: "typescript-language-server", version: "5.3.0", in: directory)
        let native = try makeExecutable(named: "tsc", version: "Version 7.0.2", in: directory)

        let result = try TypeScriptLanguageAdapter.discover(
            overrideStore: makeOverrideStore(),
            identity: nil,
            loginShellPath: { directory.path },
            packageManagerDirectories: [],
            managedInstallProbe: { nil }
        )

        XCTAssertEqual(result.url, native)
        XCTAssertEqual(result.arguments, ["--lsp", "--stdio"])
    }

    func testLegacyServerIsUsedWhenTSCDoesNotProvideTheNativeLSP() throws {
        let directory = try makeTemporaryDirectory()
        let legacy = try makeExecutable(named: "typescript-language-server", version: "5.3.0", in: directory)
        _ = try makeExecutable(named: "tsc", version: "Version 6.0.3", in: directory)

        let result = try TypeScriptLanguageAdapter.discover(
            overrideStore: makeOverrideStore(),
            identity: nil,
            loginShellPath: { directory.path },
            packageManagerDirectories: [],
            managedInstallProbe: { nil }
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
        store.setWorkspaceOverride(
            url: override,
            arguments: ["--custom"],
            languageKey: TypeScriptLanguageAdapter.languageKey,
            identity: identity
        )

        let result = try TypeScriptLanguageAdapter.discover(
            overrideStore: store,
            identity: identity,
            loginShellPath: { directory.path },
            packageManagerDirectories: [],
            managedInstallProbe: { nil }
        )

        XCTAssertEqual(result.url, override)
        XCTAssertEqual(result.arguments, ["--custom"])
    }
}
