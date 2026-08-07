import Foundation

/// The fixed on-disk layout for everything Phase 8 writes:
/// `~/Library/Application Support/Kod/LanguageServers/` (SPEC 6.5:
/// "Install under `~/Library/Application Support/Kod/LanguageServers`")
/// — never anywhere under the opened workspace. Every subdirectory
/// below is created lazily and only ever holds Kod-managed-install
/// state, never anything workspace-derived.
public struct ManagedInstallPaths: Sendable, Equatable {
    public let root: URL

    /// `root` defaults to the real per-user Application Support
    /// location; tests always pass an isolated temporary directory so
    /// no test run ever touches the real user's install state (and so
    /// tests can assert nothing is written outside that directory —
    /// the "full workspace immutability" and general isolation
    /// requirement).
    public init(root: URL? = nil, fileManager: FileManager = .default) {
        if let root {
            self.root = root
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.root = appSupport.appendingPathComponent("Kod/LanguageServers", isDirectory: true)
        }
    }

    public var catalogDirectory: URL {
        root.appendingPathComponent("catalog", isDirectory: true)
    }

    public var catalogEnvelopeURL: URL {
        catalogDirectory.appendingPathComponent("current-catalog.json")
    }

    public var versionsDirectory: URL {
        root.appendingPathComponent("versions", isDirectory: true)
    }

    public func versionDirectory(serverID: String, version: SemanticVersion) -> URL {
        versionsDirectory.appendingPathComponent(serverID, isDirectory: true).appendingPathComponent(version.description, isDirectory: true)
    }

    public func serverVersionsDirectory(serverID: String) -> URL {
        versionsDirectory.appendingPathComponent(serverID, isDirectory: true)
    }

    public var stagingDirectory: URL {
        root.appendingPathComponent("staging", isDirectory: true)
    }

    public func newStagingDirectory(serverID: String, operationID: UUID = UUID()) -> URL {
        stagingDirectory.appendingPathComponent(serverID, isDirectory: true).appendingPathComponent(operationID.uuidString, isDirectory: true)
    }

    public var downloadsDirectory: URL {
        root.appendingPathComponent("downloads", isDirectory: true)
    }

    public func newDownloadFileURL(serverID: String, operationID: UUID = UUID()) -> URL {
        downloadsDirectory.appendingPathComponent(serverID, isDirectory: true).appendingPathComponent("\(operationID.uuidString).download")
    }

    public var stateDirectory: URL {
        root.appendingPathComponent("state", isDirectory: true)
    }

    public func serverStateDirectory(serverID: String) -> URL {
        stateDirectory.appendingPathComponent(serverID, isDirectory: true)
    }

    public func activeVersionPointerURL(serverID: String) -> URL {
        serverStateDirectory(serverID: serverID).appendingPathComponent("active-version.json")
    }

    public func previousVersionPointerURL(serverID: String) -> URL {
        serverStateDirectory(serverID: serverID).appendingPathComponent("previous-version.json")
    }

    public func consentRecordURL(serverID: String) -> URL {
        serverStateDirectory(serverID: serverID).appendingPathComponent("consent.json")
    }

    public var locksDirectory: URL {
        root.appendingPathComponent("locks", isDirectory: true)
    }

    public func lockFileURL(serverID: String) -> URL {
        locksDirectory.appendingPathComponent("\(serverID).lock")
    }

    /// Every top-level directory this type ever writes under `root` —
    /// used both to eagerly create the full layout and by tests that
    /// assert nothing else gets created.
    public var allManagedDirectories: [URL] {
        [catalogDirectory, versionsDirectory, stagingDirectory, downloadsDirectory, stateDirectory, locksDirectory]
    }

    public func ensureLayoutExists(fileManager: FileManager = .default) throws {
        for directory in allManagedDirectories {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
