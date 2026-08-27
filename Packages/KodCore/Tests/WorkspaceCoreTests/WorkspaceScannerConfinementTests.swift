import Foundation
import WorkspaceCore
import XCTest

/// Regressions for ancestor confinement. Checking the last component of a
/// path -- with `lstat`, or with `O_NOFOLLOW` on the open itself -- says
/// nothing about the directories above it: the kernel resolves those by
/// path on every call, so an ancestor replaced by a symbolic link between
/// two calls redirects the next one outside the workspace root. Every case
/// below wins exactly that window, deterministically.
final class WorkspaceScannerConfinementTests: XCTestCase {
    // MARK: - Ancestor replaced mid-scan

    func testAncestorReplacedAfterListingCannotRedirectRecursionOutsideRoot() async throws {
        let root = try makeDirectory()
        let outside = try makeDirectory()
        let outer = root.appendingPathComponent("outer", isDirectory: true)
        let inner = outer.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: inner.appendingPathComponent("kept.swift"))
        // The replacement destination mirrors the shape of the subtree that
        // is about to be entered, so a scan that resolves `outer` by path
        // finds a real directory where it expected one and walks straight
        // into it.
        try FileManager.default.createDirectory(
            at: outside.appendingPathComponent("inner", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("escaped".utf8).write(
            to: outside.appendingPathComponent("inner/escaped-nested.txt")
        )

        let scanner = WorkspaceScanner(
            metadataProvider: AncestorSwappingMetadataProvider(
                // `outer/inner` is looked up first when its parent is
                // listed and classified; the swap lands immediately after
                // that answer, before anything opens the directory.
                triggerPath: inner.path,
                mutation: { replace(outer, withSymbolicLinkTo: outside) }
            )
        )

        let discovered = try await paths(of: scanner.scan(root: root))

        assertNothingEscaped(discovered)
        XCTAssertEqual(
            discovered,
            ["outer", "outer/inner"],
            "the subtree under the replaced ancestor is dropped, not followed"
        )
    }

    func testAncestorReplacedDuringExpansionFailsInsteadOfListingOutsideRoot() async throws {
        let root = try makeDirectory()
        let outside = try makeDirectory()
        let outer = root.appendingPathComponent("outer", isDirectory: true)
        let inner = outer.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: inner.appendingPathComponent("kept.swift"))
        try FileManager.default.createDirectory(
            at: outside.appendingPathComponent("inner", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("escaped".utf8).write(
            to: outside.appendingPathComponent("inner/escaped-nested.txt")
        )

        let scanner = WorkspaceScanner(
            metadataProvider: AncestorSwappingMetadataProvider(
                // The expansion checks `outer` before it descends; the swap
                // lands between that check and the descent.
                triggerPath: outer.path,
                mutation: { replace(outer, withSymbolicLinkTo: outside) }
            )
        )

        var discovered: [String] = []
        do {
            discovered = try await paths(
                of: scanner.scanDirectory(root: root, relativePath: "outer/inner")
            )
            XCTFail("expanding through a replaced ancestor must fail")
        } catch {
            XCTAssertEqual(
                error as? WorkspaceScannerError,
                .invalidRelativeDirectory("outer/inner")
            )
        }
        assertNothingEscaped(discovered)
    }

    func testClassificationThroughAReplacedAncestorReportsAbsenceNotOutsideMetadata() throws {
        let root = try makeDirectory()
        let outside = try makeDirectory()
        let outer = root.appendingPathComponent("outer", isDirectory: true)
        let inner = outer.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: outside.appendingPathComponent("inner", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("escaped".utf8).write(
            to: outside.appendingPathComponent("inner/kept.swift")
        )
        replace(outer, withSymbolicLinkTo: outside)

        // The path still spells a location inside the workspace, and every
        // component but the first is a real directory or file. Only a
        // lookup anchored at the root can tell that it now leads out.
        let classified = try WorkspaceScanner().classify(
            path: inner.appendingPathComponent("kept.swift"),
            root: root
        )

        XCTAssertEqual(classified, .absent)
    }

    func testSiblingsKeepListingTheDirectoryTheyWereFoundInAfterItIsReplaced() async throws {
        let root = try makeDirectory()
        let outside = try makeDirectory()
        let outer = root.appendingPathComponent("outer", isDirectory: true)
        for name in ["alpha", "beta"] {
            try FileManager.default.createDirectory(
                at: outer.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
            try Data("kept".utf8).write(
                to: outer.appendingPathComponent("\(name)/\(name).swift")
            )
            try FileManager.default.createDirectory(
                at: outside.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
            try Data("escaped".utf8).write(
                to: outside.appendingPathComponent("\(name)/escaped.txt")
            )
        }

        let scanner = WorkspaceScanner(
            directoryEnumerator: ListingMutationEnumerator(
                // `outer` is replaced once its first child has been listed,
                // so the second child is reached while the path that found
                // it already leads somewhere else. The original directory
                // is moved aside rather than deleted, so a scan that
                // resolved `outer` by name again would list `outside`.
                trigger: "outer/alpha",
                mutation: {
                    try? FileManager.default.moveItem(
                        at: outer,
                        to: root.appendingPathComponent("moved", isDirectory: true)
                    )
                    try? FileManager.default.createSymbolicLink(
                        at: outer,
                        withDestinationURL: outside
                    )
                }
            )
        )

        let discovered = try await paths(of: scanner.scan(root: root))

        assertNothingEscaped(discovered)
        XCTAssertEqual(
            discovered,
            [
                "outer",
                "outer/alpha",
                "outer/beta",
                "outer/alpha/alpha.swift",
                "outer/beta/beta.swift"
            ],
            "siblings are opened from the directory that listed them, not from its name"
        )
    }

    // MARK: - Descriptor lifetime

    func testDirectoryHandlesAreClosedAndBoundedRegardlessOfWidthOrDepth() async throws {
        let wide = try makeDirectory()
        for index in 0..<200 {
            let directory = wide.appendingPathComponent("dir-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("source".utf8).write(to: directory.appendingPathComponent("file.swift"))
        }

        let wideLedger = DirectoryHandleLedger()
        let wideDiscovered = try await paths(
            of: WorkspaceScanner(directoryEnumerator: wideLedger).scan(root: wide)
        )

        XCTAssertEqual(wideDiscovered.count, 400)
        XCTAssertEqual(
            wideLedger.openedCount(),
            wideLedger.closedCount(),
            "every directory the scan opened must be closed again"
        )
        XCTAssertLessThanOrEqual(
            wideLedger.peakConcurrentCount(),
            4,
            "a wide tree must not cost a descriptor per queued directory"
        )

        // Deeper than the chain the scan is willing to keep open, so the
        // walk has to re-open the tail for each directory below the cap.
        let deep = try makeDirectory()
        var directory = deep
        for depth in 0..<40 {
            directory = directory.appendingPathComponent("level-\(depth)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("source".utf8).write(to: directory.appendingPathComponent("file.swift"))
        }

        let deepLedger = DirectoryHandleLedger()
        let deepDiscovered = try await paths(
            of: WorkspaceScanner(directoryEnumerator: deepLedger).scan(root: deep)
        )

        XCTAssertEqual(deepDiscovered.count, 80)
        XCTAssertGreaterThan(deepLedger.openedCount(), 40)
        XCTAssertEqual(
            deepLedger.openedCount(),
            deepLedger.closedCount(),
            "every directory the scan opened must be closed again"
        )
        XCTAssertLessThanOrEqual(
            deepLedger.peakConcurrentCount(),
            35,
            "the open chain is capped, so depth cannot exhaust the descriptor table"
        )
    }

    func testDescriptorsAreReleasedAcrossRepeatedScansExpansionsAndFailures() async throws {
        let root = try makeDirectory()
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        let nested = sources.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: nested.appendingPathComponent("main.swift"))
        try Data("rules".utf8).write(to: root.appendingPathComponent(".gitignore"))
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: try makeDirectory()
        )

        let scanner = WorkspaceScanner()
        try await exercise(scanner, root: root, missing: missing)
        let baseline = openDescriptorCount()

        for _ in 0..<10 {
            try await exercise(scanner, root: root, missing: missing)
        }

        XCTAssertEqual(
            openDescriptorCount(),
            baseline,
            "scans, expansions, failures and cancellation must all release their descriptors"
        )
    }

    /// One round of everything that opens a descriptor: a full scan, an
    /// expansion, a cancelled scan, two failing paths and a classification.
    private func exercise(
        _ scanner: WorkspaceScanner,
        root: URL,
        missing: URL
    ) async throws {
        _ = try await paths(of: scanner.scan(root: root))
        _ = try await paths(of: scanner.scanDirectory(root: root, relativePath: "Sources"))
        for try await _ in scanner.scan(
            root: root,
            options: WorkspaceDiscoveryOptions(batchSize: 1)
        ) {
            break
        }
        _ = try? await paths(of: scanner.scan(root: missing))
        _ = try? await paths(
            of: scanner.scanDirectory(root: root, relativePath: "link/inside")
        )
        _ = try scanner.classify(
            path: root.appendingPathComponent("Sources/Nested/main.swift"),
            root: root
        )
    }

    /// Counts the descriptors this process holds without opening one.
    private func openDescriptorCount() -> Int {
        var count = 0
        for descriptor in 0..<Int32(min(getdtablesize(), 4_096))
        where fcntl(descriptor, F_GETFD) != -1 {
            count += 1
        }
        return count
    }

    // MARK: - Helpers

    private func makeDirectory() throws -> URL {
        // `realpath` rather than `resolvingSymlinksInPath()`, which leaves
        // the fixture under the `/var` symlink and makes every path in
        // these assertions ambiguous.
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

    private func assertNothingEscaped(
        _ paths: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for path in paths {
            XCTAssertFalse(
                path.contains("escaped"),
                "discovered \(path) from outside the workspace root",
                file: file,
                line: line
            )
        }
    }
}

/// Replaces a directory with a symbolic link to somewhere else, the way a
/// concurrent writer would.
private func replace(_ directory: URL, withSymbolicLinkTo destination: URL) {
    try? FileManager.default.removeItem(at: directory)
    try? FileManager.default.createSymbolicLink(at: directory, withDestinationURL: destination)
}

/// Answers every lookup from the live filesystem and, the first time one
/// named path is looked up, replaces an ancestor directory immediately
/// afterwards. The answer the scan acts on is therefore true when it is
/// given and stale by the time the scan uses it -- the exact window an
/// attacker needs.
private struct AncestorSwappingMetadataProvider: PathMetadataProvider {
    let triggerPath: String
    let mutation: @Sendable () -> Void
    private let hasFired = SingleShot()

    init(triggerPath: String, mutation: @escaping @Sendable () -> Void) {
        self.triggerPath = triggerPath
        self.mutation = mutation
    }

    func metadata(for path: URL) throws -> WorkspacePathMetadata? {
        let metadata = try LocalPathMetadataProvider().metadata(for: path)
        if path.path == triggerPath, hasFired.fire() {
            mutation()
        }
        return metadata
    }
}

private final class SingleShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    /// Returns `true` exactly once.
    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else {
            return false
        }
        fired = true
        return true
    }
}

/// Lists through the real local capability and mutates the filesystem once,
/// immediately after one named directory has been listed.
private struct ListingMutationEnumerator: DirectoryEnumerator {
    let trigger: String
    let mutation: @Sendable () -> Void
    private let hasFired = SingleShot()

    init(trigger: String, mutation: @escaping @Sendable () -> Void) {
        self.trigger = trigger
        self.mutation = mutation
    }

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
        let children = try LocalDirectoryEnumerator().children(in: directory)
        if directory.relativePath == trigger, hasFired.fire() {
            mutation()
        }
        return children
    }
}

/// Forwards to the real local capability and books every directory the scan
/// opens and closes, so a descriptor kept past its directory -- or one held
/// per queued directory -- is visible without inspecting the process.
private final class DirectoryHandleLedger: DirectoryEnumerator, @unchecked Sendable {
    private let lock = NSLock()
    private var opened = 0
    private var closed = 0
    private var peak = 0

    func children(of directory: URL) throws -> [URL] {
        try LocalDirectoryEnumerator().children(of: directory)
    }

    func openRoot(_ root: URL) throws -> WorkspaceDirectoryOpening {
        record(try LocalDirectoryEnumerator().openRoot(root))
    }

    func openChild(
        _ name: String,
        of parent: WorkspaceDirectoryHandle,
        url: URL,
        relativePath: String
    ) throws -> WorkspaceDirectoryOpening {
        record(
            try LocalDirectoryEnumerator().openChild(
                name,
                of: parent,
                url: url,
                relativePath: relativePath
            )
        )
    }

    func closeDirectory(_ directory: WorkspaceDirectoryHandle) {
        guard !directory.isVirtual else {
            return
        }
        lock.lock()
        closed += 1
        lock.unlock()
        close(directory.descriptor)
    }

    func children(in directory: WorkspaceDirectoryHandle) throws -> [WorkspaceDirectoryChild] {
        try LocalDirectoryEnumerator().children(in: directory)
    }

    func openedCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return opened
    }

    func closedCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func peakConcurrentCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }

    private func record(_ opening: WorkspaceDirectoryOpening) -> WorkspaceDirectoryOpening {
        guard case .opened(let handle) = opening, !handle.isVirtual else {
            return opening
        }
        lock.lock()
        opened += 1
        peak = max(peak, opened - closed)
        lock.unlock()
        return opening
    }
}
