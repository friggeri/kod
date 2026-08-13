import Foundation
import LanguageClient
import SourceModel
import WorkspaceCore
import XCTest
@testable import LanguageAdapters

final class LanguageProfileServiceFactoryTests: XCTestCase {
    @MainActor
    func testCustomProfileLaunchRequiresTrustAndUsesConfiguredLanguageIDAndArguments() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let identity = try WorkspaceIdentity(root: root)
        let suiteName =
            "LanguageProfileServiceFactoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(
                forName: suiteName
            )
        }
        let trustStore = WorkspaceTrustStore(defaults: defaults)
        let executable = try ProfileFakeLanguageServerLocator.executableURL()
        let profile = try LanguageProfile(
            identifier: "widget",
            displayName: "Widget",
            origin: .custom,
            defaultRevision: 1,
            associations: [
                LanguageFileAssociation(
                    identifier: "widget-files",
                    fileExtensions: ["widget"],
                    syntax: .plainText
                )
            ],
            languageServer: LanguageServerConfiguration(
                defaultLanguageID: "unused-default",
                languageIDOverrides: ["widget-files": "widget-lsp"],
                executableCandidates: [],
                selectedExecutable: RegisteredLanguageServerExecutable(
                    path: executable.path,
                    arguments: ["profile-config", "--profile-marker"]
                )
            )
        ).validated()
        let discoveries = LockedProfileValues<DiscoveredExecutable>()
        let diagnostics = LockedProfileValues<[NormalizedDiagnostic]>()
        let service = try LanguageProfileServiceFactory.makeService(
            for: profile,
            identity: identity,
            trustStore: trustStore,
            overrideStore: LanguageServerOverrideStore(defaults: defaults),
            onDiscovery: { discoveries.append($0) },
            onDiagnostics: { _, values in diagnostics.append(values) }
        )

        do {
            try await service.start()
            XCTFail("An untrusted workspace must not launch a custom server")
        } catch LanguageWorkspaceServiceError.notTrusted {
            // Expected.
        }
        XCTAssertTrue(discoveries.snapshot().isEmpty)

        trustStore.trust(identity)
        try await service.start()
        defer { Task { await service.stop() } }

        let fileURL = root.appendingPathComponent("sample.widget")
        let snapshot = SourceSnapshot(
            text: "widget value\n",
            url: fileURL,
            version: 1
        )
        try await service.didOpen(snapshot)

        let deadline = Date().addingTimeInterval(3)
        while !diagnostics.snapshot().joined().contains(where: {
            $0.message == "Profile configuration accepted"
        }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        let discovered = try XCTUnwrap(discoveries.snapshot().last)
        XCTAssertEqual(discovered.source, .registeredProfile)
        XCTAssertEqual(discovered.url, executable)
        XCTAssertEqual(
            discovered.arguments,
            ["profile-config", "--profile-marker"]
        )
        XCTAssertTrue(
            diagnostics.snapshot().joined().contains(where: {
                $0.message == "Profile configuration accepted"
            })
        )
        let currentState = await service.currentState
        XCTAssertEqual(currentState, LanguageServerState.ready)
    }
}

private enum ProfileFakeLanguageServerLocator {
    enum LocatorError: Error {
        case notFound
    }

    static func executableURL() throws -> URL {
        if let executable = Bundle(for: LocatorSentinel.self)
            .bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("FakeLanguageServer") as URL?,
            FileManager.default.isExecutableFile(atPath: executable.path) {
            return executable
        }

        var directory = URL(
            fileURLWithPath: #filePath
        ).deletingLastPathComponent()
        for _ in 0..<8 {
            if let executable = search(
                directory.appendingPathComponent(".build")
            ) {
                return executable
            }
            directory.deleteLastPathComponent()
        }
        throw LocatorError.notFound
    }

    private static func search(_ root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for case let url as URL in enumerator
        where url.lastPathComponent == "FakeLanguageServer"
            && FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        return nil
    }
}

private final class LocatorSentinel {}

private final class LockedProfileValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [Value] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
