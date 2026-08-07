import Foundation

/// Every way `ManagedInstallController.install` can refuse to proceed,
/// each reported distinctly (never collapsed into one generic
/// "install failed") so the app layer can show the user exactly why
/// and, where relevant, exactly what to do about it.
public enum ManagedInstallError: Error, Equatable, Sendable {
    case revokedEntry(serverID: String, reason: String?)
    case unsupportedArchitecture(serverID: String, architecture: ManagedInstallArchitecture)
    case insecureArtifactURL(URL)
    case consentRequired(serverID: String, version: SemanticVersion, architecture: ManagedInstallArchitecture)
    case artifactDigestRevoked(sha256Hex: String)
    case digestMismatch(expectedSha256Hex: String, actualSha256Hex: String)
    case missingPrivateRuntime(runtimeServerID: String)
    case noActiveVersion(serverID: String)
    case noPreviousVersionForRollback(serverID: String)
}
