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

public struct WorkspaceScanner: Sendable {
    public init() {}

    /// Classifies a single path that changed on disk (created or modified),
    /// without rescanning the rest of the workspace: walks the ignore-rule
    /// chain from `root` down to `path`'s containing directory (reading
    /// only the `.gitignore` files actually on that chain, not the whole
    /// subtree), then applies the same hidden/ignored rules `scan(root:)`
    /// uses. Returns `nil` for `.git` itself/its contents (always excluded,
    /// matching `scan(root:)`), for paths outside `root`, or if `path` no
    /// longer exists.
    ///
    /// Used by FSEvents-driven incremental updates (SPEC 5.6) to keep
    /// classification correct (respecting every ancestor `.gitignore`)
    /// without paying for a full workspace rescan on every external write.
    public func classify(path: URL, root: URL) -> WorkspaceFileEntry? {
        let rootPath = root.standardizedFileURL.path
        let targetPath = path.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard targetPath.hasPrefix(prefix) else {
            return nil
        }
        let relativePath = String(targetPath.dropFirst(prefix.count))
        guard !relativePath.isEmpty, relativePath != ".git", !relativePath.hasPrefix(".git/") else {
            return nil
        }

        guard let values = try? path.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isHiddenKey
        ]) else {
            return nil
        }

        var rules: [IgnoreRule] = []
        var currentDirectory = root
        var currentRelative = ""
        for component in relativePath.split(separator: "/").dropLast() {
            rules += loadIgnoreRules(at: currentDirectory, relativeDirectory: currentRelative)
            currentDirectory = currentDirectory.appendingPathComponent(String(component), isDirectory: true)
            currentRelative = currentRelative.isEmpty ? String(component) : "\(currentRelative)/\(component)"
        }
        rules += loadIgnoreRules(at: currentDirectory, relativeDirectory: currentRelative)

        let isSymbolicLink = values.isSymbolicLink == true
        let isDirectory = values.isDirectory == true && !isSymbolicLink
        let isHidden = values.isHidden == true || relativePath.split(separator: "/").last?.hasPrefix(".") == true
        let ignored = isIgnored(relativePath: relativePath, isDirectory: isDirectory, rules: rules)

        let kind: WorkspaceFileKind = isSymbolicLink ? .symbolicLink : (isDirectory ? .directory : .file)
        return WorkspaceFileEntry(
            url: path,
            relativePath: relativePath,
            kind: kind,
            isHidden: isHidden,
            isIgnored: ignored
        )
    }

    public func scan(
        root: URL,
        options: WorkspaceDiscoveryOptions = WorkspaceDiscoveryOptions()
    ) -> AsyncThrowingStream<WorkspaceDiscoveryBatch, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try Self.scanSynchronously(
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

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func scanSynchronously(
        root: URL,
        options: WorkspaceDiscoveryOptions,
        continuation: AsyncThrowingStream<WorkspaceDiscoveryBatch, Error>.Continuation
    ) throws {
        let fileManager = FileManager()
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

        func visit(
            directory: URL,
            relativeDirectory: String,
            inheritedRules: [IgnoreRule]
        ) throws {
            try Task.checkCancellation()

            let rules = inheritedRules + loadIgnoreRules(
                at: directory,
                relativeDirectory: relativeDirectory
            )
            let children = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .isHiddenKey
                ],
                options: []
            ).sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }

            for child in children {
                try Task.checkCancellation()

                let name = child.lastPathComponent
                if name == ".git" {
                    continue
                }

                let relativePath = relativeDirectory.isEmpty
                    ? name
                    : "\(relativeDirectory)/\(name)"
                let values = try child.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .isHiddenKey
                ])
                let isSymbolicLink = values.isSymbolicLink == true
                let isDirectory = values.isDirectory == true && !isSymbolicLink
                let isHidden = values.isHidden == true || name.hasPrefix(".")
                let ignored = isIgnored(
                    relativePath: relativePath,
                    isDirectory: isDirectory,
                    rules: rules
                )

                if name == ".gitignore" {
                    if options.includeHidden {
                        emit(
                            WorkspaceFileEntry(
                                url: child,
                                relativePath: relativePath,
                                kind: .file,
                                isHidden: true,
                                isIgnored: ignored
                            )
                        )
                    }
                    continue
                }

                let shouldInclude = (!isHidden || options.includeHidden)
                    && (!ignored || options.includeIgnored)

                if shouldInclude {
                    let kind: WorkspaceFileKind
                    if isSymbolicLink {
                        kind = .symbolicLink
                    } else if isDirectory {
                        kind = .directory
                    } else {
                        kind = .file
                    }

                    emit(
                        WorkspaceFileEntry(
                            url: child,
                            relativePath: relativePath,
                            kind: kind,
                            isHidden: isHidden,
                            isIgnored: ignored
                        )
                    )
                }

                if isDirectory,
                   !isHidden || options.includeHidden,
                   !ignored || options.includeIgnored || rules.contains(where: \.isNegated) {
                    try visit(
                        directory: child,
                        relativeDirectory: relativePath,
                        inheritedRules: rules
                    )
                }
            }
        }

        try visit(directory: root, relativeDirectory: "", inheritedRules: [])

        if !pending.isEmpty {
            continuation.yield(
                WorkspaceDiscoveryBatch(
                    entries: pending,
                    discoveredCount: discoveredCount
                )
            )
        }
    }
}

struct IgnoreRule: Sendable {
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

func loadIgnoreRules(
    at directory: URL,
    relativeDirectory: String
) -> [IgnoreRule] {
    let ignoreURL = directory.appendingPathComponent(".gitignore", isDirectory: false)
    guard let contents = try? String(contentsOf: ignoreURL, encoding: .utf8) else {
        return []
    }

    return contents
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

func isIgnored(
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

func globMatches(_ pattern: String, _ candidate: String) -> Bool {
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

struct GlobState: Hashable {
    let patternIndex: Int
    let candidateIndex: Int
}

