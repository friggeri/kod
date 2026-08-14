import Foundation
import LanguageClient
import WorkspaceCore

public enum LanguageProfileServiceFactory {
    /// Builds the runtime language-service configuration for `profile`,
    /// entirely from that profile's persisted/default data. The only
    /// value not literally present in the profile is the ShellCheck path
    /// patched in for the shipped `.shellCheckOptional` note, which is
    /// resolved at launch time and written into the section the profile
    /// itself declares.
    static func makeConfiguration(
        languageServer: LanguageServerConfiguration,
        profile: LanguageProfile,
        shellCheckURL: @Sendable () -> URL? = { ShellCheckSupport.discoverShellCheck() }
    ) -> LanguageWorkspaceService.Configuration {
        var workspaceConfiguration = languageServer.workspaceConfiguration
        if languageServer.supportNotes.contains(.shellCheckOptional) {
            workspaceConfiguration = ShellCheckSupport
                .resolvedWorkspaceConfiguration(
                    workspaceConfiguration,
                    shellCheckURL: shellCheckURL()
                )
        }
        return LanguageWorkspaceService.Configuration(
            languageId: languageServer.defaultLanguageID,
            languageIdForURL: { url in
                languageID(
                    for: url,
                    profile: profile,
                    configuration: languageServer
                )
            },
            semanticTokenTypes: languageServer.semanticTokenTypes,
            semanticTokenModifiers: languageServer.semanticTokenModifiers,
            initializationOptions: languageServer.initializationOptions,
            workspaceConfiguration: workspaceConfiguration
        )
    }

    public static func makeService(
        for profile: LanguageProfile,
        identity: WorkspaceIdentity,
        trustStore: WorkspaceTrustStore,
        overrideStore: LanguageServerOverrideStore,
        /// Identity bound into every cross-file result this service
        /// produces. Defaults to a fresh instance of the profile's logical
        /// identity, so replacing a service always invalidates the handles
        /// its predecessor handed out.
        providerID: LanguageProviderID? = nil,
        onDiscovery: @escaping @Sendable (DiscoveredExecutable) -> Void = {
            _ in
        },
        onStateChange: @escaping @Sendable (LanguageServerState) -> Void = {
            _ in
        },
        onDiagnostics: @escaping @Sendable (URL, [Diagnostic]) -> Void = {
            _, _ in
        },
        onNormalizedDiagnostics: @escaping @Sendable (
            URL,
            [NormalizedDiagnostic]
        ) -> Void = { _, _ in },
        onWorkspaceDiagnosticsFailure: @escaping @Sendable (String) -> Void = {
            _ in
        },
        /// Reports documents a relaunched server could not be
        /// resynchronized with; the service never claims `.ready` for a
        /// generation whose replay failed.
        onDocumentReplayFailure: @escaping @Sendable (
            [LanguageDocumentReplayFailure]
        ) -> Void = { _ in }
    ) throws -> LanguageWorkspaceService {
        let profile = try profile.validated()
        guard let languageServer = profile.languageServer else {
            throw LanguageServerDiscoveryError.profileHasNoLanguageServer(
                profile.displayName
            )
        }

        let discoveredLaunch = ProfileDiscoveredLaunchBox()
        let resolvedProviderID = providerID
            ?? LanguageProviderID(profileIdentifier: profile.identifier)
        return LanguageWorkspaceService(
            workspaceRoot: identity.root,
            authorization: .workspaceTrust(trustStore, identity: identity),
            configuration: makeConfiguration(
                languageServer: languageServer,
                profile: profile
            ),
            dependencies: LanguageWorkspaceService.Dependencies(
                discoverExecutable: {
                    let discovered = try LanguageServerDiscoveryEngine.resolve(
                        profile: profile,
                        overrideStore: overrideStore,
                        identity: identity
                    )
                    discoveredLaunch.set(
                        arguments: discovered.arguments,
                        environment: discovered.environment
                    )
                    onDiscovery(discovered)
                    return discovered.url
                },
                connectionFactory: {
                    configuration,
                    onStateChange,
                    onNotification in
                    var configuration = configuration
                    let launch = discoveredLaunch.get()
                    configuration.arguments = launch.arguments
                    configuration.environment = launch.environment
                    return LanguageServerConnection(
                        configuration: configuration,
                        onStateChange: onStateChange,
                        onNotification: onNotification
                    )
                }
            ),
            providerID: resolvedProviderID,
            onStateChange: onStateChange,
            onDiagnostics: onDiagnostics,
            onNormalizedDiagnostics: onNormalizedDiagnostics,
            onWorkspaceDiagnosticsFailure: onWorkspaceDiagnosticsFailure,
            onDocumentReplayFailure: onDocumentReplayFailure
        )
    }

    private static func languageID(
        for url: URL,
        profile: LanguageProfile,
        configuration: LanguageServerConfiguration
    ) -> String? {
        let fileName = url.lastPathComponent.lowercased()
        if let association = profile.associations.first(where: {
            $0.exactFileNames.contains(fileName)
        }) {
            return configuration.languageID(for: association.identifier)
        }
        let fileExtension = url.pathExtension.lowercased()
        if let association = profile.associations.first(where: {
            $0.fileExtensions.contains(fileExtension)
        }) {
            return configuration.languageID(for: association.identifier)
        }
        return nil
    }
}

private final class ProfileDiscoveredLaunchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var arguments: [String] = []
    private var environment: [String: String]?

    func set(
        arguments newArguments: [String],
        environment newEnvironment: [String: String]?
    ) {
        lock.lock()
        arguments = newArguments
        environment = newEnvironment
        lock.unlock()
    }

    func get() -> (arguments: [String], environment: [String: String]?) {
        lock.lock()
        defer { lock.unlock() }
        return (arguments, environment)
    }
}
