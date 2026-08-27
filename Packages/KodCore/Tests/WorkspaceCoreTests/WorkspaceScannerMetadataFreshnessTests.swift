import Foundation
import WorkspaceCore
import XCTest

/// Regressions for the time-of-check/time-of-use window between listing a
/// directory and acting on one of its children. The scanner must read each
/// path's type from the filesystem immediately before it classifies or
/// descends into it, so an entry swapped for a symbolic link, a file, or
/// nothing at all can never produce a stale entry, recursion outside the
/// workspace root, or a symlink cycle.
final class WorkspaceScannerMetadataFreshnessTests: XCTestCase {
    // MARK: - Provider-level freshness

    func testListedURLsCarryNoCachedTypeSoLaterSwapsAreObserved() throws {
        let root = try makeDirectory()
        let outside = try makeDirectory()
        try Data("escaped".utf8).write(to: outside.appendingPathComponent("escaped.txt"))
        let inside = root.appendingPathComponent("inside", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)

        let listed = try LocalDirectoryEnumerator().children(of: root)
        let listedInside = try XCTUnwrap(listed.first { $0.lastPathComponent == "inside" })
        // Seed Foundation's per-URL resource-value cache exactly as a
        // listing-time prefetch does, so this regression fails for any
        // provider that answers from that cache instead of the filesystem.
        let seeded = try listedInside.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isHiddenKey
        ])
        XCTAssertEqual(seeded.isDirectory, true)

        try FileManager.default.removeItem(at: inside)
        try FileManager.default.createSymbolicLink(at: inside, withDestinationURL: outside)

        let metadata = try XCTUnwrap(
            LocalPathMetadataProvider().metadata(for: listedInside)
        )
        XCTAssertTrue(
            metadata.isSymbolicLink,
            "metadata read after the swap must not answer from a listing-time cache"
        )
        XCTAssertFalse(metadata.isDirectory)
    }

    func testListingPreservesExactChildNames() throws {
        let root = try makeDirectory()
        let names = [
            "plain.swift",
            "with space.swift",
            "ünïcødé-📁.swift",
            ".dotfile",
            String(repeating: "n", count: 240) + ".swift"
        ]
        for name in names {
            try Data("source".utf8).write(to: root.appendingPathComponent(name))
        }

        let listed = try LocalDirectoryEnumerator().children(of: root)
        XCTAssertEqual(
            Set(listed.map(\.lastPathComponent)),
            Set(names),
            "names must survive the raw directory read byte for byte"
        )
        for url in listed {
            XCTAssertNotNil(try LocalPathMetadataProvider().metadata(for: url))
        }
    }

    func testLocalEnumeratorRefusesToListThroughASymbolicLink() throws {
        let root = try makeDirectory()
        let outside = try makeDirectory()
        try Data("escaped".utf8).write(to: outside.appendingPathComponent("escaped.txt"))
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertThrowsError(try LocalDirectoryEnumerator().children(of: link)) { error in
            XCTAssertEqual(error as? WorkspaceAccessFailure, .unavailable)
        }
        XCTAssertEqual(
            try LocalDirectoryEnumerator().children(of: outside).map(\.lastPathComponent),
            ["escaped.txt"],
            "the link's destination itself stays listable"
        )
    }

    func testLocalMetadataTypesAbsencePermissionAndDanglingLinks() throws {
        let root = try makeDirectory()
        let provider = LocalPathMetadataProvider()

        XCTAssertNil(try provider.metadata(for: root.appendingPathComponent("missing.swift")))

        let dangling = root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(
            at: dangling,
            withDestinationURL: root.appendingPathComponent("never-created")
        )
        let danglingMetadata = try XCTUnwrap(provider.metadata(for: dangling))
        XCTAssertTrue(danglingMetadata.isSymbolicLink)
        XCTAssertFalse(danglingMetadata.isDirectory)

        let restricted = root.appendingPathComponent("restricted", isDirectory: true)
        try FileManager.default.createDirectory(at: restricted, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: restricted.appendingPathComponent("secret.swift"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: restricted.path
        )
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: restricted.path
            )
        }
        try XCTSkipUnless(
            (try? FileManager.default.contentsOfDirectory(atPath: restricted.path)) == nil,
            "process bypasses directory permissions"
        )

        XCTAssertThrowsError(
            try provider.metadata(for: restricted.appendingPathComponent("secret.swift"))
        ) { error in
            XCTAssertEqual(error as? WorkspaceAccessFailure, .permissionDenied)
        }
    }

    func testFilesystemHiddenFlagHidesEntriesWithoutADotName() async throws {
        let root = try makeDirectory()
        let flagged = root.appendingPathComponent("flagged.swift")
        try Data("source".utf8).write(to: flagged)
        var hiddenValues = URLResourceValues()
        hiddenValues.isHidden = true
        var flaggedURL = flagged
        try flaggedURL.setResourceValues(hiddenValues)
        try Data("source".utf8).write(to: root.appendingPathComponent("visible.swift"))

        let metadata = try XCTUnwrap(LocalPathMetadataProvider().metadata(for: flagged))
        XCTAssertTrue(metadata.isHidden, "UF_HIDDEN must still count as hidden")

        let scanner = WorkspaceScanner()
        let visible = try await paths(of: scanner.scan(root: root))
        XCTAssertEqual(visible, ["visible.swift"])

        var revealed: [String: WorkspaceFileEntry] = [:]
        for try await batch in scanner.scan(
            root: root,
            options: WorkspaceDiscoveryOptions(includeHidden: true)
        ) {
            for entry in batch.entries {
                revealed[entry.relativePath] = entry
            }
        }
        XCTAssertEqual(revealed["flagged.swift"]?.isHidden, true)
        XCTAssertEqual(revealed["visible.swift"]?.isHidden, false)
    }

    // MARK: - Mutation between listing and classification

    func testDirectoryReplacedBySymlinkAfterListingIsNeverFollowedOutsideRoot() async throws {
        let root = try makeDirectory()
        let outside = try makeDirectory()
        try Data("escaped".utf8).write(to: outside.appendingPathComponent("escaped.txt"))
        let inside = root.appendingPathComponent("inside", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: inside.appendingPathComponent("nested.swift"))
        try Data("root".utf8).write(to: root.appendingPathComponent("root.swift"))

        let opened = PathRecorder()
        let scanner = WorkspaceScanner(
            directoryEnumerator: MutatingDirectoryEnumerator(
                trigger: root,
                opened: opened,
                mutation: {
                    try? FileManager.default.removeItem(at: inside)
                    try? FileManager.default.createSymbolicLink(
                        at: inside,
                        withDestinationURL: outside
                    )
                }
            )
        )

        var entries: [WorkspaceFileEntry] = []
        for try await batch in scanner.scan(root: root) {
            entries.append(contentsOf: batch.entries)
        }

        XCTAssertEqual(
            entries.first { $0.relativePath == "inside" }?.kind,
            .symbolicLink,
            "the entry must describe the path as it is at classification time"
        )
        XCTAssertEqual(
            entries.map(\.relativePath).sorted(),
            ["inside", "root.swift"]
        )
        assertConfined(entries, to: root)
        XCTAssertEqual(opened.paths(), [root.path], "the swapped link was never opened")
    }

    func testDirectoryReplacedByFileAfterListingIsClassifiedAsFileWithoutChildren() async throws {
        let root = try makeDirectory()
        let inside = root.appendingPathComponent("inside", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: inside.appendingPathComponent("nested.swift"))

        let opened = PathRecorder()
        let scanner = WorkspaceScanner(
            directoryEnumerator: MutatingDirectoryEnumerator(
                trigger: root,
                opened: opened,
                mutation: {
                    try? FileManager.default.removeItem(at: inside)
                    try? Data("now a file".utf8).write(
                        to: URL(fileURLWithPath: inside.path, isDirectory: false)
                    )
                }
            )
        )

        var entries: [WorkspaceFileEntry] = []
        for try await batch in scanner.scan(root: root) {
            entries.append(contentsOf: batch.entries)
        }

        XCTAssertEqual(entries.map(\.relativePath), ["inside"])
        XCTAssertEqual(entries.first?.kind, .file)
        XCTAssertEqual(opened.paths(), [root.path])
    }

    func testEntryRemovedAfterListingIsDroppedInsteadOfEmittedOrFailing() async throws {
        let root = try makeDirectory()
        let ghost = root.appendingPathComponent("ghost.swift")
        try Data("ghost".utf8).write(to: ghost)
        try Data("kept".utf8).write(to: root.appendingPathComponent("kept.swift"))

        let scanner = WorkspaceScanner(
            directoryEnumerator: MutatingDirectoryEnumerator(
                trigger: root,
                opened: PathRecorder(),
                mutation: { try? FileManager.default.removeItem(at: ghost) }
            )
        )

        let discovered = try await paths(of: scanner.scan(root: root))
        XCTAssertEqual(discovered, ["kept.swift"])
    }

    // MARK: - Mutation between classification and recursion

    func testStaleDirectoryClassificationCannotRecurseThroughASwappedSymlink() async throws {
        let root = try makeDirectory()
        let outside = try makeDirectory()
        try Data("escaped".utf8).write(to: outside.appendingPathComponent("escaped.txt"))
        try FileManager.default.createDirectory(
            at: outside.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        let inside = root.appendingPathComponent("inside", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: inside, withDestinationURL: outside)

        // Models exactly what a listing-time prefetch would have cached: the
        // first lookup still calls `inside` a directory, so it is queued for
        // recursion. Only the fresh lookup taken before the directory is
        // opened can stop the scan from walking into `outside`.
        let opened = PathRecorder()
        let scanner = WorkspaceScanner(
            directoryEnumerator: MutatingDirectoryEnumerator(
                trigger: nil,
                opened: opened,
                mutation: {}
            ),
            metadataProvider: StaleOnFirstLookupMetadataProvider(
                stalePath: inside.path,
                stale: WorkspacePathMetadata(
                    isDirectory: true,
                    isSymbolicLink: false,
                    isHidden: false
                )
            )
        )

        var entries: [WorkspaceFileEntry] = []
        for try await batch in scanner.scan(root: root) {
            entries.append(contentsOf: batch.entries)
        }

        XCTAssertEqual(entries.map(\.relativePath), ["inside"])
        XCTAssertFalse(
            entries.contains { $0.relativePath.hasPrefix("inside/") },
            "no child of the swapped link may be discovered"
        )
        assertConfined(entries, to: root)
        XCTAssertEqual(
            opened.paths(),
            [root.path],
            "the stale directory must never be opened after the fresh re-check"
        )
    }

    func testSymlinkCycleClassifiedAsADirectoryTerminatesWithoutRepeatingEntries() async throws {
        let root = try makeDirectory()
        try Data("root".utf8).write(to: root.appendingPathComponent("root.swift"))
        let loop = root.appendingPathComponent("loop", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: loop, withDestinationURL: root)

        let opened = PathRecorder()
        let scanner = WorkspaceScanner(
            directoryEnumerator: MutatingDirectoryEnumerator(
                trigger: nil,
                opened: opened,
                mutation: {}
            ),
            metadataProvider: StaleOnFirstLookupMetadataProvider(
                stalePath: loop.path,
                stale: WorkspacePathMetadata(
                    isDirectory: true,
                    isSymbolicLink: false,
                    isHidden: false
                )
            )
        )

        let discovered = try await paths(of: scanner.scan(root: root))

        XCTAssertEqual(discovered, ["loop", "root.swift"])
        XCTAssertEqual(discovered.count, Set(discovered).count, "a cycle would repeat entries")
        XCTAssertEqual(opened.paths(), [root.path])
    }

    func testDirectoryExpansionRejectsSymlinkedAncestorsAndSwappedDirectories() async throws {
        let root = try makeDirectory()
        let outside = try makeDirectory()
        try FileManager.default.createDirectory(
            at: outside.appendingPathComponent("sub", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("escaped".utf8).write(
            to: outside.appendingPathComponent("sub/escaped.txt")
        )
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let scanner = WorkspaceScanner()
        do {
            _ = try await paths(of: scanner.scanDirectory(root: root, relativePath: "link/sub"))
            XCTFail("expanding through a symbolic-link ancestor must fail")
        } catch {
            XCTAssertEqual(
                error as? WorkspaceScannerError,
                .invalidRelativeDirectory("link/sub")
            )
        }

        // The directory exists when the expansion is requested and is a
        // symbolic link by the time it would be opened.
        let expanded = root.appendingPathComponent("expanded", isDirectory: true)
        try FileManager.default.createDirectory(at: expanded, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: expanded.appendingPathComponent("nested.swift"))
        try FileManager.default.removeItem(at: expanded)
        try FileManager.default.createSymbolicLink(at: expanded, withDestinationURL: outside)

        let listed = try await paths(
            of: scanner.scanDirectory(root: root, relativePath: "expanded")
        )
        XCTAssertEqual(
            listed,
            [],
            "a directory that became a symbolic link lists nothing"
        )
    }

    // MARK: - Helpers

    private func makeDirectory() throws -> URL {
        // `realpath` rather than `resolvingSymlinksInPath()`, which strips a
        // leading `/private` and leaves the fixture under the `/var` symlink.
        // A symlinked ancestor makes Foundation rebuild every listed URL and
        // silently drops the resource-value cache these regressions pin down.
        let temporary = FileManager.default.temporaryDirectory.path
        guard let resolved = realpath(temporary, nil) else {
            throw WorkspaceAccessFailure.unavailable
        }
        defer { free(resolved) }
        let url = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func paths(
        of stream: AsyncThrowingStream<WorkspaceDiscoveryBatch, Error>
    ) async throws -> [String] {
        var paths: [String] = []
        for try await batch in stream {
            paths.append(contentsOf: batch.entries.map(\.relativePath))
        }
        return paths
    }

    private func assertConfined(
        _ entries: [WorkspaceFileEntry],
        to root: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let prefixes = Set([
            root.path,
            root.path.hasPrefix("/private/") ? String(root.path.dropFirst(8)) : root.path
        ]).map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        for entry in entries {
            XCTAssertTrue(
                prefixes.contains { entry.url.path.hasPrefix($0) },
                "\(entry.url.path) escaped \(root.path)",
                file: file,
                line: line
            )
            XCTAssertFalse(
                entry.relativePath.contains("escaped"),
                "discovered an entry from outside the root: \(entry.relativePath)",
                file: file,
                line: line
            )
        }
    }
}

/// Records every directory the scanner actually listed and applies a
/// filesystem mutation right after the triggering directory is listed,
/// reproducing a swap that lands between enumeration and metadata lookup.
/// Every descriptor operation is forwarded to the real local capability, so
/// these regressions run against the confined traversal rather than around
/// it.
private struct MutatingDirectoryEnumerator: DirectoryEnumerator {
    let trigger: URL?
    let opened: PathRecorder
    let mutation: @Sendable () -> Void

    func children(of directory: URL) throws -> [URL] {
        try LocalDirectoryEnumerator().children(of: directory)
    }

    func openRoot(_ root: URL) throws -> WorkspaceDirectoryOpening {
        try LocalDirectoryEnumerator().openRoot(root)
    }

    func openChild(
        _ name: String,
        of parent: WorkspaceDirectoryHandle,
        url: URL,
        relativePath: String
    ) throws -> WorkspaceDirectoryOpening {
        try LocalDirectoryEnumerator().openChild(
            name,
            of: parent,
            url: url,
            relativePath: relativePath
        )
    }

    func children(in directory: WorkspaceDirectoryHandle) throws -> [WorkspaceDirectoryChild] {
        opened.record(directory.url.path)
        let children = try LocalDirectoryEnumerator().children(in: directory)
        // Populate Foundation's per-URL resource-value cache the way the
        // prefetching enumeration used to, so anything that still trusts
        // that cache observes the pre-mutation type.
        for child in children {
            _ = try? child.url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .isHiddenKey
            ])
        }
        if directory.url.path == trigger?.path {
            mutation()
        }
        return children
    }
}

/// Serves one deliberately stale answer for a single path, the way a
/// listing-time resource-value prefetch used to, and the live filesystem
/// state for every lookup after that.
private struct StaleOnFirstLookupMetadataProvider: PathMetadataProvider {
    let stalePath: String
    let stale: WorkspacePathMetadata
    private let served = PathRecorder()

    init(stalePath: String, stale: WorkspacePathMetadata) {
        self.stalePath = stalePath
        self.stale = stale
    }

    func metadata(for path: URL) throws -> WorkspacePathMetadata? {
        if path.path == stalePath, served.recordFirst(stalePath) {
            return stale
        }
        return try LocalPathMetadataProvider().metadata(for: path)
    }
}

private final class PathRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func record(_ path: String) {
        lock.lock()
        recorded.append(path)
        lock.unlock()
    }

    /// Returns `true` the first time a path is seen.
    func recordFirst(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let isFirst = !recorded.contains(path)
        recorded.append(path)
        return isFirst
    }

    func paths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
