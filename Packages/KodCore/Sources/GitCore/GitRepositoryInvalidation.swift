/// A repository change signal supplied by a GitCore client.
///
/// GitCore only needs to know whether any paths changed; retaining the paths
/// keeps the input useful for future targeted invalidation without coupling
/// GitCore to a filesystem-watcher model.
public struct GitRepositoryInvalidation: Equatable, Sendable {
    public let changedPaths: Set<String>

    public init(changedPaths: [String]) {
        self.changedPaths = Set(changedPaths)
    }

    public var isEmpty: Bool {
        changedPaths.isEmpty
    }
}
