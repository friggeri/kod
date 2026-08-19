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
            !$0.syntaxDescription.isEmpty
        })
        XCTAssertTrue(fixture.service.items.allSatisfy {
            if case .available = $0.serverState {
                return true
            }
            return false
        })
    }

    func testInstallationClipboardCopiesExactCommandLines() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "LanguageSupportServiceTests.\(UUID().uuidString)"
            )
        )
        let option = LanguageServerInstallCommandOption(
            id: "test",
            label: "Test",
            commandLines: ["first command", "second command"]
        )

        XCTAssertTrue(
            LanguageServerInstallationClipboard.copy(
                option,
                to: pasteboard
            )
        )
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "first command\nsecond command"
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

    func testSyntaxOnlyCustomProfilePersistsWithoutLSP() throws {
        let fixture = try makeService(defaultProfiles: [])
        var draft = LanguageProfileDraft(
            prefilling: URL(fileURLWithPath: "/tmp/example.widget")
        )
        draft.displayName = "Widget"
        draft.associations[0].syntaxLanguage = .json

        let result = try fixture.service.save(draft: draft)

        guard case .saved(let saved) = result else {
            return XCTFail("Expected profile to save without a server")
        }
        XCTAssertNil(saved.languageServer)
        XCTAssertEqual(
            fixture.service.items.first?.serverState,
            .notConfigured
        )
        XCTAssertEqual(
            fixture.service.profileRegistry.resolve(
                url: URL(fileURLWithPath: "/tmp/example.widget")
            )?.syntax,
            .treeSitter(.json)
        )
    }

    func testOverlappingAssociationRequiresConfirmationAndThenWins() throws {
        let fixture = try makeService(defaultProfiles: [
            DefaultLanguageProfiles.markdown
        ])
        var draft = LanguageProfileDraft(
            prefilling: URL(fileURLWithPath: "/tmp/notes.md")
        )
        draft.displayName = "Custom Notes"
        draft.associations[0].syntaxLanguage = nil

        let firstResult = try fixture.service.save(draft: draft)
        guard case .requiresConflictConfirmation(let conflicts) = firstResult else {
            return XCTFail("Expected overlap confirmation")
        }
        XCTAssertEqual(conflicts.count, 1)

        let confirmed = try fixture.service.save(
            draft: draft,
            confirmConflicts: true
        )
        guard case .saved(let saved) = confirmed else {
            return XCTFail("Expected confirmed profile to save")
        }
        XCTAssertEqual(
            fixture.service.profileRegistry.resolve(
                url: URL(fileURLWithPath: "/tmp/notes.md")
            )?.profile.identifier,
            saved.identifier
        )
        XCTAssertEqual(
            fixture.service.profileRegistry.resolve(
                url: URL(fileURLWithPath: "/tmp/notes.md")
            )?.syntax,
            .plainText
        )
        XCTAssertNil(
            fixture.service.syntaxLanguage(
                for: SourceSnapshot(
                    text: "# Still plain text\n",
                    url: URL(fileURLWithPath: "/tmp/notes.md")
                )
            )
        )
    }

    func testUseAutoDetectedClearsRegisteredExecutable() throws {
        let fixture = try makeService(defaultProfiles: [
            DefaultLanguageProfiles.shell
        ])
        var profile = try XCTUnwrap(
            fixture.store.profile(identifier: "shellscript")
        )
        profile.languageServer?.selectedExecutable =
            RegisteredLanguageServerExecutable(
                path: "/usr/bin/true",
                arguments: []
            )
        _ = try fixture.store.updateProfile(profile)

        try fixture.service.useAutoDetectedExecutable(
            profileIdentifier: "shellscript"
        )

        XCTAssertNil(
            fixture.store.profile(identifier: "shellscript")?
                .languageServer?.selectedExecutable
        )
    }

    func testStandaloneDocumentReloadsWhenProfileSyntaxChanges() throws {
        let fixture = try makeService(defaultProfiles: [
            DefaultLanguageProfiles.json
        ])
        let snapshot = SourceSnapshot(
            text: "{\"value\": true}\n",
            url: fixture.root.appendingPathComponent("example.json")
        )
        let controller = StandaloneDocumentViewController(
            snapshot: snapshot,
            languageSupportService: fixture.service,
            appearanceCenter: try AppearanceCenter(
                themeStore: ThemeStore(repository: fixture.repository),
                fontSettingsStore: FontSettingsStore(
                    repository: fixture.repository
                )
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 720, height: 480))
        window.layoutIfNeeded()
        let originalController = try XCTUnwrap(
            controller.children.compactMap {
                $0 as? CodeDocumentViewController
            }.first
        )
        originalController.restoreNavigationAnchor(
            selection: 2..<7,
            viewportAnchorLine: 0
        )
        controller.findInFile(nil)
        let findField = try XCTUnwrap(
            findView(
                identifier: "find.query",
                in: originalController.view
            ) as? NSSearchField
        )
        findField.stringValue = "value"
        let matchCaseButton = try XCTUnwrap(
            findView(
                identifier: "find.matchCase",
                in: originalController.view
            ) as? NSButton
        )
        matchCaseButton.state = .on
        originalController.controlTextDidChange(
            Notification(
                name: NSControl.textDidChangeNotification,
                object: findField
            )
        )
        controller.toggleWordWrap(nil)
        controller.toggleMinimap(nil)
        XCTAssertTrue(window.makeFirstResponder(originalController.viewport))
        let originalFindState = originalController.captureFindState()
        let originalContentSize = try XCTUnwrap(window.contentView).bounds.size
        XCTAssertEqual(controller.syntaxLanguage, .json)

        var profile = try XCTUnwrap(
            fixture.store.profile(identifier: "json")
        )
        profile.associations = profile.associations.map { association in
            var association = association
            association.syntax = .plainText
            return association
        }
        _ = try fixture.store.updateProfile(profile)

        XCTAssertNil(controller.syntaxLanguage)
        let replacementController = try XCTUnwrap(
            controller.children.compactMap {
                $0 as? CodeDocumentViewController
            }.first
        )
        XCTAssertFalse(replacementController === originalController)
        XCTAssertEqual(window.contentView?.bounds.size, originalContentSize)
        XCTAssertEqual(
            replacementController.captureNavigationAnchor().selection,
            2..<7
        )
        XCTAssertTrue(replacementController.isFindBarShown)
        XCTAssertEqual(
            replacementController.captureFindState(),
            originalFindState
        )
        XCTAssertTrue(replacementController.wordWrapEnabled)
        XCTAssertFalse(replacementController.minimapEnabled)
        XCTAssertTrue(window.firstResponder === replacementController.viewport)
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
