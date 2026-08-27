import Foundation

public enum WorkspaceFileKind: Equatable, Sendable {
    case file
    case directory
    case symbolicLink
}

public struct WorkspaceFileEntry: Equatable, Sendable {
    public let url: URL
    public let relativePath: String
    public let kind: WorkspaceFileKind
    public let isHidden: Bool
    public let isIgnored: Bool

    public init(
        url: URL,
        relativePath: String,
        kind: WorkspaceFileKind,
        isHidden: Bool,
        isIgnored: Bool
    ) {
        self.url = url
        self.relativePath = relativePath
        self.kind = kind
        self.isHidden = isHidden
        self.isIgnored = isIgnored
    }
}

public struct WorkspaceDiscoveryBatch: Sendable {
    public let entries: [WorkspaceFileEntry]
    public let discoveredCount: Int

    public init(entries: [WorkspaceFileEntry], discoveredCount: Int) {
        self.entries = entries
        self.discoveredCount = discoveredCount
    }
}

public struct WorkspaceDiscoveryOptions: Equatable, Sendable {
    public let includeHidden: Bool
    public let includeIgnored: Bool
    public let batchSize: Int

    public init(
        includeHidden: Bool = false,
        includeIgnored: Bool = false,
        batchSize: Int = 256
    ) {
        self.includeHidden = includeHidden
        self.includeIgnored = includeIgnored
        self.batchSize = max(1, batchSize)
    }
}

/// The state of one path itself, never of a symbolic link's destination.
/// Every value is read at lookup time; nothing here may be cached across a
/// directory listing, because a path's type can change in between.
public struct WorkspacePathMetadata: Equatable, Sendable {
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let isHidden: Bool

    public init(isDirectory: Bool, isSymbolicLink: Bool, isHidden: Bool) {
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.isHidden = isHidden
    }
}

public enum WorkspaceAccessFailure: Error, Equatable, Sendable {
    case permissionDenied
    case unavailable
}

private enum WorkspacePathComponentValidator {
    static func isValid(_ component: String) -> Bool {
        !component.isEmpty
            && component != "."
            && component != ".."
            && !component.contains("/")
            && !component.utf8.contains(0)
    }
}

/// One directory the scan has opened and is working inside.
///
/// A path is only confined to the workspace if every component of it is
/// resolved from a directory the scan already holds open: `openat` and
/// `fstatat` resolve a single name inside the directory the descriptor
/// refers to, so replacing an ancestor after it was opened cannot redirect
/// the lookup. Resolving the same name by path re-walks every ancestor and
/// would follow the replacement instead.
///
/// The scan owns `descriptor` and closes it as soon as the directory is
/// finished. A capability must not retain or use it after the call it was
/// handed to returns.
public struct WorkspaceDirectoryHandle: Sendable {
    /// Stands in for a descriptor when a capability models a workspace that
    /// is not on disk and has nothing to open.
    public static let virtualDescriptor: Int32 = -1

    /// Where the directory sits in the workspace. It names the directory
    /// for reporting and for capabilities backed by something other than a
    /// filesystem; the scan never resolves it to reach the directory.
    public let url: URL
    /// Workspace-relative path of the directory, empty for the root itself.
    public let relativePath: String
    /// An open descriptor for the directory, or ``virtualDescriptor``.
    public let descriptor: Int32

    public init(
        url: URL,
        relativePath: String,
        descriptor: Int32 = WorkspaceDirectoryHandle.virtualDescriptor
    ) {
        self.url = url
        self.relativePath = relativePath
        self.descriptor = descriptor
    }

    /// Whether the handle has no descriptor behind it.
    public var isVirtual: Bool {
        descriptor < 0
    }
}

/// One listed child, named by the single path component that reaches it
/// from its already-open parent. The URL is for reporting only.
public struct WorkspaceDirectoryChild: Equatable, Sendable {
    public let name: String
    public let url: URL

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }
}

public enum WorkspaceDirectoryOpening: Sendable {
    case opened(WorkspaceDirectoryHandle)
    /// The name is absent, is not a directory, or is a symbolic link, so
    /// the scan must not enter it. This is never an error: it is the
    /// ordinary answer for a path that changed under the scan.
    case notTraversable
}

public protocol DirectoryEnumerator: Sendable {
    /// Lists a directory by path. The scan itself never does this -- the
    /// kernel would resolve the ancestors again -- but capabilities that
    /// model a workspace in memory are defined in these terms.
    func children(of directory: URL) throws -> [URL]

    /// Opens the workspace root, the anchor every later lookup is made
    /// relative to. Answers `notTraversable` when the root is absent or is
    /// not a directory; only genuine access failures throw.
    func openRoot(_ root: URL) throws -> WorkspaceDirectoryOpening

    /// Opens the child called `name` of an already-open directory, without
    /// following a symbolic link and without resolving any ancestor by
    /// path. Ownership of the descriptor passes to the scan.
    func openChild(
        _ name: String,
        of parent: WorkspaceDirectoryHandle,
        url: URL,
        relativePath: String
    ) throws -> WorkspaceDirectoryOpening

    /// Releases a directory returned by ``openRoot(_:)`` or
    /// ``openChild(_:of:url:relativePath:)``.
    func closeDirectory(_ directory: WorkspaceDirectoryHandle)

    /// Lists the immediate children of an already-open directory.
    func children(in directory: WorkspaceDirectoryHandle) throws -> [WorkspaceDirectoryChild]
}

extension DirectoryEnumerator {
    /// A capability with no filesystem behind it has nothing to open, so
    /// the scan works from the directory's URL alone. Such a capability
    /// cannot confine anything itself; the scan re-reads each directory's
    /// type before entering it, which is all a virtual tree can offer.
    public func openRoot(_ root: URL) throws -> WorkspaceDirectoryOpening {
        .opened(WorkspaceDirectoryHandle(url: root, relativePath: ""))
    }

    public func openChild(
        _ name: String,
        of parent: WorkspaceDirectoryHandle,
        url: URL,
        relativePath: String
    ) throws -> WorkspaceDirectoryOpening {
        .opened(WorkspaceDirectoryHandle(url: url, relativePath: relativePath))
    }

    public func closeDirectory(_ directory: WorkspaceDirectoryHandle) {
        guard !directory.isVirtual else {
            return
        }
        close(directory.descriptor)
    }

    public func children(in directory: WorkspaceDirectoryHandle) throws -> [WorkspaceDirectoryChild] {
        try children(of: directory.url).map {
            WorkspaceDirectoryChild(name: $0.lastPathComponent, url: $0)
        }
    }
}

public protocol PathMetadataProvider: Sendable {
    /// Returns `nil` only when the path is absent. Implementations must
    /// answer from the filesystem at call time and must not follow symbolic
    /// links, so callers can rely on the answer describing the path as it is
    /// immediately before they act on it.
    func metadata(for path: URL) throws -> WorkspacePathMetadata?

    /// Reads the type of one child of an already-open directory. `url`
    /// names the same child for reporting and for capabilities with no
    /// filesystem behind them.
    func metadata(
        ofChild name: String,
        in directory: WorkspaceDirectoryHandle,
        url: URL
    ) throws -> WorkspacePathMetadata?
}

extension PathMetadataProvider {
    public func metadata(
        ofChild name: String,
        in directory: WorkspaceDirectoryHandle,
        url: URL
    ) throws -> WorkspacePathMetadata? {
        try metadata(for: url)
    }
}

public protocol IgnoreFileSource: Sendable {
    /// Returns `nil` only when the directory has no `.gitignore`.
    func ignoreFileContents(in directory: URL) throws -> String?

    /// Reads the `.gitignore` of an already-open directory.
    func ignoreFileContents(in directory: WorkspaceDirectoryHandle) throws -> String?
}

extension IgnoreFileSource {
    public func ignoreFileContents(in directory: WorkspaceDirectoryHandle) throws -> String? {
        try ignoreFileContents(in: directory.url)
    }
}

public struct LocalDirectoryEnumerator: DirectoryEnumerator {
    public init() {}

    /// Lists a directory through a descriptor opened with
    /// `O_DIRECTORY | O_NOFOLLOW`, so a directory replaced by a symbolic
    /// link is rejected by the kernel instead of enumerated through the
    /// link. The ancestors are still resolved by path, which is why the
    /// scan lists through ``children(in:)`` instead.
    public func children(of directory: URL) throws -> [URL] {
        let directoryPath = directory.path
        let descriptor = directoryPath.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw posixAccessFailure(errno)
        }
        return try children(
            readingDescriptor: descriptor,
            prefix: pathPrefix(of: directoryPath)
        ).map(\.url)
    }

    /// Opens the root itself with `O_NOFOLLOW`: the workspace root is the
    /// only path the scan resolves by name, and a root that is a symbolic
    /// link is refused rather than followed.
    public func openRoot(_ root: URL) throws -> WorkspaceDirectoryOpening {
        let descriptor = root.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            return try opening(rejectedBy: errno)
        }
        return .opened(
            WorkspaceDirectoryHandle(url: root, relativePath: "", descriptor: descriptor)
        )
    }

    /// Opens one name inside an open directory. `O_NOFOLLOW` rejects a
    /// child that is a symbolic link and `O_DIRECTORY` one that is no
    /// longer a directory, both atomically with the open, so no window
    /// exists between deciding to enter a directory and entering it.
    public func openChild(
        _ name: String,
        of parent: WorkspaceDirectoryHandle,
        url: URL,
        relativePath: String
    ) throws -> WorkspaceDirectoryOpening {
        guard WorkspacePathComponentValidator.isValid(name) else {
            throw WorkspaceAccessFailure.unavailable
        }
        guard !parent.isVirtual else {
            return .opened(WorkspaceDirectoryHandle(url: url, relativePath: relativePath))
        }
        let descriptor = name.withCString {
            openat(parent.descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            return try opening(rejectedBy: errno)
        }
        return .opened(
            WorkspaceDirectoryHandle(
                url: url,
                relativePath: relativePath,
                descriptor: descriptor
            )
        )
    }

    public func children(in directory: WorkspaceDirectoryHandle) throws -> [WorkspaceDirectoryChild] {
        guard !directory.isVirtual else {
            return try children(of: directory.url).map {
                WorkspaceDirectoryChild(name: $0.lastPathComponent, url: $0)
            }
        }
        // `fdopendir` takes ownership of the descriptor it is given and the
        // scan keeps using the directory after the listing, so the stream
        // reads through a duplicate. Duplicating costs no path resolution
        // -- re-opening the directory by name would -- and the duplicate
        // shares its offset with the original, so the stream is rewound
        // before it is read.
        let listing = fcntl(directory.descriptor, F_DUPFD_CLOEXEC, 0)
        guard listing >= 0 else {
            throw posixAccessFailure(errno)
        }
        return try children(
            readingDescriptor: listing,
            prefix: pathPrefix(of: directory.url.path)
        )
    }

    /// Consumes `descriptor`: it is closed with the stream that wraps it,
    /// on every path out of this call.
    private func children(
        readingDescriptor descriptor: Int32,
        prefix: String
    ) throws -> [WorkspaceDirectoryChild] {
        guard let stream = fdopendir(descriptor) else {
            let failure = posixAccessFailure(errno)
            close(descriptor)
            throw failure
        }
        defer { closedir(stream) }
        rewinddir(stream)

        var children: [WorkspaceDirectoryChild] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                let failure = errno
                guard failure == 0 else {
                    throw posixAccessFailure(failure)
                }
                return children
            }
            let name = directoryEntryName(entry)
            guard name != ".", name != ".." else {
                continue
            }
            // The type is deliberately not taken from `d_type`: it is a
            // snapshot of the listing, and every caller re-reads the child.
            children.append(
                WorkspaceDirectoryChild(
                    name: name,
                    url: URL(fileURLWithPath: prefix + name, isDirectory: false)
                )
            )
        }
    }

    /// A name that is gone, is not a directory, or is a symbolic link is
    /// not an access failure: the scan simply may not enter it.
    private func opening(rejectedBy code: Int32) throws -> WorkspaceDirectoryOpening {
        switch code {
        case ENOENT, ENOTDIR, ELOOP, EMLINK:
            return .notTraversable
        default:
            throw posixAccessFailure(code)
        }
    }
}

public struct LocalPathMetadataProvider: PathMetadataProvider {
    public init() {}

    /// Answers from a fresh `lstat`, which neither consults Foundation's
    /// per-URL resource-value cache nor follows the final symbolic link, so
    /// a path whose type changed since it was listed is reported as it is
    /// now. Hidden matches Foundation: the `UF_HIDDEN` filesystem flag or a
    /// leading-dot name.
    public func metadata(for path: URL) throws -> WorkspacePathMetadata? {
        let filePath = path.path
        var status = stat()
        guard filePath.withCString({ lstat($0, &status) }) == 0 else {
            return try absentOrFailure(errno)
        }
        return metadata(of: status, name: lastComponent(ofPath: filePath))
    }

    /// Answers from `fstatat` on the open parent, so the type belongs to
    /// the child of *that* directory rather than to whatever the same path
    /// resolves to now.
    public func metadata(
        ofChild name: String,
        in directory: WorkspaceDirectoryHandle,
        url: URL
    ) throws -> WorkspacePathMetadata? {
        guard WorkspacePathComponentValidator.isValid(name) else {
            throw WorkspaceAccessFailure.unavailable
        }
        guard !directory.isVirtual else {
            return try metadata(for: url)
        }
        var status = stat()
        let read = name.withCString {
            fstatat(directory.descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard read == 0 else {
            return try absentOrFailure(errno)
        }
        return metadata(of: status, name: name[...])
    }

    private func absentOrFailure(_ code: Int32) throws -> WorkspacePathMetadata? {
        if code == ENOENT || code == ENOTDIR {
            return nil
        }
        throw posixAccessFailure(code)
    }

    private func metadata(of status: stat, name: Substring) -> WorkspacePathMetadata {
        let type = status.st_mode & S_IFMT
        return WorkspacePathMetadata(
            isDirectory: type == S_IFDIR,
            isSymbolicLink: type == S_IFLNK,
            isHidden: status.st_flags & UInt32(UF_HIDDEN) != 0 || name.hasPrefix(".")
        )
    }
}

public struct LocalIgnoreFileSource: IgnoreFileSource {
    public init() {}

    public func ignoreFileContents(in directory: URL) throws -> String? {
        let url = directory.appendingPathComponent(".gitignore", isDirectory: false)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            let cocoaError = error as NSError
            if cocoaError.code == NSFileNoSuchFileError
                || cocoaError.code == NSFileReadNoSuchFileError {
                return nil
            }
            throw workspaceAccessFailure(for: error)
        }
    }

    /// Reads the ignore file from the open directory it belongs to. The
    /// open refuses to follow a symbolic link -- which could name a file
    /// outside the workspace -- and refuses anything that is not a regular
    /// file, so a fifo left in the workspace cannot stall the scan.
    public func ignoreFileContents(in directory: WorkspaceDirectoryHandle) throws -> String? {
        guard !directory.isVirtual else {
            return try ignoreFileContents(in: directory.url)
        }
        let descriptor = openat(
            directory.descriptor,
            ".gitignore",
            O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            let failure = errno
            if failure == ENOENT || failure == ENOTDIR || failure == ELOOP {
                return nil
            }
            throw posixAccessFailure(failure)
        }
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw posixAccessFailure(errno)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            return nil
        }
        guard let contents = String(
            data: try readAll(descriptor, expecting: status.st_size),
            encoding: .utf8
        ) else {
            throw WorkspaceAccessFailure.unavailable
        }
        return contents
    }

    private func readAll(_ descriptor: Int32, expecting size: off_t) throws -> Data {
        var data = Data()
        data.reserveCapacity(max(0, Int(size)))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                guard let base = $0.baseAddress else {
                    return -1
                }
                return read(descriptor, base, $0.count)
            }
            if count < 0 {
                let failure = errno
                guard failure == EINTR else {
                    throw posixAccessFailure(failure)
                }
                continue
            }
            guard count > 0 else {
                return data
            }
            data.append(contentsOf: buffer[0..<count])
        }
    }
}

public enum WorkspacePathExclusion: Equatable, Sendable {
    case outsideRoot
    case workspaceRoot
    case gitMetadata
}

public enum WorkspaceClassificationOutcome: Equatable, Sendable {
    case entry(WorkspaceFileEntry)
    case absent
    case excluded(WorkspacePathExclusion)
}

public enum WorkspaceScannerError: Error, Equatable, Sendable {
    case directoryEnumerationFailed(URL, WorkspaceAccessFailure)
    case metadataFailed(URL, WorkspaceAccessFailure)
    case unreadableIgnoreFile(URL, WorkspaceAccessFailure)
    case invalidRelativeDirectory(String)
}

public struct WorkspaceScanner: Sendable {
    private struct QueuedDirectory {
        let url: URL
        let relativePath: String
        let inheritedRules: [IgnoreRule]
    }

    private struct DirectoryContents {
        let entries: [WorkspaceFileEntry]
        let childDirectories: [QueuedDirectory]
    }

    private let directoryEnumerator: any DirectoryEnumerator
    private let metadataProvider: any PathMetadataProvider
    private let ignoreFileSource: any IgnoreFileSource

    public init(
        directoryEnumerator: any DirectoryEnumerator = LocalDirectoryEnumerator(),
        metadataProvider: any PathMetadataProvider = LocalPathMetadataProvider(),
        ignoreFileSource: any IgnoreFileSource = LocalIgnoreFileSource()
    ) {
        self.directoryEnumerator = directoryEnumerator
        self.metadataProvider = metadataProvider
        self.ignoreFileSource = ignoreFileSource
    }

    /// Classifies one incremental path with the same metadata and ignore
    /// capabilities used by `scan(root:options:)`. Every component below the
    /// root is resolved from the root's own descriptor, so a path that
    /// still spells a location inside the workspace but now leads out of it
    /// through a replaced ancestor reads as absent rather than as an entry.
    public func classify(path: URL, root: URL) throws -> WorkspaceClassificationOutcome {
        let rootPath = root.standardizedFileURL.path
        let targetPath = path.standardizedFileURL.path
        if targetPath == rootPath {
            return .excluded(.workspaceRoot)
        }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard targetPath.hasPrefix(prefix) else {
            return .excluded(.outsideRoot)
        }
        let relativePath = String(targetPath.dropFirst(prefix.count))
        let components = relativePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard components.allSatisfy(
            WorkspacePathComponentValidator.isValid
        ) else {
            throw WorkspaceScannerError.invalidRelativeDirectory(relativePath)
        }
        guard relativePath != ".git", !relativePath.hasPrefix(".git/") else {
            return .excluded(.gitMetadata)
        }

        guard let rootHandle = try openRoot(root) else {
            return .absent
        }
        defer { directoryEnumerator.closeDirectory(rootHandle) }
        return try classify(
            path: path,
            relativePath: relativePath,
            components: components[...],
            in: rootHandle,
            rules: []
        )
    }

    /// Walks the components below `parent` one at a time, collecting the
    /// ignore rules of each directory it passes through, and classifies the
    /// last component from the directory that directly contains it.
    private func classify(
        path: URL,
        relativePath: String,
        components: ArraySlice<String>,
        in parent: WorkspaceDirectoryHandle,
        rules: [IgnoreRule]
    ) throws -> WorkspaceClassificationOutcome {
        guard let name = components.first else {
            return .absent
        }
        let rules = rules + (try ignoreRules(in: parent))

        guard components.count > 1 else {
            guard let metadata = try metadata(ofChild: name, in: parent, url: path) else {
                return .absent
            }
            return .entry(makeEntry(
                url: path,
                relativePath: relativePath,
                name: name,
                metadata: metadata,
                rules: rules
            ))
        }

        let childRelativePath = parent.relativePath.isEmpty
            ? name
            : "\(parent.relativePath)/\(name)"
        guard let child = try openChild(
            name,
            of: parent,
            url: parent.url.appendingPathComponent(name, isDirectory: true),
            relativePath: childRelativePath
        ) else {
            return .absent
        }
        defer { directoryEnumerator.closeDirectory(child) }
        return try classify(
            path: path,
            relativePath: relativePath,
            components: components.dropFirst(),
            in: child,
            rules: rules
        )
    }

    public func scan(
        root: URL,
        options: WorkspaceDiscoveryOptions = WorkspaceDiscoveryOptions()
    ) -> AsyncThrowingStream<WorkspaceDiscoveryBatch, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try scanSynchronously(
                        root: root,
                        options: options,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Lists only the immediate children of one workspace-relative directory.
    /// The Explorer uses this for root startup and directory expansion so it
    /// never enumerates a collapsed subtree.
    public func scanDirectory(
        root: URL,
        relativePath: String,
        options: WorkspaceDiscoveryOptions = WorkspaceDiscoveryOptions()
    ) -> AsyncThrowingStream<WorkspaceDiscoveryBatch, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try scanDirectorySynchronously(
                        root: root,
                        relativePath: relativePath,
                        options: options,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func scanSynchronously(
        root: URL,
        options: WorkspaceDiscoveryOptions,
        continuation: AsyncThrowingStream<WorkspaceDiscoveryBatch, Error>.Continuation
    ) throws {
        var pending: [WorkspaceFileEntry] = []
        pending.reserveCapacity(options.batchSize)
        var discoveredCount = 0

        func emit(_ entry: WorkspaceFileEntry) {
            pending.append(entry)
            discoveredCount += 1
            if pending.count >= options.batchSize {
                continuation.yield(
                    WorkspaceDiscoveryBatch(
                        entries: pending,
                        discoveredCount: discoveredCount
                    )
                )
                pending.removeAll(keepingCapacity: true)
            }
        }

        func flushPending() {
            guard !pending.isEmpty else {
                return
            }
            continuation.yield(
                WorkspaceDiscoveryBatch(
                    entries: pending,
                    discoveredCount: discoveredCount
                )
            )
            pending.removeAll(keepingCapacity: true)
        }

        var queue = [
            QueuedDirectory(
                url: root,
                relativePath: "",
                inheritedRules: []
            )
        ]
        var nextDirectoryIndex = 0
        var levelEndIndex = queue.endIndex

        guard let rootHandle = try openRoot(root) else {
            throw WorkspaceScannerError.directoryEnumerationFailed(root, .unavailable)
        }
        var anchor = RootAnchor(root: rootHandle)
        defer { close(&anchor) }

        while nextDirectoryIndex < queue.endIndex {
            try Task.checkCancellation()
            let directory = queue[nextDirectoryIndex]
            nextDirectoryIndex += 1
            let listing = try withDirectory(directory, anchor: &anchor) { handle in
                try contents(of: directory, handle: handle, options: options)
            }
            if let listing {
                listing.entries.forEach(emit)
                queue.append(contentsOf: listing.childDirectories)
            }

            if nextDirectoryIndex == levelEndIndex {
                flushPending()
                levelEndIndex = queue.endIndex
            }
        }
    }

    private func scanDirectorySynchronously(
        root: URL,
        relativePath: String,
        options: WorkspaceDiscoveryOptions,
        continuation: AsyncThrowingStream<WorkspaceDiscoveryBatch, Error>.Continuation
    ) throws {
        let entries = try withRequestedDirectory(
            root: root,
            relativePath: relativePath
        ) { handle, inheritedRules in
            try contents(
                of: QueuedDirectory(
                    url: handle.url,
                    relativePath: handle.relativePath,
                    inheritedRules: inheritedRules
                ),
                handle: handle,
                options: options
            ).entries
        } ?? []
        var discoveredCount = 0

        for startIndex in stride(
            from: 0,
            to: entries.count,
            by: options.batchSize
        ) {
            try Task.checkCancellation()
            let endIndex = min(startIndex + options.batchSize, entries.count)
            let batchEntries = Array(entries[startIndex..<endIndex])
            discoveredCount += batchEntries.count
            continuation.yield(
                WorkspaceDiscoveryBatch(
                    entries: batchEntries,
                    discoveredCount: discoveredCount
                )
            )
        }
    }

    /// Opens one workspace-relative directory for expansion, component by
    /// component, from the root's own descriptor. Returns `nil` when the
    /// requested directory itself is no longer a directory the scan may
    /// enter; a *containing* directory that has been replaced makes the
    /// request invalid instead, because the caller asked for a path that no
    /// longer describes anything inside the workspace.
    private func withRequestedDirectory<T>(
        root: URL,
        relativePath: String,
        _ body: (WorkspaceDirectoryHandle, [IgnoreRule]) throws -> T
    ) throws -> T? {
        guard let rootHandle = try openRoot(root) else {
            throw WorkspaceScannerError.directoryEnumerationFailed(root, .unavailable)
        }
        defer { directoryEnumerator.closeDirectory(rootHandle) }
        guard !relativePath.isEmpty else {
            return try body(rootHandle, [])
        }
        guard !relativePath.hasPrefix("/") else {
            throw WorkspaceScannerError.invalidRelativeDirectory(relativePath)
        }
        return try withRequestedDirectory(
            requested: relativePath,
            components: relativePath
                .split(separator: "/", omittingEmptySubsequences: false)
                .map(String.init)[...],
            in: rootHandle,
            inheritedRules: [],
            body
        )
    }

    private func withRequestedDirectory<T>(
        requested: String,
        components: ArraySlice<String>,
        in parent: WorkspaceDirectoryHandle,
        inheritedRules: [IgnoreRule],
        _ body: (WorkspaceDirectoryHandle, [IgnoreRule]) throws -> T
    ) throws -> T? {
        guard let name = components.first else {
            return try body(parent, inheritedRules)
        }
        guard WorkspacePathComponentValidator.isValid(name) else {
            throw WorkspaceScannerError.invalidRelativeDirectory(requested)
        }
        let inheritedRules = inheritedRules + (try ignoreRules(in: parent))
        let relativePath = parent.relativePath.isEmpty
            ? name
            : "\(parent.relativePath)/\(name)"
        let url = parent.url.appendingPathComponent(name, isDirectory: true)
        let isRequested = components.count == 1

        // The type is re-read from the open parent and the open then
        // refuses to follow a link, so neither this check nor the descent
        // can be redirected by a replacement landing between them.
        let metadata = try metadata(ofChild: name, in: parent, url: url)
        let isTraversable = metadata.map { $0.isDirectory && !$0.isSymbolicLink } ?? false
        guard isTraversable, let child = try openChild(
            name,
            of: parent,
            url: url,
            relativePath: relativePath
        ) else {
            guard isRequested else {
                throw WorkspaceScannerError.invalidRelativeDirectory(requested)
            }
            return nil
        }
        defer { directoryEnumerator.closeDirectory(child) }
        return try withRequestedDirectory(
            requested: requested,
            components: components.dropFirst(),
            in: child,
            inheritedRules: inheritedRules,
            body
        )
    }

    private func contents(
        of directory: QueuedDirectory,
        handle: WorkspaceDirectoryHandle,
        options: WorkspaceDiscoveryOptions
    ) throws -> DirectoryContents {
        try Task.checkCancellation()

        // The listing is read from the directory the scan already holds
        // open, and each child's type is read back from that same
        // descriptor, so nothing here re-walks the path that reached it.
        // Names are carried through sorting, classification, and
        // relative-path construction: sorting URLs re-derived
        // `lastPathComponent` twice per comparison, which dominated
        // large-directory scans.
        let children: [WorkspaceDirectoryChild]
        do {
            children = try directoryEnumerator.children(in: handle)
                .sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            guard children.allSatisfy({
                WorkspacePathComponentValidator.isValid($0.name)
            }) else {
                throw WorkspaceAccessFailure.unavailable
            }
        } catch {
            throw WorkspaceScannerError.directoryEnumerationFailed(
                directory.url,
                accessFailure(from: error)
            )
        }

        // The listing just read says whether this directory has ignore data
        // at all, so the common case -- almost every directory in a
        // workspace -- costs no open. A capability with no filesystem
        // behind it keeps a listing and its ignore data independent, so it
        // is always asked.
        let hasIgnoreFile = handle.isVirtual || children.contains { $0.name == ".gitignore" }
        let rules = directory.inheritedRules
            + (hasIgnoreFile ? try ignoreRules(in: handle) : [])

        var entries: [WorkspaceFileEntry] = []
        var childDirectories: [QueuedDirectory] = []
        entries.reserveCapacity(children.count)
        childDirectories.reserveCapacity(children.count)

        for child in children {
            try Task.checkCancellation()
            let name = child.name
            if name == ".git" {
                continue
            }

            let relativePath = directory.relativePath.isEmpty
                ? name
                : "\(directory.relativePath)/\(name)"
            guard let metadata = try metadata(
                ofChild: name,
                in: handle,
                url: child.url
            ) else {
                continue
            }
            let entry = makeEntry(
                url: child.url,
                relativePath: relativePath,
                name: name,
                metadata: metadata,
                rules: rules
            )

            if name == ".gitignore" {
                if options.includeHidden {
                    entries.append(entry)
                }
                continue
            }

            if (!entry.isHidden || options.includeHidden)
                && (!entry.isIgnored || options.includeIgnored) {
                entries.append(entry)
            }

            if entry.kind == .directory,
               !entry.isHidden || options.includeHidden,
               !entry.isIgnored
                    || options.includeIgnored
                    || rules.contains(where: \.isNegated) {
                childDirectories.append(
                    QueuedDirectory(
                        url: child.url,
                        relativePath: relativePath,
                        inheritedRules: rules
                    )
                )
            }
        }

        return DirectoryContents(
            entries: entries,
            childDirectories: childDirectories
        )
    }

    private func makeEntry(
        url: URL,
        relativePath: String,
        name: String,
        metadata: WorkspacePathMetadata,
        rules: [IgnoreRule]
    ) -> WorkspaceFileEntry {
        let isDirectory = metadata.isDirectory && !metadata.isSymbolicLink
        let isHidden = metadata.isHidden || name.hasPrefix(".")
        return WorkspaceFileEntry(
            url: isDirectory ? directoryURL(url) : url,
            relativePath: relativePath,
            kind: metadata.isSymbolicLink ? .symbolicLink : (isDirectory ? .directory : .file),
            isHidden: isHidden,
            isIgnored: isIgnored(
                relativePath: relativePath,
                isDirectory: isDirectory,
                rules: rules
            )
        )
    }

    // MARK: - Root-anchored traversal

    private struct OpenAncestor {
        let name: String
        let handle: WorkspaceDirectoryHandle
    }

    /// Everything the scan holds open while it walks: the workspace root,
    /// which anchors every lookup, and the chain of directories leading to
    /// the one it worked in last. Breadth-first order visits directories
    /// that share a prefix together, so the next one usually reuses most of
    /// the chain and opens only what differs. The chain is a single path,
    /// never a level, so its length is bounded by depth rather than by the
    /// number of queued directories -- and capped besides, so a
    /// pathologically deep tree cannot exhaust the descriptor table.
    private struct RootAnchor {
        static let maximumCachedDepth = 32

        let root: WorkspaceDirectoryHandle
        var chain: [OpenAncestor] = []
    }

    private func close(_ anchor: inout RootAnchor) {
        while let ancestor = anchor.chain.popLast() {
            directoryEnumerator.closeDirectory(ancestor.handle)
        }
        directoryEnumerator.closeDirectory(anchor.root)
    }

    /// Opens one queued directory from the anchor and hands it to `body`,
    /// closing it before returning. Answers `nil` -- and the scan drops the
    /// subtree -- when the directory, or anything it hangs from, is no
    /// longer a directory reachable from the root without following a link.
    private func withDirectory<T>(
        _ directory: QueuedDirectory,
        anchor: inout RootAnchor,
        _ body: (WorkspaceDirectoryHandle) throws -> T
    ) throws -> T? {
        guard !directory.relativePath.isEmpty else {
            return try body(anchor.root)
        }

        let name = lastComponent(of: directory.relativePath)
        let parentComponents = directory.relativePath
            .dropLast(name.count + 1)
            .split(separator: "/")
            .map(String.init)

        // An ancestor below the cached depth belongs to this directory
        // alone: the walk closes each one as soon as the next is open, so
        // depth cannot run the descriptor table down either.
        var transient: WorkspaceDirectoryHandle?
        defer {
            if let transient {
                directoryEnumerator.closeDirectory(transient)
            }
        }
        guard let parent = try parentDirectory(
            components: parentComponents,
            anchor: &anchor,
            transient: &transient
        ) else {
            return nil
        }

        // The queued type was read while the parent was listed. Read it
        // again from the parent that is open right now, so a directory that
        // has since become a symbolic link, a file, or nothing at all is
        // dropped rather than entered.
        let metadata = try metadata(ofChild: name, in: parent, url: directory.url)
        guard metadata?.isDirectory == true, metadata?.isSymbolicLink == false else {
            return nil
        }
        guard let handle = try openChild(
            name,
            of: parent,
            url: directory.url,
            relativePath: directory.relativePath
        ) else {
            return nil
        }
        defer { directoryEnumerator.closeDirectory(handle) }
        return try body(handle)
    }

    /// Resolves the directory that directly contains the one about to be
    /// scanned, reusing the open ancestors it shares with the chain and
    /// opening the rest one component at a time. Each step resolves a
    /// single name inside the directory opened by the step before it, so
    /// replacing any of them redirects nothing: the walk simply stops.
    private func parentDirectory(
        components: [String],
        anchor: inout RootAnchor,
        transient: inout WorkspaceDirectoryHandle?
    ) throws -> WorkspaceDirectoryHandle? {
        var shared = 0
        while shared < anchor.chain.count,
              shared < components.count,
              anchor.chain[shared].name == components[shared] {
            shared += 1
        }
        while anchor.chain.count > shared, let ancestor = anchor.chain.popLast() {
            directoryEnumerator.closeDirectory(ancestor.handle)
        }

        var current = anchor.chain.last?.handle ?? anchor.root
        for name in components[shared...] {
            let relativePath = current.relativePath.isEmpty
                ? name
                : "\(current.relativePath)/\(name)"
            guard let opened = try openChild(
                name,
                of: current,
                url: current.url.appendingPathComponent(name, isDirectory: true),
                relativePath: relativePath
            ) else {
                return nil
            }
            if anchor.chain.count < RootAnchor.maximumCachedDepth {
                anchor.chain.append(OpenAncestor(name: name, handle: opened))
            } else {
                if let previous = transient {
                    directoryEnumerator.closeDirectory(previous)
                }
                transient = opened
            }
            current = opened
        }
        return current
    }

    // MARK: - Capabilities

    private func openRoot(_ root: URL) throws -> WorkspaceDirectoryHandle? {
        let opening: WorkspaceDirectoryOpening
        do {
            opening = try directoryEnumerator.openRoot(root)
        } catch {
            throw WorkspaceScannerError.directoryEnumerationFailed(
                root,
                accessFailure(from: error)
            )
        }
        switch opening {
        case .opened(let handle):
            return WorkspaceDirectoryHandle(
                url: root,
                relativePath: "",
                descriptor: handle.descriptor
            )
        case .notTraversable:
            return nil
        }
    }

    /// Opens one child and re-labels it with the location the scan itself
    /// walked to, so reporting and ignore scoping never depend on what a
    /// capability chose to put in the handle.
    private func openChild(
        _ name: String,
        of parent: WorkspaceDirectoryHandle,
        url: URL,
        relativePath: String
    ) throws -> WorkspaceDirectoryHandle? {
        guard WorkspacePathComponentValidator.isValid(name) else {
            throw WorkspaceScannerError.invalidRelativeDirectory(relativePath)
        }
        let opening: WorkspaceDirectoryOpening
        do {
            opening = try directoryEnumerator.openChild(
                name,
                of: parent,
                url: url,
                relativePath: relativePath
            )
        } catch {
            throw WorkspaceScannerError.directoryEnumerationFailed(
                url,
                accessFailure(from: error)
            )
        }
        switch opening {
        case .opened(let handle):
            return WorkspaceDirectoryHandle(
                url: url,
                relativePath: relativePath,
                descriptor: handle.descriptor
            )
        case .notTraversable:
            return nil
        }
    }

    private func metadata(
        ofChild name: String,
        in directory: WorkspaceDirectoryHandle,
        url: URL
    ) throws -> WorkspacePathMetadata? {
        guard WorkspacePathComponentValidator.isValid(name) else {
            throw WorkspaceScannerError.invalidRelativeDirectory(name)
        }
        do {
            return try metadataProvider.metadata(ofChild: name, in: directory, url: url)
        } catch {
            throw WorkspaceScannerError.metadataFailed(
                url,
                accessFailure(from: error)
            )
        }
    }

    private func ignoreRules(in directory: WorkspaceDirectoryHandle) throws -> [IgnoreRule] {
        let contents: String?
        do {
            contents = try ignoreFileSource.ignoreFileContents(in: directory)
        } catch {
            throw WorkspaceScannerError.unreadableIgnoreFile(
                directory.url.appendingPathComponent(".gitignore"),
                accessFailure(from: error)
            )
        }
        guard let contents else {
            return []
        }
        return parseIgnoreRules(contents, relativeDirectory: directory.relativePath)
    }
}

private func lastComponent(of relativePath: String) -> String {
    guard let separator = relativePath.lastIndex(of: "/") else {
        return relativePath
    }
    return String(relativePath[relativePath.index(after: separator)...])
}

private func lastComponent(ofPath path: String) -> Substring {
    guard let separator = path.lastIndex(of: "/") else {
        return path[...]
    }
    return path[path.index(after: separator)...]
}

private func directoryURL(_ url: URL) -> URL {
    url.hasDirectoryPath ? url : URL(fileURLWithPath: url.path, isDirectory: true)
}

private func pathPrefix(of directoryPath: String) -> String {
    directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
}

private let directoryEntryNameOffset = MemoryLayout<dirent>.offset(of: \dirent.d_name) ?? 21

private func directoryEntryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
    let start = UnsafeRawPointer(entry).advanced(by: directoryEntryNameOffset)
    return String(
        decoding: UnsafeRawBufferPointer(
            start: start,
            count: Int(entry.pointee.d_namlen)
        ),
        as: UTF8.self
    )
}

private func posixAccessFailure(_ code: Int32) -> WorkspaceAccessFailure {
    code == EACCES || code == EPERM ? .permissionDenied : .unavailable
}

private func workspaceAccessFailure(for error: Error) -> WorkspaceAccessFailure {
    let cocoaError = error as NSError
    return cocoaError.code == NSFileReadNoPermissionError
        ? .permissionDenied
        : .unavailable
}

private func accessFailure(from error: Error) -> WorkspaceAccessFailure {
    (error as? WorkspaceAccessFailure) ?? workspaceAccessFailure(for: error)
}

private struct IgnoreRule: Sendable {
    let basePath: String
    let pattern: String
    let isNegated: Bool
    let isDirectoryOnly: Bool
    let isAnchored: Bool
    let containsSlash: Bool

    func matches(relativePath: String, isDirectory: Bool) -> Bool {
        let candidate: String
        if basePath.isEmpty {
            candidate = relativePath
        } else {
            let prefix = basePath + "/"
            guard relativePath == basePath || relativePath.hasPrefix(prefix) else {
                return false
            }
            candidate = String(relativePath.dropFirst(prefix.count))
        }

        if isDirectoryOnly {
            var components = candidate.split(separator: "/").map(String.init)
            if !isDirectory, !components.isEmpty {
                components.removeLast()
            }
            return components.contains { globMatches(pattern, $0) }
        }
        if isAnchored || containsSlash {
            return globMatches(pattern, candidate)
        }
        return candidate
            .split(separator: "/")
            .contains { globMatches(pattern, String($0)) }
    }
}

private func parseIgnoreRules(
    _ contents: String,
    relativeDirectory: String
) -> [IgnoreRule] {
    contents
        .split(whereSeparator: \.isNewline)
        .compactMap { line in
            var value = String(line).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, !value.hasPrefix("#") else {
                return nil
            }

            let isNegated = value.hasPrefix("!")
            if isNegated {
                value.removeFirst()
            }
            let isDirectoryOnly = value.hasSuffix("/")
            if isDirectoryOnly {
                value.removeLast()
            }
            let isAnchored = value.hasPrefix("/")
            if isAnchored {
                value.removeFirst()
            }
            guard !value.isEmpty else {
                return nil
            }

            return IgnoreRule(
                basePath: relativeDirectory,
                pattern: value,
                isNegated: isNegated,
                isDirectoryOnly: isDirectoryOnly,
                isAnchored: isAnchored,
                containsSlash: value.contains("/")
            )
        }
}

private func isIgnored(
    relativePath: String,
    isDirectory: Bool,
    rules: [IgnoreRule]
) -> Bool {
    var ignored = false
    for rule in rules where rule.matches(
        relativePath: relativePath,
        isDirectory: isDirectory
    ) {
        ignored = !rule.isNegated
    }
    return ignored
}

private func globMatches(_ pattern: String, _ candidate: String) -> Bool {
    let pattern = Array(pattern)
    let candidate = Array(candidate)
    var memo: [GlobState: Bool] = [:]

    func match(patternIndex: Int, candidateIndex: Int) -> Bool {
        let state = GlobState(patternIndex: patternIndex, candidateIndex: candidateIndex)
        if let cached = memo[state] {
            return cached
        }

        let result: Bool
        if patternIndex == pattern.count {
            result = candidateIndex == candidate.count
        } else if pattern[patternIndex] == "*" {
            let isDoubleStar = patternIndex + 1 < pattern.count
                && pattern[patternIndex + 1] == "*"
            let nextPatternIndex = patternIndex + (isDoubleStar ? 2 : 1)
            result = match(
                patternIndex: nextPatternIndex,
                candidateIndex: candidateIndex
            ) || (
                candidateIndex < candidate.count
                    && (isDoubleStar || candidate[candidateIndex] != "/")
                    && match(
                        patternIndex: patternIndex,
                        candidateIndex: candidateIndex + 1
                    )
            )
        } else if pattern[patternIndex] == "?" {
            result = candidateIndex < candidate.count
                && candidate[candidateIndex] != "/"
                && match(
                    patternIndex: patternIndex + 1,
                    candidateIndex: candidateIndex + 1
                )
        } else {
            result = candidateIndex < candidate.count
                && pattern[patternIndex] == candidate[candidateIndex]
                && match(
                    patternIndex: patternIndex + 1,
                    candidateIndex: candidateIndex + 1
                )
        }

        memo[state] = result
        return result
    }

    return match(patternIndex: 0, candidateIndex: 0)
}

private struct GlobState: Hashable {
    let patternIndex: Int
    let candidateIndex: Int
}
