import Foundation

// Construction inputs for `LanguageWorkspaceService`: the injectable
// process/connection dependencies and the per-language configuration a
// language profile supplies. Kept beside the service rather than inside
// it so the actor file stays lifecycle and state-machine wiring.

extension LanguageWorkspaceService {
    public struct Dependencies: Sendable {
        public var discoverExecutable: @Sendable () throws -> URL
        public var connectionFactory: @Sendable (
            LanguageServerConnection.Configuration,
            @escaping @Sendable (LanguageServerState) -> Void,
            @escaping @Sendable (ServerNotification) -> Void
        ) -> LanguageServerConnection

        public init(
            discoverExecutable: @escaping @Sendable () throws -> URL,
            connectionFactory: @escaping @Sendable (
                LanguageServerConnection.Configuration,
                @escaping @Sendable (LanguageServerState) -> Void,
                @escaping @Sendable (ServerNotification) -> Void
            ) -> LanguageServerConnection = { configuration, onStateChange, onNotification in
                LanguageServerConnection(
                    configuration: configuration,
                    onStateChange: onStateChange,
                    onNotification: onNotification
                )
            }
        ) {
            self.discoverExecutable = discoverExecutable
            self.connectionFactory = connectionFactory
        }
    }

    public struct Configuration: Sendable {
        public var languageId: String
        public var languageIdForURL: @Sendable (URL) -> String?
        public var arguments: [String]
        public var environment: [String: String]?
        public var semanticTokenTypes: [String]
        public var semanticTokenModifiers: [String]
        public var initializationOptions: JSONValue?
        public var workspaceConfiguration: [String: JSONValue]

        public init(
            languageId: String,
            languageIdForURL: @escaping @Sendable (URL) -> String? = { _ in nil },
            arguments: [String] = [],
            environment: [String: String]? = nil,
            semanticTokenTypes: [String] = [],
            semanticTokenModifiers: [String] = [],
            initializationOptions: JSONValue? = nil,
            workspaceConfiguration: [String: JSONValue] = [:]
        ) {
            self.languageId = languageId
            self.languageIdForURL = languageIdForURL
            self.arguments = arguments
            self.environment = environment
            self.semanticTokenTypes = semanticTokenTypes
            self.semanticTokenModifiers = semanticTokenModifiers
            self.initializationOptions = initializationOptions
            self.workspaceConfiguration = workspaceConfiguration
        }

        func resolvedLanguageId(for url: URL) -> String {
            languageIdForURL(url) ?? languageId
        }
    }
}
