import Foundation

public struct ReadOnlyFilePayload: Sendable {
    public let data: Data
    public let modificationDate: Date?

    public init(data: Data, modificationDate: Date?) {
        self.data = data
        self.modificationDate = modificationDate
    }
}

public protocol ReadOnlyFileSystem: Sendable {
    func readFile(at url: URL) throws -> ReadOnlyFilePayload
}

public struct LocalReadOnlyFileSystem: ReadOnlyFileSystem {
    public init() {}

    public func readFile(at url: URL) throws -> ReadOnlyFilePayload {
        let values = try url.resourceValues(forKeys: [
            .contentModificationDateKey,
            .isRegularFileKey
        ])

        guard values.isRegularFile == true else {
            throw SourceSnapshotError.notRegularFile(url)
        }

        return try ReadOnlyFilePayload(
            data: Data(contentsOf: url, options: .mappedIfSafe),
            modificationDate: values.contentModificationDate
        )
    }
}

