import Foundation
import KodFixtureSupport
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

        let suiteName = "WorkspaceTrustStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
        }

        let store = WorkspaceTrustStore(defaults: defaults)
        XCTAssertFalse(store.isTrusted(identity))
        store.trust(identity)
        XCTAssertTrue(store.isTrusted(identity))
        store.revoke(identity)
        XCTAssertFalse(store.isTrusted(identity))
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
            let classified = try XCTUnwrap(
                scanner.classify(path: root.appendingPathComponent(relativePath), root: root)
            )
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

        let classified = WorkspaceScanner().classify(
            path: root.appendingPathComponent(".git/hooks/sample"),
            root: root
        )
        XCTAssertNil(classified)
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

        let classified = WorkspaceScanner().classify(path: outsidePath, root: root)
        XCTAssertNil(classified)
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

    func testFilenameIndexSearchesOneHundredThousandPaths() async {
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
