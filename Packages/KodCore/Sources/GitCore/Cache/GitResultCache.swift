import Foundation

/// A tiny in-memory cache keyed by an arbitrary request key (e.g. a
/// path, or a path+target pair) plus the `GitRepositoryStateIdentity` the
/// cached value was computed under. A lookup only ever returns a hit
/// when the identity matches exactly, so any `HEAD`/index/worktree
/// change transparently invalidates the affected entries the next time
/// they are looked up — never by writing anything to the repository
/// itself, only to this process's own memory. `GitContext` owns the
/// shared worktree-generation counter and calls `invalidateAll()` here
/// from the FSEvents pipeline; this type has no filesystem-watching
/// knowledge of its own.
public actor GitResultCache<Value: Sendable> {
    private struct Entry {
        let identity: GitRepositoryStateIdentity
        let value: Value
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public func value(forKey key: String, identity: GitRepositoryStateIdentity) -> Value? {
        guard let entry = entries[key], entry.identity == identity else {
            return nil
        }
        return entry.value
    }

    public func store(_ value: Value, forKey key: String, identity: GitRepositoryStateIdentity) {
        entries[key] = Entry(identity: identity, value: value)
    }

    public func invalidate(key: String) {
        entries.removeValue(forKey: key)
    }

    public func invalidateAll() {
        entries.removeAll()
    }

    public var count: Int {
        entries.count
    }
}
