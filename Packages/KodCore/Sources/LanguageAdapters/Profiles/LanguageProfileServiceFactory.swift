import Foundation
import LanguageClient
import WorkspaceCore

public enum LanguageProfileServiceFactory {
    public static func makeService(
        for profile: LanguageProfile,
        identity: WorkspaceIdentity,
        trustStore: WorkspaceTrustStore,
        overrideStore: LanguageServerOverrideStore,
        onDiscovery: @escaping @Sendable (DiscoveredExecutable) -> Void = {
            _ in
        },
        onStateChange: @escaping @Sendable (LanguageServerState) -> Void = {
            _ in
        },
        onDiagnostics: @escaping @Sendable (URL, [NormalizedDiagnostic]) -> Void = {
            _, _ in
        }
    ) throws -> LanguageWorkspaceService {
        let profile = try profile.validated()
        guard let languageServer = profile.languageServer else {
            throw LanguageServerDiscoveryError.profileHasNoLanguageServer(
                profile.displayName
            )
        }

        var workspaceConfiguration = languageServer.workspaceConfiguration
        if languageServer.supportNotes.contains(.shellCheckOptional) {
            workspaceConfiguration = ShellLanguageAdapter.configuration(
                shellCheckURL: ShellLanguageAdapter.discoverShellCheck()
            )
        }

        let discoveredLaunch = ProfileDiscoveredLaunchBox()
        return LanguageWorkspaceService(
            identity: identity,
            trustStore: trustStore,
            configuration: LanguageWorkspaceService.Configuration(
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
            onStateChange: onStateChange,
            onDiagnostics: onDiagnostics
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
