import Foundation

public struct ScaleFixtureConfiguration: Equatable, Sendable {
    public let root: URL
    public let fileCount: Int
    public let bytesPerFile: Int

    public init(root: URL, fileCount: Int, bytesPerFile: Int) {
        self.root = root
        self.fileCount = fileCount
        self.bytesPerFile = bytesPerFile
    }
}

public enum ScaleFixtureError: Error, Equatable {
    case invalidFileCount(Int)
    case invalidBytesPerFile(Int)
    case destinationIsNotEmpty(URL)
}

public struct ScaleFixtureGenerator {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func generate(_ configuration: ScaleFixtureConfiguration) throws {
        guard configuration.fileCount >= 0 else {
            throw ScaleFixtureError.invalidFileCount(configuration.fileCount)
        }
        guard configuration.bytesPerFile >= 0 else {
            throw ScaleFixtureError.invalidBytesPerFile(configuration.bytesPerFile)
        }

        if fileManager.fileExists(atPath: configuration.root.path) {
            let contents = try fileManager.contentsOfDirectory(
                at: configuration.root,
                includingPropertiesForKeys: nil
            )
            guard contents.isEmpty else {
                throw ScaleFixtureError.destinationIsNotEmpty(configuration.root)
            }
        } else {
            try fileManager.createDirectory(
                at: configuration.root,
                withIntermediateDirectories: true
            )
        }

        for index in 0..<configuration.fileCount {
            let directory = configuration.root
                .appendingPathComponent(String(format: "%03d", index / 1_000), isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            let header = "// fixture \(index)\n"
            let paddingCount = max(0, configuration.bytesPerFile - header.utf8.count)
            let source = header + String(repeating: "x", count: paddingCount)
            let file = directory.appendingPathComponent(
                String(format: "file-%06d.swift", index),
                isDirectory: false
            )
            try Data(source.utf8).write(to: file, options: .withoutOverwriting)
        }
    }
}
