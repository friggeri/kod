import Foundation

/// A recorded, explicit user decision to install one specific
/// server+version+architecture combination (SPEC 6.5's managed-install
/// consent model: nothing downloads without this existing first).
/// Persisted alongside the other per-server state so a later app launch
/// can tell "the user already agreed to this exact version" from "this
/// would be a new download the user hasn't approved yet" — e.g. an
/// automatic upgrade check must never silently start a download for a
/// *different* version than the one last consented to.
public struct ManagedInstallConsent: Codable, Sendable, Equatable {
    public let serverID: String
    public let version: SemanticVersion
    public let architecture: ManagedInstallArchitecture
    public let consentedAt: Date

    public init(serverID: String, version: SemanticVersion, architecture: ManagedInstallArchitecture, consentedAt: Date) {
        self.serverID = serverID
        self.version = version
        self.architecture = architecture
        self.consentedAt = consentedAt
    }
}

/// Persists/reads one `ManagedInstallConsent` per server ID. A missing
/// or non-matching (different version/architecture) file means "not
/// consented" — `ManagedInstallController.install` always fails closed
/// with `.consentRequired` rather than treating a read error or a stale
/// consent for a different version as an implicit yes.
struct ManagedInstallConsentStore: @unchecked Sendable {
    let paths: ManagedInstallPaths
    let fileManager: FileManager

    init(paths: ManagedInstallPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func consent(serverID: String) -> ManagedInstallConsent? {
        let url = paths.consentRecordURL(serverID: serverID)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(ManagedInstallConsent.self, from: data)
    }

    func record(_ consent: ManagedInstallConsent) throws {
        try fileManager.createDirectory(at: paths.serverStateDirectory(serverID: consent.serverID), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(consent)
        try data.write(to: paths.consentRecordURL(serverID: consent.serverID), options: .atomic)
    }

    func matches(serverID: String, version: SemanticVersion, architecture: ManagedInstallArchitecture) -> Bool {
        guard let consent = consent(serverID: serverID) else {
            return false
        }
        return consent.version == version && consent.architecture == architecture
    }
}
