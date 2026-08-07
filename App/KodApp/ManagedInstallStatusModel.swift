import Foundation
import ManagedLanguageServers

/// One managed server's current state for UI binding (SPEC 6.5's
/// setup/install/update/rollback/remove surface). This is a plain,
/// `Equatable` snapshot — `ManagedInstallCoordinator` is the only thing
/// that mutates it, always by replacing the whole value, so a SwiftUI/
/// AppKit observer never has to reason about partial updates.
public struct ManagedInstallStatusModel: Sendable, Equatable {
    public enum Lifecycle: Sendable, Equatable {
        case notInstalled
        case unsupportedArchitecture
        case consentRequired(version: SemanticVersion)
        case downloading(bytesReceived: Int, expectedTotalBytes: Int?)
        case verifyingDigest
        case extracting
        case activating
        case installed
        case upgradeAvailable(newVersion: SemanticVersion)
        case failed(message: String)
    }

    public let serverID: String
    public let language: String?
    public let lifecycle: Lifecycle
    /// Non-`nil` exactly when there is a currently-active installed
    /// version (including while an upgrade to a *different* version is
    /// in progress, so the UI can keep reporting the still-working
    /// current install rather than going blank mid-upgrade).
    public let installedVersion: SemanticVersion?
    public let installedArchitecture: ManagedInstallArchitecture?
    public let installedExecutablePath: String?
    /// Always `.managedInstall` once `installedVersion != nil` — kept as
    /// an explicit field (rather than implied) so this model's shape
    /// matches `DiscoveredExecutable`'s "provenance is always visible"
    /// contract (SPEC 6.5: "Kod displays the selected executable,
    /// version, source, and arguments before first launch").
    public let provenance: ExecutableProvenance?

    public enum ExecutableProvenance: String, Sendable, Equatable {
        case managedInstall
    }

    public init(
        serverID: String,
        language: String?,
        lifecycle: Lifecycle,
        installedVersion: SemanticVersion? = nil,
        installedArchitecture: ManagedInstallArchitecture? = nil,
        installedExecutablePath: String? = nil,
        provenance: ExecutableProvenance? = nil
    ) {
        self.serverID = serverID
        self.language = language
        self.lifecycle = lifecycle
        self.installedVersion = installedVersion
        self.installedArchitecture = installedArchitecture
        self.installedExecutablePath = installedExecutablePath
        self.provenance = provenance
    }

    static func notInstalled(serverID: String, language: String?) -> ManagedInstallStatusModel {
        ManagedInstallStatusModel(serverID: serverID, language: language, lifecycle: .notInstalled)
    }

    /// A one-line, user-facing provenance statement distinct from a bare
    /// status dot (SPEC 6.5/13: "Kod displays the selected executable,
    /// version, source... before first launch"). Uses only fields this
    /// model already carries — never invents version/digest data that
    /// wasn't actually reported by `ManagedInstallController`.
    public var provenanceDescription: String {
        guard let provenance, let installedVersion else {
            switch lifecycle {
            case .notInstalled:
                return Localized.string("Not installed.", comment: "Managed language server provenance text when the server has never been installed")
            case .failed:
                return Localized.string(
                    "Not installed (last install attempt failed).",
                    comment: "Managed language server provenance text when the last install attempt failed"
                )
            default:
                return Localized.string("Not yet installed.", comment: "Managed language server provenance text when installation is pending/in-progress")
            }
        }
        switch provenance {
        case .managedInstall:
            let architectureSuffix = installedArchitecture.map { " (\($0.rawValue))" } ?? ""
            return Localized.string(
                "Installed from Kod's managed catalog, version \(installedVersion.description)\(architectureSuffix).",
                comment: "Managed language server provenance text showing the installed version and architecture"
            )
        }
    }
}
