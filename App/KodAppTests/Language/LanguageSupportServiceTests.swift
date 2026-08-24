import AppKit
import CodeViewport
import FontCore
import Foundation
import KodUIComponents
import LanguageAdapters
import SettingsCore
import SourceModel
import SyntaxCore
import ThemeCore
import XCTest
@testable import Kod

@MainActor
final class LanguageSupportServiceTests: XCTestCase {
    private func findView(identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier {
            return view
        }
        for subview in view.subviews {
            if let match = findView(identifier: identifier, in: subview) {
                return match
            }
        }
        return nil
    }

    private func makeService(
        defaultProfiles: [LanguageProfile] = DefaultLanguageProfiles.all,
        discovery: @escaping LanguageSupportService.Discovery = {
            profile,
            _ in
            DiscoveredExecutable(
                url: URL(
                    fileURLWithPath:
                        "/usr/local/bin/\(profile.identifier)-lsp"
                ),
                arguments: [],
                version: "1.0.0",
                source: .loginShellPath
            )
        }
    ) throws -> (
        service: LanguageSupportService,
        store: LanguageProfileStore,
        repository: CodableSettingsRepository,
        root: URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LanguageSupportServiceTests-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let repository = CodableSettingsRepository(
            store: InMemorySettingsKeyValueStore()
        )
        let overrideStore = LanguageServerOverrideStore(
            repository: repository
        )
        let store = try LanguageProfileStore(
            defaultProfiles: defaultProfiles,
            repository: repository,
            overrideStore: overrideStore
        )
        let service = LanguageSupportService(
            profileStore: store,
            overrideStore: overrideStore,
            discovery: discovery
        )
        addTeardownBlock { [root] in
            try? FileManager.default.removeItem(at: root)
        }
        return (service, store, repository, root)
    }

    func testRefreshListsBundledSyntaxSeparatelyFromLocalServers() async throws {
        let fixture = try makeService(defaultProfiles: [
            DefaultLanguageProfiles.shell,
            DefaultLanguageProfiles.markdown,
            DefaultLanguageProfiles.json,
            DefaultLanguageProfiles.yaml,
            DefaultLanguageProfiles.toml
        ])

        await fixture.service.refresh()

        XCTAssertEqual(
            fixture.service.items.map(\.id),
            ["json", "markdown", "shellscript", "toml", "yaml"]
        )
        XCTAssertTrue(fixture.service.items.allSatisfy {
            if case .available = $0.serverState {
                return true
            }
            return false
        })
    }

    func testTargetedRefreshOnlyProbesTheSelectedLanguage() async throws {
        let swiftCalls = Box(0)
        let markdownCalls = Box(0)
        let fixture = try makeService(
            defaultProfiles: [
                DefaultLanguageProfiles.swift,
                DefaultLanguageProfiles.markdown
            ],
            discovery: { profile, _ in
                switch profile.identifier {
                case "swift":
                    swiftCalls.increment()
                case "markdown":
                    markdownCalls.increment()
                default:
                    break
                }
                return DiscoveredExecutable(
                    url: URL(fileURLWithPath: "/usr/bin/true"),
                    arguments: [],
                    version: nil,
                    source: .registeredProfile
                )
            }
        )

        await fixture.service.refresh(profileIdentifier: "swift")

        XCTAssertEqual(swiftCalls.get(), 1)
        XCTAssertEqual(markdownCalls.get(), 0)
        XCTAssertEqual(
            fixture.service.items.first {
                $0.id == "swift"
            }?.serverState.isAvailable,
            true
        )
        XCTAssertEqual(
            fixture.service.items.first {
                $0.id == "markdown"
            }?.serverState,
            .checking
        )
    }

    func testFullRefreshCapturesLoginShellPathOnlyOnceWhenCaptureFails() async throws {
        let repository = CodableSettingsRepository(
            store: InMemorySettingsKeyValueStore()
        )
        let overrideStore = LanguageServerOverrideStore(
            repository: repository
        )
        var swift = DefaultLanguageProfiles.swift
        swift.languageServer?.selectedExecutable =
            RegisteredLanguageServerExecutable(
                path: "/usr/bin/true",
                arguments: []
            )
        var markdown = DefaultLanguageProfiles.markdown
        markdown.languageServer?.selectedExecutable =
            RegisteredLanguageServerExecutable(
                path: "/usr/bin/true",
                arguments: []
            )
        let captureCount = Box(0)
        let service = LanguageSupportService(
            profileStore: try LanguageProfileStore(
                defaultProfiles: [swift, markdown],
                repository: repository,
                overrideStore: overrideStore
            ),
            overrideStore: overrideStore,
            loginShellPathCapture: {
                captureCount.increment()
                return nil
            }
        )

        await service.refresh()

        XCTAssertEqual(captureCount.get(), 1)
        XCTAssertTrue(service.items.allSatisfy {
            $0.serverState.isAvailable
        })
    }

    func testCachedStatusesRestoreAcrossServiceInstances() async throws {
        let repository = CodableSettingsRepository(
            store: InMemorySettingsKeyValueStore()
        )
        let overrideStore = LanguageServerOverrideStore(
            repository: repository
        )
        let cacheStore = LanguageServerStatusCacheStore(
            repository: repository
        )
        let firstProfileStore = try LanguageProfileStore(
            defaultProfiles: [
                DefaultLanguageProfiles.swift,
                DefaultLanguageProfiles.markdown
            ],
            repository: repository,
            overrideStore: overrideStore
        )
        let firstService = LanguageSupportService(
            profileStore: firstProfileStore,
            overrideStore: overrideStore,
            statusCacheStore: cacheStore,
            discovery: { profile, _ in
                if profile.identifier == "markdown" {
                    throw LanguageServerDiscoveryError.notFound(
                        languageName: profile.displayName,
                        attemptedSources: []
                    )
                }
                return DiscoveredExecutable(
                    url: URL(fileURLWithPath: "/usr/bin/true"),
                    arguments: ["--stdio"],
                    version: "1.0",
                    source: .loginShellPath
                )
            }
        )

        await firstService.refresh()
        let secondProfileStore = try LanguageProfileStore(
            defaultProfiles: [
                DefaultLanguageProfiles.swift,
                DefaultLanguageProfiles.markdown
            ],
            repository: repository,
            overrideStore: overrideStore
        )
        let secondService = LanguageSupportService(
            profileStore: secondProfileStore,
            overrideStore: overrideStore,
            statusCacheStore: cacheStore,
            discovery: { _, _ in
                XCTFail("Restoring the cache must not run discovery")
                throw LanguageServerDiscoveryError.notFound(
                    languageName: "Unexpected",
                    attemptedSources: []
                )
            }
        )

        guard case .available(let executable) = secondService.items.first(
            where: { $0.id == "swift" }
        )?.serverState else {
            return XCTFail("Expected cached Swift availability")
        }
        XCTAssertEqual(executable.url.path, "/usr/bin/true")
        guard case .missing = secondService.items.first(
            where: { $0.id == "markdown" }
        )?.serverState else {
            return XCTFail("Expected cached Markdown missing state")
        }
    }

    func testCommandChangeInvalidatesCachedStatus() async throws {
        let repository = CodableSettingsRepository(
            store: InMemorySettingsKeyValueStore()
        )
        let overrideStore = LanguageServerOverrideStore(
            repository: repository
        )
        let cacheStore = LanguageServerStatusCacheStore(
            repository: repository
        )
        let firstProfileStore = try LanguageProfileStore(
            defaultProfiles: [DefaultLanguageProfiles.shell],
            repository: repository,
            overrideStore: overrideStore
        )
        let firstService = LanguageSupportService(
            profileStore: firstProfileStore,
            overrideStore: overrideStore,
            statusCacheStore: cacheStore,
            discovery: { _, _ in
                DiscoveredExecutable(
                    url: URL(fileURLWithPath: "/usr/bin/true"),
                    arguments: [],
                    version: nil,
                    source: .loginShellPath
                )
            }
        )
        await firstService.refresh(profileIdentifier: "shellscript")
        try firstService.setCommand(
            "/usr/bin/false",
            profileIdentifier: "shellscript"
        )

        let secondService = LanguageSupportService(
            profileStore: try LanguageProfileStore(
                defaultProfiles: [DefaultLanguageProfiles.shell],
                repository: repository,
                overrideStore: overrideStore
            ),
            overrideStore: overrideStore,
            statusCacheStore: cacheStore
        )

        XCTAssertEqual(
            secondService.items.first?.serverState,
            .checking
        )
    }

    func testCommandChangeSupersedesInFlightDiscovery() async throws {
        let gate = DispatchSemaphore(value: 0)
        let repository = CodableSettingsRepository(
            store: InMemorySettingsKeyValueStore()
        )
        let overrideStore = LanguageServerOverrideStore(
            repository: repository
        )
        let service = LanguageSupportService(
            profileStore: try LanguageProfileStore(
                defaultProfiles: [DefaultLanguageProfiles.shell],
                repository: repository,
                overrideStore: overrideStore
            ),
            overrideStore: overrideStore,
            statusCacheStore: LanguageServerStatusCacheStore(
                repository: repository
            ),
            discovery: { _, _ in
                gate.wait()
                return DiscoveredExecutable(
                    url: URL(fileURLWithPath: "/usr/bin/true"),
                    arguments: [],
                    version: nil,
                    source: .loginShellPath
                )
            }
        )

        async let staleRefresh: Void = service.refresh(
            profileIdentifier: "shellscript"
        )
        try await Task.sleep(for: .milliseconds(50))
        try service.setCommand(
            "/usr/bin/false",
            profileIdentifier: "shellscript"
        )
        gate.signal()
        await staleRefresh

        XCTAssertEqual(service.items.first?.serverState, .checking)
        let restored = LanguageSupportService(
            profileStore: try LanguageProfileStore(
                defaultProfiles: [DefaultLanguageProfiles.shell],
                repository: repository,
                overrideStore: overrideStore
            ),
            overrideStore: overrideStore,
            statusCacheStore: LanguageServerStatusCacheStore(
                repository: repository
            )
        )
        XCTAssertEqual(restored.items.first?.serverState, .checking)
    }

    func testRepeatedProfileFocusRequestsRemainObservable() throws {
        let fixture = try makeService()
        let initialRevision = fixture.service.focusRequestRevision

        fixture.service.focusProfile(identifier: "swift")
        XCTAssertEqual(fixture.service.focusedProfileIdentifier, "swift")
        XCTAssertEqual(
            fixture.service.focusRequestRevision,
            initialRevision + 1
        )

        fixture.service.focusProfile(identifier: "swift")
        XCTAssertEqual(fixture.service.focusedProfileIdentifier, "swift")
        XCTAssertEqual(
            fixture.service.focusRequestRevision,
            initialRevision + 2
        )
    }

    func testChooseExecutableUsesCandidateSpecificTaploArguments() throws {
        let fixture = try makeService(defaultProfiles: [
            DefaultLanguageProfiles.toml
        ])
        let taplo = fixture.root.appendingPathComponent("taplo")
        try "#!/bin/sh\nexit 0\n".write(
            to: taplo,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: taplo.path
        )

        try fixture.service.setSelectedExecutable(
            profileIdentifier: "toml",
            url: taplo
        )

        let selected = try XCTUnwrap(
            fixture.store.profile(identifier: "toml")?
                .languageServer?.selectedExecutable
        )
        XCTAssertEqual(selected.path, taplo.path)
        XCTAssertEqual(selected.arguments, ["lsp", "stdio"])
    }

    func testProfileWithoutLanguageServerKeepsSyntaxAvailable() throws {
        var syntaxOnlyMarkdown = DefaultLanguageProfiles.markdown
        syntaxOnlyMarkdown.languageServer = nil
        let fixture = try makeService(defaultProfiles: [
            syntaxOnlyMarkdown
        ])

        let states = Dictionary(
            uniqueKeysWithValues: fixture.service.items.map {
                ($0.id, $0.serverState)
            }
        )

        XCTAssertEqual(states["markdown"], .syntaxOnly)
        XCTAssertEqual(
            fixture.service.profileRegistry.resolve(
                url: URL(fileURLWithPath: "/tmp/README.md")
            )?.syntax,
            .treeSitter(.markdown)
        )
    }

    func testCommandPersistsQuotedArgumentsAndClearsBackToAutomatic() throws {
        let fixture = try makeService(defaultProfiles: [
            DefaultLanguageProfiles.shell
        ])
        try fixture.service.setCommand(
            #"/usr/bin/true "--name=hello world" "" '$(never-executed)'"#,
            profileIdentifier: "shellscript"
        )

        let selected = try XCTUnwrap(
            fixture.store.profile(identifier: "shellscript")?
                .languageServer?.selectedExecutable
        )
        XCTAssertEqual(selected.path, "/usr/bin/true")
        XCTAssertEqual(
            selected.arguments,
            ["--name=hello world", "", "$(never-executed)"]
        )

        try fixture.service.setCommand(
            "  ",
            profileIdentifier: "shellscript"
        )

        XCTAssertNil(
            fixture.store.profile(identifier: "shellscript")?
                .languageServer?.selectedExecutable
        )
    }

    func testCommandRoundTripsQuotedPathsEscapesAndEmptyArguments() throws {
        let command = LanguageServerCommandLine.format(
            path: "/tmp/Language Server/bin/server",
            arguments: [
                "--label=hello world",
                #"quote"value"#,
                #"slash\value"#,
                ""
            ]
        )

        let parsed = try XCTUnwrap(LanguageServerCommandLine.parse(command))

        XCTAssertEqual(parsed.path, "/tmp/Language Server/bin/server")
        XCTAssertEqual(
            parsed.arguments,
            [
                "--label=hello world",
                #"quote"value"#,
                #"slash\value"#,
                ""
            ]
        )
    }

    func testCommandParserTreatsNewlinesAsTokenSeparators() throws {
        let parsed = try XCTUnwrap(
            LanguageServerCommandLine.parse(
                """
                /usr/bin/true
                --stdio
                "--label=hello world"
                """
            )
        )

        XCTAssertEqual(parsed.path, "/usr/bin/true")
        XCTAssertEqual(
            parsed.arguments,
            ["--stdio", "--label=hello world"]
        )
    }

    func testCommandRejectsMalformedOrRelativeInput() {
        XCTAssertThrowsError(
            try LanguageServerCommandLine.parse(#"/usr/bin/true "unfinished"#)
        ) { error in
            XCTAssertEqual(
                error as? LanguageServerCommandLineError,
                .unterminatedQuote
            )
        }
        XCTAssertThrowsError(
            try LanguageServerCommandLine.parse("server --stdio")
        ) { error in
            XCTAssertEqual(
                error as? LanguageServerCommandLineError,
                .executableMustBeAbsolute("server")
            )
        }
        XCTAssertThrowsError(
            try LanguageServerCommandLine.parse(#"/usr/bin/true trailing\"#)
        ) { error in
            XCTAssertEqual(
                error as? LanguageServerCommandLineError,
                .trailingEscape
            )
        }
    }

    func testInvalidCommandPreservesThePreviousOverride() throws {
        let fixture = try makeService(defaultProfiles: [
            DefaultLanguageProfiles.shell
        ])
        try fixture.service.setCommand(
            "/usr/bin/true --stdio",
            profileIdentifier: "shellscript"
        )
        let previous = fixture.store.profile(identifier: "shellscript")?
            .languageServer?.selectedExecutable

        XCTAssertThrowsError(
            try fixture.service.setCommand(
                "/definitely/not/an/executable --stdio",
                profileIdentifier: "shellscript"
            )
        )

        XCTAssertEqual(
            fixture.store.profile(identifier: "shellscript")?
                .languageServer?.selectedExecutable,
            previous
        )

        let directory = fixture.root.appendingPathComponent(
            "not-a-server",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: directory.path)
        )
        XCTAssertThrowsError(
            try fixture.service.setCommand(
                directory.path,
                profileIdentifier: "shellscript"
            )
        )
        XCTAssertEqual(
            fixture.store.profile(identifier: "shellscript")?
                .languageServer?.selectedExecutable,
            previous
        )
    }

    /// SPEC (implement-language-ui-refresh): a `refresh()` that finds a
    /// previously-missing executable now available must post a typed
    /// `.executableDiscovery` `.kodLanguageSupportChanged` notification
    /// for that profile, and only that profile — reflecting the current
    /// refresh's result, not a stale one.
    func testRefreshPostsExecutableDiscoveryNotificationOnlyWhenAnExecutableBecomesAvailable() async throws {
        let shouldSucceed = Box(false)
        let fixture = try makeService(
            defaultProfiles: [DefaultLanguageProfiles.shell],
            discovery: { profile, _ in
                if shouldSucceed.get() {
                    return DiscoveredExecutable(
                        url: URL(fileURLWithPath: "/usr/local/bin/shellscript-lsp"),
                        arguments: [],
                        version: "1.0.0",
                        source: .loginShellPath
                    )
                }
                throw LanguageServerDiscoveryError.notFound(
                    languageName: profile.displayName,
                    attemptedSources: []
                )
            }
        )

        await fixture.service.refresh()
        guard case .missing = fixture.service.items.first?.serverState else {
            return XCTFail("Expected the first refresh to leave the item missing")
        }

        let received = Box<[Notification]>([])
        let observer = NotificationCenter.default.addObserver(
            forName: .kodLanguageSupportChanged,
            object: fixture.service,
            queue: nil
        ) { notification in
            received.set(received.get() + [notification])
        }
        addTeardownBlock {
            NotificationCenter.default.removeObserver(observer)
        }

        shouldSucceed.set(true)
        await fixture.service.refresh()

        XCTAssertEqual(received.get().count, 1)
        XCTAssertEqual(
            received.get().first?.languageSupportChangedKey,
            "shellscript"
        )
        XCTAssertEqual(
            received.get().first?.languageSupportChangeKind,
            .executableDiscovery
        )
        guard case .available = fixture.service.items.first?.serverState else {
            return XCTFail("Expected the second refresh to leave the item available")
        }

        // Once available, further refreshes must not re-notify: nothing
        // changed, and Settings must not needlessly ask an active
        // workspace to restart an already-healthy service.
        received.set([])
        await fixture.service.refresh()
        XCTAssertTrue(received.get().isEmpty)
    }

    /// SPEC (implement-language-ui-refresh): if two `refresh()` calls
    /// overlap, a slower call that resolves after a faster, later call
    /// must not overwrite (or notify for) its now-stale result.
    func testOverlappingRefreshesDoNotLetAStaleResultOverwriteANewerOne() async throws {
        let gate = DispatchSemaphore(value: 0)
        let callCount = Box(0)
        let fixture = try makeService(
            defaultProfiles: [DefaultLanguageProfiles.shell],
            discovery: { profile, _ in
                let call = callCount.increment()
                if call == 1 {
                    // Block the first (stale) refresh's discovery until
                    // the test explicitly releases it, after the second
                    // (newer) refresh has already completed.
                    gate.wait()
                    throw LanguageServerDiscoveryError.notFound(
                        languageName: profile.displayName,
                        attemptedSources: []
                    )
                }
                return DiscoveredExecutable(
                    url: URL(fileURLWithPath: "/usr/local/bin/shellscript-lsp"),
                    arguments: [],
                    version: "1.0.0",
                    source: .loginShellPath
                )
            }
        )

        let service = fixture.service
        async let first: Void = service.refresh()
        // Give the first refresh's task group a moment to reach and
        // block inside `discovery`.
        try await Task.sleep(for: .milliseconds(50))

        await service.refresh()
        guard case .available = service.items.first?.serverState else {
            return XCTFail("Expected the second (newer) refresh to resolve to available")
        }

        gate.signal()
        await first

        guard case .available = service.items.first?.serverState else {
            return XCTFail(
                "The slower, stale first refresh must not overwrite the newer available result"
            )
        }
    }

    func testTargetedRefreshesForDifferentProfilesDoNotSupersedeEachOther() async throws {
        let swiftGate = DispatchSemaphore(value: 0)
        let fixture = try makeService(
            defaultProfiles: [
                DefaultLanguageProfiles.swift,
                DefaultLanguageProfiles.markdown
            ],
            discovery: { profile, _ in
                if profile.identifier == "swift" {
                    swiftGate.wait()
                }
                return DiscoveredExecutable(
                    url: URL(fileURLWithPath: "/usr/bin/true"),
                    arguments: [],
                    version: nil,
                    source: .registeredProfile
                )
            }
        )
        let service = fixture.service

        async let swiftRefresh: Void = service.refresh(
            profileIdentifier: "swift"
        )
        try await Task.sleep(for: .milliseconds(50))
        await service.refresh(profileIdentifier: "markdown")
        XCTAssertEqual(
            service.items.first { $0.id == "markdown" }?
                .serverState.isAvailable,
            true
        )

        swiftGate.signal()
        await swiftRefresh
        XCTAssertEqual(
            service.items.first { $0.id == "swift" }?
                .serverState.isAvailable,
            true
        )
    }
}

/// A tiny thread-safe box for capturing/mutating a value written from a
/// `@Sendable` discovery closure invoked concurrently from a task group,
/// and read back from the test's `await` context.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ initial: T) {
        self.value = initial
    }

    func set(_ newValue: T) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

extension Box where T == Int {
    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
