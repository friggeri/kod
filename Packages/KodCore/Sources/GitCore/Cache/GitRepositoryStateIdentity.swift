import Foundation

/// A cheap-to-compute fingerprint of a repository's `HEAD` and index
/// state, used as a cache-invalidation key. Computed entirely from
/// already-known state (`GitRepositoryLocation.head`) plus a plain
/// filesystem `stat()` of the per-worktree `index` file — never by
/// invoking Git, so computing it can never itself perturb repository
/// state.
public struct GitRepositoryStateIdentity: Equatable, Sendable {
    public let headDescription: String
    public let indexFingerprint: String?
    /// Bumped externally (see `GitResultCache.invalidate(for:)`) whenever
    /// the FSEvents pipeline reports a worktree change, so an edit that
    /// only touches tracked working-tree files — never `HEAD` or the
    /// index — still invalidates cached diffs/status.
    public let worktreeGeneration: Int

    public init(headDescription: String, indexFingerprint: String?, worktreeGeneration: Int) {
        self.headDescription = headDescription
        self.indexFingerprint = indexFingerprint
        self.worktreeGeneration = worktreeGeneration
    }
}

public enum GitRepositoryStateIdentityComputer {
    public static func compute(
        location: GitRepositoryLocation,
        worktreeGeneration: Int,
        fileManager: FileManager = .default
    ) -> GitRepositoryStateIdentity {
        let headDescription: String
        switch location.head {
        case .branch(let name):
            headDescription = "branch:\(name)"
        case .detached(let commitID):
            headDescription = "detached:\(commitID)"
        }

        let indexURL = location.gitDirectory.appendingPathComponent("index")
        var fingerprint: String?
        if let attributes = try? fileManager.attributesOfItem(atPath: indexURL.path),
           let modificationDate = attributes[.modificationDate] as? Date,
           let size = attributes[.size] as? Int {
            fingerprint = "\(modificationDate.timeIntervalSince1970):\(size)"
        }

        return GitRepositoryStateIdentity(
            headDescription: headDescription,
            indexFingerprint: fingerprint,
            worktreeGeneration: worktreeGeneration
        )
    }
}
