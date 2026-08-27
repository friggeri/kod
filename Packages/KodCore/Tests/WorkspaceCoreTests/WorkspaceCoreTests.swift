import Foundation
import KodFixtureSupport
import SettingsCore
import XCTest
@testable import WorkspaceCore

final class WorkspaceCoreTests: XCTestCase {
    @MainActor
    func testIdentityCanonicalizesDirectoryAndTrustPersistsOutsideWorkspace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }

        let identity = try WorkspaceIdentity(root: root.appendingPathComponent("."))
        XCTAssertEqual(identity.root, root.resolvingSymlinksInPath())
        XCTAssertEqual(identity.persistenceKey.count, 64)

        let repository = CodableSettingsRepository(
            store: InMemorySettingsKeyValueStore()
        )
        let store = WorkspaceTrustStore(repository: repository)
        XCTAssertFalse(store.isTrusted(identity))
        try store.trust(identity)
        XCTAssertTrue(store.isTrusted(identity))
        try store.revoke(identity)
        XCTAssertFalse(store.isTrusted(identity))
    }

    @MainActor
    func testLegacyTrustBooleanMigratesAndCorruptionIsReported() throws {
        let identity = try WorkspaceIdentity(
            root: FileManager.default.temporaryDirectory
        )
        let key = "trusted-workspace.\(identity.persistenceKey)"
        let keyValueStore = InMemorySettingsKeyValueStore()
        let repository = CodableSettingsRepository(store: keyValueStore)
        let store = WorkspaceTrustStore(repository: repository)

        try keyValueStore.setValue(.boolean(true), forKey: key)
        XCTAssertEqual(try store.trustState(identity), .trusted)
        guard let migrated = try keyValueStore.value(forKey: key),
              case .data = migrated else {
            return XCTFail("Expected migrated trust envelope")
        }

        try keyValueStore.setValue(
            .data(Data("corrupt".utf8)),
            forKey: key
        )
        guard case .resetAfterQuarantine(let record) =
                try store.trustState(identity) else {
            return XCTFail("Expected corrupt trust state to be explicit")
        }
        XCTAssertEqual(record.key, key)
        XCTAssertFalse(store.isTrusted(identity))
    }

    @MainActor
    func testFailedTrustRevocationStillFailsClosedForCurrentSession() throws {
        let identity = try WorkspaceIdentity(
            root: FileManager.default.temporaryDirectory
        )
        let keyValueStore = RemoveFailingSettingsStore()
        let repository = CodableSettingsRepository(store: keyValueStore)
        let store = WorkspaceTrustStore(repository: repository)
        try store.trust(identity)
        XCTAssertTrue(store.isTrusted(identity))

        XCTAssertThrowsError(try store.revoke(identity))

        XCTAssertFalse(
            store.isTrusted(identity),
            "A failed persistence removal must not leave this session trusted"
        )
        XCTAssertTrue(
            WorkspaceTrustStore(repository: repository).isTrusted(identity),
            "The underlying persisted value remains until a later retry succeeds"
        )
    }

    @MainActor
    func testLegacyRecentWorkspacePathsMigrateAndRespectLimit() throws {
        let keyValueStore = InMemorySettingsKeyValueStore(
            initialValues: [
                "recent-workspaces": .stringArray(["/one", "/two"])
            ]
        )
        let repository = CodableSettingsRepository(store: keyValueStore)
        let store = RecentWorkspaceStore(
            repository: repository,
            limit: 2
        )

        guard case .value(let legacyRoots, let provenance) =
                try store.roots() else {
            return XCTFail("Expected legacy recent roots")
        }

        XCTAssertEqual(legacyRoots.map(\.path), ["/one", "/two"])
        XCTAssertEqual(
            provenance,
            .migrated(from: .unversioned, toVersion: 1)
        )

        try store.record(URL(fileURLWithPath: "/three"))
        guard case .value(let roots, _) = try store.roots() else {
            return XCTFail("Expected recent roots")
        }
        XCTAssertEqual(roots.map(\.path), ["/three", "/one"])
    }

    func testScannerRespectsIgnoreHiddenAndSymlinkRules() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }

        try Data("ignored/\n*.tmp\n!important.tmp\n".utf8)
            .write(to: root.appendingPathComponent(".gitignore"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources"),
            withIntermediateDirectories: true
        )
        try Data("let value = 1".utf8)
            .write(to: root.appendingPathComponent("Sources/main.swift"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("ignored"),
            withIntermediateDirectories: true
        )
        try Data("ignored".utf8)
            .write(to: root.appendingPathComponent("ignored/file.swift"))
        try Data("temporary".utf8)
            .write(to: root.appendingPathComponent("cache.tmp"))
        try Data("important".utf8)
            .write(to: root.appendingPathComponent("important.tmp"))
        try Data("hidden".utf8)
            .write(to: root.appendingPathComponent(".hidden.swift"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("source-link"),
            withDestinationURL: root.appendingPathComponent("Sources")
        )

        var entries: [WorkspaceFileEntry] = []
        for try await batch in WorkspaceScanner().scan(root: root) {
            entries.append(contentsOf: batch.entries)
        }
        let paths = Set(entries.map(\.relativePath))

        XCTAssertTrue(paths.contains("Sources"))
        XCTAssertTrue(paths.contains("Sources/main.swift"))
        XCTAssertTrue(paths.contains("important.tmp"))
        XCTAssertTrue(paths.contains("source-link"))
        XCTAssertFalse(paths.contains("ignored"))
        XCTAssertFalse(paths.contains("ignored/file.swift"))
        XCTAssertFalse(paths.contains("cache.tmp"))
        XCTAssertFalse(paths.contains(".hidden.swift"))
        XCTAssertEqual(
            entries.first(where: { $0.relativePath == "source-link" })?.kind,
            .symbolicLink
        )

        var revealedEntries: [WorkspaceFileEntry] = []
        let revealOptions = WorkspaceDiscoveryOptions(includeHidden: true, includeIgnored: true)
        for try await batch in WorkspaceScanner().scan(root: root, options: revealOptions) {
            revealedEntries.append(contentsOf: batch.entries)
        }
        let revealedPaths = Set(revealedEntries.map(\.relativePath))
        XCTAssertTrue(revealedPaths.contains(".gitignore"))
        XCTAssertTrue(revealedPaths.contains(".hidden.swift"))
        XCTAssertTrue(revealedPaths.contains("ignored"))
        XCTAssertTrue(revealedPaths.contains("ignored/file.swift"))
        XCTAssertTrue(revealedPaths.contains("cache.tmp"))
        XCTAssertTrue(revealedEntries.first(where: { $0.relativePath == "ignored" })?.isIgnored == true)
    }

    func testClassifyPathMatchesFullScanForNestedIgnoreRules() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }

        // Root-level .gitignore ignores "Generated/", but a nested
        // Sources/.gitignore re-includes "Sources/Generated/keep.swift" via
        // a negated pattern — classify(path:root:) must see both files to
        // agree with a full scan.
        try Data("Generated/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources/Generated"),
            withIntermediateDirectories: true
        )
        try Data("nested ignore\n!Generated/keep.swift\n".utf8)
            .write(to: root.appendingPathComponent("Sources/.gitignore"))
        try Data("dropped".utf8)
            .write(to: root.appendingPathComponent("Sources/Generated/dropped.swift"))
        try Data("kept".utf8)
            .write(to: root.appendingPathComponent("Sources/Generated/keep.swift"))

        var scannedEntries: [String: WorkspaceFileEntry] = [:]
        for try await batch in WorkspaceScanner().scan(root: root, options: WorkspaceDiscoveryOptions(includeIgnored: true)) {
            for entry in batch.entries {
                scannedEntries[entry.relativePath] = entry
            }
        }

        let scanner = WorkspaceScanner()
        for relativePath in ["Sources/Generated/dropped.swift", "Sources/Generated/keep.swift"] {
            let outcome = try scanner.classify(
                path: root.appendingPathComponent(relativePath),
                root: root
            )
            guard case .entry(let classified) = outcome else {
                return XCTFail("expected entry for \(relativePath), got \(outcome)")
            }
            let scanned = try XCTUnwrap(scannedEntries[relativePath])
            XCTAssertEqual(classified.isIgnored, scanned.isIgnored, "mismatch for \(relativePath)")
            XCTAssertEqual(classified.relativePath, scanned.relativePath)
        }
    }

    func testClassifyPathReturnsNilForGitDirectoryContents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git/hooks"),
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }
        try Data("sample".utf8).write(to: root.appendingPathComponent(".git/hooks/sample"))

        let classified = try WorkspaceScanner().classify(
            path: root.appendingPathComponent(".git/hooks/sample"),
            root: root
        )
        XCTAssertEqual(classified, .excluded(.gitMetadata))
    }

    func testScannerEmitsBreadthFirstWithRootEntriesBeforeDescendants() async throws {
        let root = URL(fileURLWithPath: "/virtual-workspace", isDirectory: true)
        let directory = root.appendingPathComponent("a-directory", isDirectory: true)
        let rootFile = root.appendingPathComponent("z-root.swift")
        let nestedFile = directory.appendingPathComponent("nested.swift")
        let scanner = WorkspaceScanner(
            directoryEnumerator: FixtureDirectoryEnumerator(
                children: [
                    root: [directory, rootFile],
                    directory: [nestedFile]
                ]
            ),
            metadataProvider: FixtureMetadataProvider(
                metadata: [
                    directory: WorkspacePathMetadata(
                        isDirectory: true,
                        isSymbolicLink: false,
                        isHidden: false
                    ),
                    rootFile: WorkspacePathMetadata(
                        isDirectory: false,
                        isSymbolicLink: false,
                        isHidden: false
                    ),
                    nestedFile: WorkspacePathMetadata(
                        isDirectory: false,
                        isSymbolicLink: false,
                        isHidden: false
                    )
                ]
            ),
            ignoreFileSource: FixtureIgnoreFileSource(contents: [:])
        )
        var paths: [String] = []

        for try await batch in scanner.scan(
            root: root,
            options: WorkspaceDiscoveryOptions(batchSize: 1)
        ) {
            paths.append(contentsOf: batch.entries.map(\.relativePath))
        }

        XCTAssertEqual(
            paths,
            ["a-directory", "z-root.swift", "a-directory/nested.swift"]
        )

        var rootPaths: [String] = []
        for try await batch in scanner.scanDirectory(
            root: root,
            relativePath: ""
        ) {
            rootPaths.append(contentsOf: batch.entries.map(\.relativePath))
        }
        XCTAssertEqual(rootPaths, ["a-directory", "z-root.swift"])
    }

    func testDirectoryScanListsImmediateChildrenOnly() async throws {
        let root = URL(fileURLWithPath: "/virtual-workspace", isDirectory: true)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        let child = sources.appendingPathComponent("main.swift")
        let nestedDirectory = sources.appendingPathComponent("Nested", isDirectory: true)
        let grandchild = nestedDirectory.appendingPathComponent("deep.swift")
        let scanner = WorkspaceScanner(
            directoryEnumerator: FixtureDirectoryEnumerator(
                children: [
                    sources: [child, nestedDirectory],
                    nestedDirectory: [grandchild]
                ]
            ),
            metadataProvider: FixtureMetadataProvider(
                metadata: [
                    sources: WorkspacePathMetadata(
                        isDirectory: true,
                        isSymbolicLink: false,
                        isHidden: false
                    ),
                    child: WorkspacePathMetadata(
                        isDirectory: false,
                        isSymbolicLink: false,
                        isHidden: false
                    ),
                    nestedDirectory: WorkspacePathMetadata(
                        isDirectory: true,
                        isSymbolicLink: false,
                        isHidden: false
                    ),
                    grandchild: WorkspacePathMetadata(
                        isDirectory: false,
                        isSymbolicLink: false,
                        isHidden: false
                    )
                ]
            ),
            ignoreFileSource: FixtureIgnoreFileSource(contents: [:])
        )
        var paths: [String] = []

        for try await batch in scanner.scanDirectory(
            root: root,
            relativePath: "Sources"
        ) {
            paths.append(contentsOf: batch.entries.map(\.relativePath))
        }

        XCTAssertEqual(paths, ["Sources/main.swift", "Sources/Nested"])
        XCTAssertFalse(paths.contains("Sources/Nested/deep.swift"))
    }

    func testClassifyPathReturnsNilForPathOutsideRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }
        let outsidePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("elsewhere-\(UUID().uuidString).txt")

        let classified = try WorkspaceScanner().classify(path: outsidePath, root: root)
        XCTAssertEqual(classified, .excluded(.outsideRoot))
    }

    func testClassifyDistinguishesAbsentFromMetadataFailure() throws {
        let root = URL(fileURLWithPath: "/virtual-workspace", isDirectory: true)
        let absent = root.appendingPathComponent("missing.swift")
        let failed = root.appendingPathComponent("denied.swift")
        let scanner = WorkspaceScanner(
            directoryEnumerator: FixtureDirectoryEnumerator(children: [:]),
            metadataProvider: FixtureMetadataProvider(
                metadata: [:],
                failures: [failed: .permissionDenied]
            ),
            ignoreFileSource: FixtureIgnoreFileSource(contents: [:])
        )

        XCTAssertEqual(try scanner.classify(path: absent, root: root), .absent)
        XCTAssertThrowsError(try scanner.classify(path: failed, root: root)) { error in
            XCTAssertEqual(
                error as? WorkspaceScannerError,
                .metadataFailed(failed, .permissionDenied)
            )
        }
    }

    func testUnreadableIgnoreRulesAreExplicitForScanAndClassify() async throws {
        let root = URL(fileURLWithPath: "/virtual-workspace", isDirectory: true)
        let file = root.appendingPathComponent("main.swift")
        let scanner = WorkspaceScanner(
            directoryEnumerator: FixtureDirectoryEnumerator(
                children: [root: [file]]
            ),
            metadataProvider: FixtureMetadataProvider(
                metadata: [
                    file: WorkspacePathMetadata(
                        isDirectory: false,
                        isSymbolicLink: false,
                        isHidden: false
                    )
                ]
            ),
            ignoreFileSource: FixtureIgnoreFileSource(
                contents: [:],
                failures: [root: .permissionDenied]
            )
        )

        XCTAssertThrowsError(try scanner.classify(path: file, root: root)) { error in
            XCTAssertEqual(
                error as? WorkspaceScannerError,
                .unreadableIgnoreFile(
                    root.appendingPathComponent(".gitignore"),
                    .permissionDenied
                )
            )
        }

        do {
            for try await _ in scanner.scan(root: root) {}
            XCTFail("scan should report unreadable ignore data")
        } catch {
            XCTAssertEqual(
                error as? WorkspaceScannerError,
                .unreadableIgnoreFile(
                    root.appendingPathComponent(".gitignore"),
                    .permissionDenied
                )
            )
        }
    }

    func testDirectoryEnumerationPermissionFailureIsTyped() async {
        let root = URL(fileURLWithPath: "/virtual-workspace", isDirectory: true)
        let scanner = WorkspaceScanner(
            directoryEnumerator: FixtureDirectoryEnumerator(
                children: [:],
                failures: [root: .permissionDenied]
            ),
            metadataProvider: FixtureMetadataProvider(metadata: [:]),
            ignoreFileSource: FixtureIgnoreFileSource(contents: [:])
        )

        do {
            for try await _ in scanner.scan(root: root) {}
            XCTFail("scan should report directory enumeration failure")
        } catch {
            XCTAssertEqual(
                error as? WorkspaceScannerError,
                .directoryEnumerationFailed(root, .permissionDenied)
            )
        }
    }

    func testScannerOrdersChildrenByNaturalCaseInsensitiveComparison() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }

        for name in ["file-10.swift", "Beta.swift", "file-2.swift", "alpha.swift", "File-3.swift"] {
            try Data("source".utf8).write(to: root.appendingPathComponent(name))
        }

        let expected = [
            "alpha.swift",
            "Beta.swift",
            "file-2.swift",
            "File-3.swift",
            "file-10.swift"
        ]

        var scanned: [String] = []
        for try await batch in WorkspaceScanner().scan(root: root) {
            scanned.append(contentsOf: batch.entries.map(\.relativePath))
        }
        XCTAssertEqual(scanned, expected)

        var listed: [String] = []
        for try await batch in WorkspaceScanner().scanDirectory(root: root, relativePath: "") {
            listed.append(contentsOf: batch.entries.map(\.relativePath))
        }
        XCTAssertEqual(listed, expected)
    }

    func testHiddenClassificationUsesChildNameRatherThanAncestorPath() async throws {
        let root = URL(fileURLWithPath: "/virtual-workspace", isDirectory: true)
        let hiddenDirectory = root.appendingPathComponent(".config", isDirectory: true)
        let visibleInsideHidden = hiddenDirectory.appendingPathComponent("settings.json")
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        let nestedDotFile = sources.appendingPathComponent(".env")
        let nestedFile = sources.appendingPathComponent("main.swift")
        let rootDotFile = root.appendingPathComponent(".hidden.swift")
        let directoryMetadata = WorkspacePathMetadata(
            isDirectory: true,
            isSymbolicLink: false,
            isHidden: false
        )
        let fileMetadata = WorkspacePathMetadata(
            isDirectory: false,
            isSymbolicLink: false,
            isHidden: false
        )
        let scanner = WorkspaceScanner(
            directoryEnumerator: FixtureDirectoryEnumerator(
                children: [
                    root: [hiddenDirectory, rootDotFile, sources],
                    hiddenDirectory: [visibleInsideHidden],
                    sources: [nestedDotFile, nestedFile]
                ]
            ),
            metadataProvider: FixtureMetadataProvider(
                metadata: [
                    hiddenDirectory: directoryMetadata,
                    sources: directoryMetadata,
                    visibleInsideHidden: fileMetadata,
                    nestedDotFile: fileMetadata,
                    nestedFile: fileMetadata,
                    rootDotFile: fileMetadata
                ]
            ),
            ignoreFileSource: FixtureIgnoreFileSource(contents: [:])
        )

        var visiblePaths: [String] = []
        for try await batch in scanner.scan(root: root) {
            visiblePaths.append(contentsOf: batch.entries.map(\.relativePath))
        }
        XCTAssertEqual(visiblePaths, ["Sources", "Sources/main.swift"])

        var revealed: [String: WorkspaceFileEntry] = [:]
        for try await batch in scanner.scan(
            root: root,
            options: WorkspaceDiscoveryOptions(includeHidden: true)
        ) {
            for entry in batch.entries {
                revealed[entry.relativePath] = entry
            }
        }
        XCTAssertEqual(revealed[".hidden.swift"]?.isHidden, true)
        XCTAssertEqual(revealed["Sources/.env"]?.isHidden, true)
        XCTAssertEqual(revealed[".config"]?.isHidden, true)
        XCTAssertEqual(revealed[".config/settings.json"]?.isHidden, false)

        for path in [rootDotFile, nestedDotFile, visibleInsideHidden, nestedFile] {
            guard case .entry(let classified) = try scanner.classify(path: path, root: root) else {
                return XCTFail("expected injected metadata to classify \(path)")
            }
            XCTAssertEqual(classified, revealed[classified.relativePath])
        }
    }

    func testLocalMetadataMatchesUncachedValuesForFilesDirectoriesAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources"),
            withIntermediateDirectories: true
        )
        try Data("source".utf8).write(to: root.appendingPathComponent("main.swift"))
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden.swift"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("source-link"),
            withDestinationURL: root.appendingPathComponent("Sources")
        )

        let provider = LocalPathMetadataProvider()
        let children = try LocalDirectoryEnumerator().children(of: root)
        XCTAssertEqual(children.count, 4)

        var byName: [String: WorkspacePathMetadata] = [:]
        for child in children {
            let listed = try XCTUnwrap(provider.metadata(for: child))
            let rebuilt = try XCTUnwrap(
                provider.metadata(for: URL(fileURLWithPath: child.path))
            )
            XCTAssertEqual(
                listed,
                rebuilt,
                "a listed URL must answer exactly like a freshly built one for \(child.path)"
            )
            byName[child.lastPathComponent] = listed
        }

        XCTAssertEqual(byName["Sources"]?.isDirectory, true)
        XCTAssertEqual(byName["Sources"]?.isSymbolicLink, false)
        XCTAssertEqual(byName["main.swift"]?.isDirectory, false)
        XCTAssertEqual(byName[".hidden.swift"]?.isHidden, true)
        XCTAssertEqual(byName["source-link"]?.isSymbolicLink, true)
    }

    func testUnreadableDirectoryOnDiskReportsTypedPermissionDenied() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let restricted = root.appendingPathComponent("restricted", isDirectory: true)
        try FileManager.default.createDirectory(at: restricted, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }
        try Data("secret".utf8).write(to: restricted.appendingPathComponent("secret.swift"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: restricted.path
        )
        addTeardownBlock {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: restricted.path
            )
        }
        try XCTSkipUnless(
            (try? FileManager.default.contentsOfDirectory(atPath: restricted.path)) == nil,
            "process bypasses directory permissions"
        )

        var visited: [String] = []
        do {
            for try await batch in WorkspaceScanner().scan(root: root) {
                visited.append(contentsOf: batch.entries.map(\.relativePath))
            }
            XCTFail("scan should report the unreadable directory")
        } catch {
            // The scan opens each directory before it can read anything
            // inside it, so an unreadable directory is named by the failure
            // rather than by a probe for a `.gitignore` it could never
            // have reached.
            guard case .directoryEnumerationFailed(let url, let failure) = try XCTUnwrap(
                error as? WorkspaceScannerError
            ) else {
                return XCTFail("expected a typed enumeration failure, got \(error)")
            }
            XCTAssertEqual(failure, .permissionDenied)
            XCTAssertTrue(
                url.path.hasSuffix("/restricted"),
                "unexpected failure path \(url.path)"
            )
        }
        XCTAssertEqual(visited, ["restricted"])
    }

    func testInjectedCapabilitiesKeepInitialAndIncrementalClassificationConsistentWithoutDiskWrites() async throws {
        let root = URL(fileURLWithPath: "/virtual-workspace", isDirectory: true)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        let kept = sources.appendingPathComponent("keep.swift")
        let dropped = sources.appendingPathComponent("drop.tmp")
        let metadata: [URL: WorkspacePathMetadata] = [
            sources: WorkspacePathMetadata(
                isDirectory: true,
                isSymbolicLink: false,
                isHidden: false
            ),
            kept: WorkspacePathMetadata(
                isDirectory: false,
                isSymbolicLink: false,
                isHidden: false
            ),
            dropped: WorkspacePathMetadata(
                isDirectory: false,
                isSymbolicLink: false,
                isHidden: false
            )
        ]
        let scanner = WorkspaceScanner(
            directoryEnumerator: FixtureDirectoryEnumerator(
                children: [
                    root: [sources],
                    sources: [dropped, kept]
                ]
            ),
            metadataProvider: FixtureMetadataProvider(metadata: metadata),
            ignoreFileSource: FixtureIgnoreFileSource(
                contents: [root: "*.tmp\n"]
            )
        )

        var initial: [String: WorkspaceFileEntry] = [:]
        for try await batch in scanner.scan(
            root: root,
            options: WorkspaceDiscoveryOptions(includeIgnored: true)
        ) {
            for entry in batch.entries {
                initial[entry.relativePath] = entry
            }
        }

        for path in [kept, dropped] {
            guard case .entry(let incremental) = try scanner.classify(
                path: path,
                root: root
            ) else {
                return XCTFail("expected injected metadata to classify \(path)")
            }
            XCTAssertEqual(incremental, initial[incremental.relativePath])
        }
    }

    func testFilenameIndexRanksBasenameAndContiguousMatches() async {
        let index = FilenameIndex()
        await index.append([
            entry("Sources/Feature/UserService.swift"),
            entry("Sources/User.swift"),
            entry("Tests/UserServiceTests.swift")
        ])

        let exact = await index.search("user")
        XCTAssertEqual(exact.first?.entry.relativePath, "Sources/User.swift")

        let fuzzy = await index.search("featureusers")
        XCTAssertEqual(fuzzy.first?.entry.relativePath, "Sources/Feature/UserService.swift")
    }

    private struct FixtureDirectoryEnumerator: DirectoryEnumerator {
        let children: [URL: [URL]]
        let failures: [URL: WorkspaceAccessFailure]

        init(
            children: [URL: [URL]],
            failures: [URL: WorkspaceAccessFailure] = [:]
        ) {
            self.children = children
            self.failures = failures
        }

        func children(of directory: URL) throws -> [URL] {
            if let failure = failures[directory] {
                throw failure
            }
            return children[directory] ?? []
        }
    }

    private struct FixtureMetadataProvider: PathMetadataProvider {
        let metadata: [URL: WorkspacePathMetadata]
        let failures: [URL: WorkspaceAccessFailure]

        init(
            metadata: [URL: WorkspacePathMetadata],
            failures: [URL: WorkspaceAccessFailure] = [:]
        ) {
            self.metadata = metadata
            self.failures = failures
        }

        func metadata(for path: URL) throws -> WorkspacePathMetadata? {
            if let failure = failures[path] {
                throw failure
            }
            return metadata[path]
        }
    }

    private struct FixtureIgnoreFileSource: IgnoreFileSource {
        let contents: [URL: String]
        let failures: [URL: WorkspaceAccessFailure]

        init(
            contents: [URL: String],
            failures: [URL: WorkspaceAccessFailure] = [:]
        ) {
            self.contents = contents
            self.failures = failures
        }

        func ignoreFileContents(in directory: URL) throws -> String? {
            if let failure = failures[directory] {
                throw failure
            }
            return contents[directory]
        }
    }

    func testFilenameIndexIncrementalRemoveDropsExactAndFuzzyMatchesWithoutFullRescan() async {
        let index = FilenameIndex()
        await index.append([
            entry("Sources/User.swift"),
            entry("Sources/Other.swift")
        ])
        let countAfterAppend = await index.count
        XCTAssertEqual(countAfterAppend, 2)

        await index.remove(relativePaths: ["Sources/User.swift"])

        let countAfterRemove = await index.count
        XCTAssertEqual(countAfterRemove, 1)
        let exact = await index.search("Sources/User.swift")
        XCTAssertTrue(exact.isEmpty)
        let fuzzy = await index.search("user")
        XCTAssertTrue(fuzzy.isEmpty)
        let emptyQuery = await index.search("")
        XCTAssertEqual(emptyQuery.map(\.entry.relativePath), ["Sources/Other.swift"])
    }

    func testFilenameIndexAppendDeduplicatesExistingPath() async {
        let index = FilenameIndex()
        await index.append([entry("Sources/User.swift")])
        await index.append([entry("Sources/User.swift")])

        let count = await index.count
        XCTAssertEqual(count, 1)
        let matches = await index.search("user")
        XCTAssertEqual(
            matches.map(\.entry.relativePath),
            ["Sources/User.swift"]
        )
    }

    func testFilenameIndexRemoveIsANoOpForUnknownPaths() async {
        let index = FilenameIndex()
        await index.append([entry("Sources/User.swift")])

        await index.remove(relativePaths: ["Sources/DoesNotExist.swift"])

        let countAfterNoOpRemove = await index.count
        XCTAssertEqual(countAfterNoOpRemove, 1)
    }

    func testFilenameIndexReappendAfterRemoveIsVisibleAgain() async {
        let index = FilenameIndex()
        await index.append([entry("Sources/User.swift")])
        await index.remove(relativePaths: ["Sources/User.swift"])
        let countAfterRemoveAll = await index.count
        XCTAssertEqual(countAfterRemoveAll, 0)

        await index.append([entry("Sources/User.swift")])

        let countAfterReappend = await index.count
        XCTAssertEqual(countAfterReappend, 1)
        let matches = await index.search("Sources/User.swift")
        XCTAssertEqual(matches.first?.entry.relativePath, "Sources/User.swift")
    }

    func testFilenameIndexSearchesOneHundredThousandPaths() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[
                "KOD_RUN_LARGE_FILE_BENCHMARKS"
            ] == "1",
            "Performance benchmark runs through release qualification."
        )
        let index = FilenameIndex()
        let entries = (0..<100_000).map { item in
            entry(String(format: "Sources/%03d/File-%06d.swift", item / 1_000, item))
        }
        await index.append(entries)

        let start = ContinuousClock.now
        let matches = await index.search("File-099999")
        let elapsed = ContinuousClock.now - start

        XCTAssertEqual(matches.first?.entry.relativePath, "Sources/099/File-099999.swift")
        XCTAssertLessThan(elapsed, .milliseconds(100))
    }

    func testDiscoversOneHundredThousandFilesWithinBudget() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["KOD_RUN_SCALE_TESTS"] == "1",
            "Scale test runs through Scripts/verify-phase 2"
        )

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }
        try ScaleFixtureGenerator().generate(
            ScaleFixtureConfiguration(
                root: root,
                fileCount: 100_000,
                bytesPerFile: 32
            )
        )

        let start = ContinuousClock.now
        var discoveredCount = 0
        var firstBatchElapsed: Duration?
        for try await batch in WorkspaceScanner().scan(root: root) {
            if firstBatchElapsed == nil {
                firstBatchElapsed = ContinuousClock.now - start
            }
            discoveredCount += batch.entries.count
        }
        let elapsed = ContinuousClock.now - start
        let firstBatch = try XCTUnwrap(firstBatchElapsed)

        print("100k discovery first batch: \(firstBatch); complete: \(elapsed)")

        XCTAssertEqual(discoveredCount, 100_100)
        XCTAssertLessThan(firstBatch, .seconds(1.5))
        XCTAssertLessThan(elapsed, .seconds(3))
    }

    private func entry(_ relativePath: String) -> WorkspaceFileEntry {
        WorkspaceFileEntry(
            url: URL(fileURLWithPath: "/workspace/\(relativePath)"),
            relativePath: relativePath,
            kind: .file,
            isHidden: false,
            isIgnored: false
        )
    }
}
