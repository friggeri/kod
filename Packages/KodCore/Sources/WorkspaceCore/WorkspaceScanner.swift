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

public protocol DirectoryEnumerator: Sendable {
    func children(of directory: URL) throws -> [URL]
}

public protocol PathMetadataProvider: Sendable {
    /// Returns `nil` only when the path is absent.
    func metadata(for path: URL) throws -> WorkspacePathMetadata?
}

public protocol IgnoreFileSource: Sendable {
    /// Returns `nil` only when the directory has no `.gitignore`.
    func ignoreFileContents(in directory: URL) throws -> String?
}

public struct LocalDirectoryEnumerator: DirectoryEnumerator {
    public init() {}

    public func children(of directory: URL) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            throw workspaceAccessFailure(for: error)
        }
    }
}

public struct LocalPathMetadataProvider: PathMetadataProvider {
    public init() {}

    public func metadata(for path: URL) throws -> WorkspacePathMetadata? {
        do {
            let values = try path.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .isHiddenKey
            ])
            return WorkspacePathMetadata(
                isDirectory: values.isDirectory == true,
                isSymbolicLink: values.isSymbolicLink == true,
                isHidden: values.isHidden == true
            )
        } catch {
            let cocoaError = error as NSError
            if cocoaError.code == NSFileNoSuchFileError
                || cocoaError.code == NSFileReadNoSuchFileError {
                return nil
            }
            throw workspaceAccessFailure(for: error)
        }
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
    /// capabilities used by `scan(root:options:)`.
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
        guard relativePath != ".git", !relativePath.hasPrefix(".git/") else {
            return .excluded(.gitMetadata)
        }

        let metadata: WorkspacePathMetadata
        do {
            guard let value = try metadataProvider.metadata(for: path) else {
                return .absent
            }
            metadata = value
        } catch {
            throw WorkspaceScannerError.metadataFailed(
                path,
                accessFailure(from: error)
            )
        }

        var rules: [IgnoreRule] = []
        var currentDirectory = root
        var currentRelative = ""
        for component in relativePath.split(separator: "/").dropLast() {
            rules += try ignoreRules(
                at: currentDirectory,
                relativeDirectory: currentRelative
            )
            currentDirectory = currentDirectory.appendingPathComponent(
                String(component),
                isDirectory: true
            )
            currentRelative = currentRelative.isEmpty
                ? String(component)
                : "\(currentRelative)/\(component)"
        }
        rules += try ignoreRules(
            at: currentDirectory,
            relativeDirectory: currentRelative
        )

        return .entry(makeEntry(
            url: path,
            relativePath: relativePath,
            metadata: metadata,
            rules: rules
        ))
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

        while nextDirectoryIndex < queue.endIndex {
            try Task.checkCancellation()
            let directory = queue[nextDirectoryIndex]
            nextDirectoryIndex += 1
            let contents = try contents(
                of: directory,
                options: options
            )
            contents.entries.forEach(emit)
            queue.append(contentsOf: contents.childDirectories)

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
        let directory = try directoryContext(
            root: root,
            relativePath: relativePath
        )
        let entries = try contents(of: directory, options: options).entries
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

    private func directoryContext(
        root: URL,
        relativePath: String
    ) throws -> QueuedDirectory {
        if relativePath.isEmpty {
            return QueuedDirectory(
                url: root,
                relativePath: "",
                inheritedRules: []
            )
        }
        guard !relativePath.hasPrefix("/") else {
            throw WorkspaceScannerError.invalidRelativeDirectory(relativePath)
        }

        var directory = root
        var currentRelativePath = ""
        var inheritedRules: [IgnoreRule] = []
        for component in relativePath.split(separator: "/", omittingEmptySubsequences: false) {
            guard !component.isEmpty, component != ".", component != ".." else {
                throw WorkspaceScannerError.invalidRelativeDirectory(relativePath)
            }
            inheritedRules += try ignoreRules(
                at: directory,
                relativeDirectory: currentRelativePath
            )
            directory.appendPathComponent(String(component), isDirectory: true)
            currentRelativePath = currentRelativePath.isEmpty
                ? String(component)
                : "\(currentRelativePath)/\(component)"
        }
        return QueuedDirectory(
            url: directory,
            relativePath: currentRelativePath,
            inheritedRules: inheritedRules
        )
    }

    private func contents(
        of directory: QueuedDirectory,
        options: WorkspaceDiscoveryOptions
    ) throws -> DirectoryContents {
        try Task.checkCancellation()
        let rules = directory.inheritedRules + (try ignoreRules(
            at: directory.url,
            relativeDirectory: directory.relativePath
        ))

        let children: [URL]
        do {
            children = try directoryEnumerator.children(of: directory.url).sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
        } catch {
            throw WorkspaceScannerError.directoryEnumerationFailed(
                directory.url,
                accessFailure(from: error)
            )
        }

        var entries: [WorkspaceFileEntry] = []
        var childDirectories: [QueuedDirectory] = []
        entries.reserveCapacity(children.count)
        childDirectories.reserveCapacity(children.count)

        for child in children {
            try Task.checkCancellation()
            let name = child.lastPathComponent
            if name == ".git" {
                continue
            }

            let relativePath = directory.relativePath.isEmpty
                ? name
                : "\(directory.relativePath)/\(name)"
            let metadata: WorkspacePathMetadata
            do {
                guard let value = try metadataProvider.metadata(for: child) else {
                    continue
                }
                metadata = value
            } catch {
                throw WorkspaceScannerError.metadataFailed(
                    child,
                    accessFailure(from: error)
                )
            }
            let entry = makeEntry(
                url: child,
                relativePath: relativePath,
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
                        url: child,
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
        metadata: WorkspacePathMetadata,
        rules: [IgnoreRule]
    ) -> WorkspaceFileEntry {
        let isDirectory = metadata.isDirectory && !metadata.isSymbolicLink
        let isHidden = metadata.isHidden
            || relativePath.split(separator: "/").last?.hasPrefix(".") == true
        return WorkspaceFileEntry(
            url: url,
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

    private func ignoreRules(
        at directory: URL,
        relativeDirectory: String
    ) throws -> [IgnoreRule] {
        let contents: String?
        do {
            contents = try ignoreFileSource.ignoreFileContents(in: directory)
        } catch {
            throw WorkspaceScannerError.unreadableIgnoreFile(
                directory.appendingPathComponent(".gitignore"),
                accessFailure(from: error)
            )
        }
        guard let contents else {
            return []
        }
        return parseIgnoreRules(contents, relativeDirectory: relativeDirectory)
    }
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
