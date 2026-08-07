import Foundation

/// A fully-installed, activated managed server version — what
/// `ManagedInstallController` returns and what
/// `ManagedInstallDiscoverySource` reads to build a `DiscoveredExecutable`.
public struct InstalledServerRecord: Codable, Sendable, Equatable {
    public let serverID: String
    public let version: SemanticVersion
    public let architecture: ManagedInstallArchitecture
    public let installedAt: Date
    /// Relative to `ManagedInstallPaths.versionDirectory(serverID:version:)`.
    public let executableRelativePath: String
    public let adapterArguments: [String]
    public let adapterEnvironment: [String: String]

    public init(
        serverID: String,
        version: SemanticVersion,
        architecture: ManagedInstallArchitecture,
        installedAt: Date,
        executableRelativePath: String,
        adapterArguments: [String],
        adapterEnvironment: [String: String]
    ) {
        self.serverID = serverID
        self.version = version
        self.architecture = architecture
        self.installedAt = installedAt
        self.executableRelativePath = executableRelativePath
        self.adapterArguments = adapterArguments
        self.adapterEnvironment = adapterEnvironment
    }
}

public enum ActiveVersionStoreError: Error, Equatable, Sendable {
    case noActiveVersion(serverID: String)
    case noPreviousVersion(serverID: String)
    case activeVersionDirectoryMissing(serverID: String, version: SemanticVersion)
    case malformedPointerFile(URL)
}

/// Owns the two small JSON "pointer" files
/// (`active-version.json`/`previous-version.json`) that record which
/// installed version of a server is currently active, and support
/// atomic upgrade/rollback (SPEC 6.5: "Pin the selected version and
/// support atomic upgrade and rollback"). The pointer files themselves
/// are always written via write-to-temp-then-`rename()` in the same
/// directory, which POSIX guarantees is atomic on one volume — a reader
/// can never observe a half-written pointer file, only the old content
/// or the fully-new content.
struct ActiveVersionStore: @unchecked Sendable {
    let paths: ManagedInstallPaths
    let fileManager: FileManager

    init(paths: ManagedInstallPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    private struct Pointer: Codable {
        let version: SemanticVersion
        let architecture: ManagedInstallArchitecture
        let recordedAt: Date
        let executableRelativePath: String
        let adapterArguments: [String]
        let adapterEnvironment: [String: String]
    }

    func activeRecord(serverID: String) throws -> InstalledServerRecord? {
        guard let pointer = try readPointer(url: paths.activeVersionPointerURL(serverID: serverID)) else {
            return nil
        }
        return try record(serverID: serverID, pointer: pointer)
    }

    func previousRecord(serverID: String) throws -> InstalledServerRecord? {
        guard let pointer = try readPointer(url: paths.previousVersionPointerURL(serverID: serverID)) else {
            return nil
        }
        return try record(serverID: serverID, pointer: pointer)
    }

    /// Atomically makes `version` the active one for `serverID`,
    /// carrying whatever was previously active into the "previous"
    /// pointer (so `rollback` can restore it) — the previous-pointer
    /// write and the active-pointer write are each individually atomic;
    /// between the two, a crash leaves either the old or the new active
    /// pointer fully intact (never a half-written one), which is exactly
    /// the "interrupted-operation recovery" contract
    /// `ManagedInstallController.recoverInterruptedOperations()`
    /// restores from (see its doc comment).
    func activate(serverID: String, version: SemanticVersion, architecture: ManagedInstallArchitecture, executableRelativePath: String, adapterArguments: [String], adapterEnvironment: [String: String]) throws -> InstalledServerRecord {
        try fileManager.createDirectory(at: paths.serverStateDirectory(serverID: serverID), withIntermediateDirectories: true)

        if let currentActive = try readPointer(url: paths.activeVersionPointerURL(serverID: serverID)) {
            try writePointer(currentActive, url: paths.previousVersionPointerURL(serverID: serverID))
        }

        let newPointer = Pointer(
            version: version,
            architecture: architecture,
            recordedAt: Date(),
            executableRelativePath: executableRelativePath,
            adapterArguments: adapterArguments,
            adapterEnvironment: adapterEnvironment
        )
        try writePointer(newPointer, url: paths.activeVersionPointerURL(serverID: serverID))

        return InstalledServerRecord(
            serverID: serverID,
            version: version,
            architecture: architecture,
            installedAt: newPointer.recordedAt,
            executableRelativePath: executableRelativePath,
            adapterArguments: adapterArguments,
            adapterEnvironment: adapterEnvironment
        )
    }

    /// Swaps active/previous back (SPEC 6.5 "atomic ... rollback"),
    /// requiring the previous version's install directory still exist
    /// on disk — `remove()` always clears both pointers together with
    /// the on-disk version directories it deletes, so a dangling
    /// previous pointer with no backing directory should never occur in
    /// practice, but this is still checked explicitly rather than
    /// assumed.
    @discardableResult
    func rollback(serverID: String) throws -> InstalledServerRecord {
        guard let previous = try readPointer(url: paths.previousVersionPointerURL(serverID: serverID)) else {
            throw ActiveVersionStoreError.noPreviousVersion(serverID: serverID)
        }
        guard let current = try readPointer(url: paths.activeVersionPointerURL(serverID: serverID)) else {
            throw ActiveVersionStoreError.noActiveVersion(serverID: serverID)
        }
        let previousVersionDirectory = paths.versionDirectory(serverID: serverID, version: previous.version)
        guard fileManager.fileExists(atPath: previousVersionDirectory.path) else {
            throw ActiveVersionStoreError.activeVersionDirectoryMissing(serverID: serverID, version: previous.version)
        }

        try writePointer(current, url: paths.previousVersionPointerURL(serverID: serverID))
        try writePointer(previous, url: paths.activeVersionPointerURL(serverID: serverID))

        return try record(serverID: serverID, pointer: previous)
    }

    func clearState(serverID: String) throws {
        let directory = paths.serverStateDirectory(serverID: serverID)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    private func record(serverID: String, pointer: Pointer) throws -> InstalledServerRecord {
        let versionDirectory = paths.versionDirectory(serverID: serverID, version: pointer.version)
        guard fileManager.fileExists(atPath: versionDirectory.path) else {
            throw ActiveVersionStoreError.activeVersionDirectoryMissing(serverID: serverID, version: pointer.version)
        }
        return InstalledServerRecord(
            serverID: serverID,
            version: pointer.version,
            architecture: pointer.architecture,
            installedAt: pointer.recordedAt,
            executableRelativePath: pointer.executableRelativePath,
            adapterArguments: pointer.adapterArguments,
            adapterEnvironment: pointer.adapterEnvironment
        )
    }

    private func readPointer(url: URL) throws -> Pointer? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(Pointer.self, from: data)
        } catch {
            throw ActiveVersionStoreError.malformedPointerFile(url)
        }
    }

    private func writePointer(_ pointer: Pointer, url: URL) throws {
        let data = try JSONEncoder().encode(pointer)
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: temporaryURL, options: .atomic)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: url)
        }
    }
}
