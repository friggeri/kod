import Foundation
import WorkspaceCore

/// The main integration surface for Git-derived data: repository
/// location, status, diff, and blame, each backed by identity-keyed
/// caching invalidated from the workspace's existing FSEvents pipeline.
/// This is the one type App code needs to hold onto per open workspace.
public actor GitContext {
    public let location: GitRepositoryLocation
    private let executableURL: URL
    private let environment: [String: String]
    private let statusService: GitStatusService
    private let diffService: GitDiffService
    private let blameService: GitBlameService

    private let statusCache = GitResultCache<GitStatusSnapshot>()
    private let diffCache = GitResultCache<GitFileDiff>()
    private let blameCache = GitResultCache<GitBlameResult>()
    private var worktreeGeneration = 0

    /// Resolves Git's absolute executable and this path's repository
    /// location, then constructs a ready-to-use context. Throws if
    /// `path` is not inside a Git repository/worktree, or if no Git
    /// executable can be found at any fixed candidate location.
    public static func open(at path: URL, executableURL: URL? = nil) async throws -> GitContext {
        let resolvedExecutable = try executableURL ?? GitExecutableLocator.resolve()
        let locator = GitRepositoryLocator(executableURL: resolvedExecutable)
        let location = try await locator.locate(startingAt: path)
        return GitContext(location: location, executableURL: resolvedExecutable)
    }

    public init(location: GitRepositoryLocation, executableURL: URL) {
        self.location = location
        self.executableURL = executableURL
        self.environment = GitInvocationHardening.environment(home: ProcessInfo.processInfo.environment["HOME"])
        self.statusService = GitStatusService(
            executableURL: executableURL,
            repositoryRoot: location.workingTreeRoot,
            environment: environment
        )
        self.diffService = GitDiffService(
            executableURL: executableURL,
            repositoryRoot: location.workingTreeRoot,
            environment: environment
        )
        self.blameService = GitBlameService(
            executableURL: executableURL,
            repositoryRoot: location.workingTreeRoot,
            environment: environment
        )
    }

    private func currentIdentity() -> GitRepositoryStateIdentity {
        GitRepositoryStateIdentityComputer.compute(location: location, worktreeGeneration: worktreeGeneration)
    }

    public func status(useCache: Bool = true) async throws -> GitStatusSnapshot {
        let identity = currentIdentity()
        let key = "status"
        if useCache, let cached = await statusCache.value(forKey: key, identity: identity) {
            return cached
        }
        let snapshot = try await statusService.status()
        await statusCache.store(snapshot, forKey: key, identity: identity)
        return snapshot
    }

    public func diff(
        path: String,
        target: GitDiffTarget,
        isUntracked: Bool = false,
        knownOldPath: String? = nil,
        useCache: Bool = true
    ) async throws -> GitFileDiff {
        let identity = currentIdentity()
        let key = "\(target)|\(isUntracked)|\(knownOldPath ?? "")|\(path)"
        if useCache, let cached = await diffCache.value(forKey: key, identity: identity) {
            return cached
        }
        let fileDiff = try await diffService.diff(
            path: path,
            target: target,
            isUntracked: isUntracked,
            knownOldPath: knownOldPath
        )
        await diffCache.store(fileDiff, forKey: key, identity: identity)
        return fileDiff
    }

    public func blame(path: String, revision: String? = nil, useCache: Bool = true) async throws -> GitBlameResult {
        let identity = currentIdentity()
        let key = "\(revision ?? "worktree")|\(path)"
        if useCache, let cached = await blameCache.value(forKey: key, identity: identity) {
            return cached
        }
        let result = try await blameService.blame(path: path, revision: revision)
        await blameCache.store(result, forKey: key, identity: identity)
        return result
    }

    /// Wires this context's caches to the workspace's existing FSEvents
    /// pipeline (`WorkspaceFileWatcher(onBatch:)`). Any non-empty batch —
    /// a tracked file edited, `.git/HEAD` changed by an external `git
    /// checkout`, a ref updated, etc. — bumps the worktree generation and
    /// drops every cached entry, so the next `status()`/`diff()`/
    /// `blame()` call recomputes rather than serving stale data. This
    /// only clears Kod's own in-memory cache; it never writes to `.git`
    /// or the working tree.
    public func invalidate(for batch: WorkspaceChangeBatch) async {
        guard !batch.paths.isEmpty else {
            return
        }
        worktreeGeneration += 1
        await statusCache.invalidateAll()
        await diffCache.invalidateAll()
        await blameCache.invalidateAll()
    }
}
