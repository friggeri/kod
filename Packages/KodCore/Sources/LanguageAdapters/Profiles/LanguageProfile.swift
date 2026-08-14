import Foundation
import LanguageClient
import SyntaxCore

public enum LanguageProfileOrigin: String, Codable, Sendable, Equatable {
    case `default`
    case custom
}

public enum SyntaxDefinitionReference: Sendable, Equatable {
    case treeSitter(SyntaxLanguage)
    case plainText
}

extension SyntaxDefinitionReference: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case language
    }

    private enum Kind: String, Codable {
        case treeSitter
        case plainText
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .treeSitter:
            self = .treeSitter(
                try container.decode(SyntaxLanguage.self, forKey: .language)
            )
        case .plainText:
            self = .plainText
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .treeSitter(let language):
            try container.encode(Kind.treeSitter, forKey: .kind)
            try container.encode(language, forKey: .language)
        case .plainText:
            try container.encode(Kind.plainText, forKey: .kind)
        }
    }
}

public enum LanguageContentMatcher: String, Codable, Sendable, Hashable {
    case shellShebang
}

public struct LanguageFileAssociation: Codable, Sendable, Equatable {
    public var identifier: String
    public var fileExtensions: [String]
    public var exactFileNames: [String]
    public var contentMatchers: [LanguageContentMatcher]
    public var syntax: SyntaxDefinitionReference

    public init(
        identifier: String,
        fileExtensions: [String] = [],
        exactFileNames: [String] = [],
        contentMatchers: [LanguageContentMatcher] = [],
        syntax: SyntaxDefinitionReference
    ) {
        self.identifier = identifier
        self.fileExtensions = fileExtensions
        self.exactFileNames = exactFileNames
        self.contentMatchers = contentMatchers
        self.syntax = syntax
    }
}

public enum LanguageServerDiscoveryStrategy: Sendable, Equatable {
    case path
    case packageManagerLocations
    case xcrun(tool: String)
    case rustup(component: String)
}

extension LanguageServerDiscoveryStrategy: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case path
        case packageManagerLocations
        case xcrun
        case rustup
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .path:
            self = .path
        case .packageManagerLocations:
            self = .packageManagerLocations
        case .xcrun:
            self = .xcrun(tool: try container.decode(String.self, forKey: .value))
        case .rustup:
            self = .rustup(component: try container.decode(String.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .path:
            try container.encode(Kind.path, forKey: .kind)
        case .packageManagerLocations:
            try container.encode(Kind.packageManagerLocations, forKey: .kind)
        case .xcrun(let tool):
            try container.encode(Kind.xcrun, forKey: .kind)
            try container.encode(tool, forKey: .value)
        case .rustup(let component):
            try container.encode(Kind.rustup, forKey: .kind)
            try container.encode(component, forKey: .value)
        }
    }
}

public struct LanguageServerExecutableCandidate: Codable, Sendable, Equatable {
    public var identifier: String
    public var executableNames: [String]
    public var arguments: [String]
    public var versionArguments: [String]?
    public var discoveryStrategies: [LanguageServerDiscoveryStrategy]
    public var minimumMajorVersion: Int?

    public init(
        identifier: String,
        executableNames: [String],
        arguments: [String],
        versionArguments: [String]? = ["--version"],
        discoveryStrategies: [LanguageServerDiscoveryStrategy] = [
            .path,
            .packageManagerLocations
        ],
        minimumMajorVersion: Int? = nil
    ) {
        self.identifier = identifier
        self.executableNames = executableNames
        self.arguments = arguments
        self.versionArguments = versionArguments
        self.discoveryStrategies = discoveryStrategies
        self.minimumMajorVersion = minimumMajorVersion
    }
}

public struct RegisteredLanguageServerExecutable: Codable, Sendable, Equatable {
    public var path: String
    public var arguments: [String]

    public init(path: String, arguments: [String]) {
        self.path = path
        self.arguments = arguments
    }

    public var url: URL {
        URL(fileURLWithPath: path)
    }
}

public struct LanguageServerConfiguration: Codable, Sendable, Equatable {
    public var defaultLanguageID: String
    public var languageIDOverrides: [String: String]
    public var executableCandidates: [LanguageServerExecutableCandidate]
    public var selectedExecutable: RegisteredLanguageServerExecutable?
    public var semanticTokenTypes: [String]
    public var semanticTokenModifiers: [String]
    public var initializationOptions: JSONValue?
    public var workspaceConfiguration: [String: JSONValue]
    public var networkAccess: LanguageServerNetworkAccess
    public var supportNotes: [LanguageServerSupportNote]

    public init(
        defaultLanguageID: String,
        languageIDOverrides: [String: String] = [:],
        executableCandidates: [LanguageServerExecutableCandidate],
        selectedExecutable: RegisteredLanguageServerExecutable? = nil,
        semanticTokenTypes: [String] = [],
        semanticTokenModifiers: [String] = [],
        initializationOptions: JSONValue? = nil,
        workspaceConfiguration: [String: JSONValue] = [:],
        networkAccess: LanguageServerNetworkAccess = .none,
        supportNotes: [LanguageServerSupportNote] = []
    ) {
        self.defaultLanguageID = defaultLanguageID
        self.languageIDOverrides = languageIDOverrides
        self.executableCandidates = executableCandidates
        self.selectedExecutable = selectedExecutable
        self.semanticTokenTypes = semanticTokenTypes
        self.semanticTokenModifiers = semanticTokenModifiers
        self.initializationOptions = initializationOptions
        self.workspaceConfiguration = workspaceConfiguration
        self.networkAccess = networkAccess
        self.supportNotes = supportNotes
    }

    public func languageID(for associationIdentifier: String) -> String {
        languageIDOverrides[associationIdentifier] ?? defaultLanguageID
    }
}

public struct LanguageProfile: Codable, Sendable, Equatable, Identifiable {
    public var identifier: String
    public var displayName: String
    public var isEnabled: Bool
    public var origin: LanguageProfileOrigin
    public var defaultRevision: Int
    public var lastModifiedOrder: UInt64
    public var associations: [LanguageFileAssociation]
    public var languageServer: LanguageServerConfiguration?

    public var id: String {
        identifier
    }

    public init(
        identifier: String,
        displayName: String,
        isEnabled: Bool = true,
        origin: LanguageProfileOrigin,
        defaultRevision: Int,
        lastModifiedOrder: UInt64 = 0,
        associations: [LanguageFileAssociation],
        languageServer: LanguageServerConfiguration? = nil
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.origin = origin
        self.defaultRevision = defaultRevision
        self.lastModifiedOrder = lastModifiedOrder
        self.associations = associations
        self.languageServer = languageServer
    }
}

public enum LanguageProfileValidationError: Error, Sendable, Equatable {
    case invalidProfileIdentifier(String)
    case invalidDisplayName
    case invalidDefaultRevision
    case tooManyAssociations
    case invalidAssociationIdentifier(String)
    case duplicateAssociationIdentifier(String)
    case emptyAssociation(String)
    case invalidFileExtension(String)
    case duplicateFileExtension(String)
    case invalidExactFileName(String)
    case duplicateExactFileName(String)
    case duplicateContentMatcher(LanguageContentMatcher)
    case unsupportedProfileSyntax(SyntaxLanguage)
    case invalidLanguageID(String)
    case unknownLanguageIDAssociation(String)
    case missingExecutableCandidate
    case invalidExecutableCandidateIdentifier(String)
    case duplicateExecutableCandidateIdentifier(String)
    case invalidExecutableName(String)
    case invalidArguments
    case invalidDiscoveryStrategy
    case invalidMinimumMajorVersion
    case invalidSelectedExecutablePath(String)
    case unsafeCustomConfiguration
    case unsafeCustomDiscoveryStrategy
    case configurationTooLarge
}

extension LanguageProfileValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidProfileIdentifier(let identifier):
            "Invalid language profile identifier: \(identifier)"
        case .invalidDisplayName:
            "A language profile needs a non-empty display name."
        case .invalidDefaultRevision:
            "A language profile revision must be at least 1."
        case .tooManyAssociations:
            "A language profile must contain between 1 and 64 file associations."
        case .invalidAssociationIdentifier(let identifier):
            "Invalid file association identifier: \(identifier)"
        case .duplicateAssociationIdentifier(let identifier):
            "Duplicate file association identifier: \(identifier)"
        case .emptyAssociation(let identifier):
            "File association \(identifier) does not match any files."
        case .invalidFileExtension(let value):
            "Invalid file extension: \(value)"
        case .duplicateFileExtension(let value):
            "File extension \(value) is assigned more than once in the profile."
        case .invalidExactFileName(let value):
            "Invalid exact filename: \(value)"
        case .duplicateExactFileName(let value):
            "Exact filename \(value) is assigned more than once in the profile."
        case .duplicateContentMatcher(let matcher):
            "Content matcher \(matcher.rawValue) is assigned more than once in the profile."
        case .unsupportedProfileSyntax(let language):
            "\(language.displayName) is an internal grammar and cannot be selected by a profile."
        case .invalidLanguageID(let value):
            "Invalid LSP language ID: \(value)"
        case .unknownLanguageIDAssociation(let identifier):
            "The LSP language ID override references unknown association \(identifier)."
        case .missingExecutableCandidate:
            "An enabled language-server configuration needs an executable candidate or selected executable."
        case .invalidExecutableCandidateIdentifier(let identifier):
            "Invalid executable candidate identifier: \(identifier)"
        case .duplicateExecutableCandidateIdentifier(let identifier):
            "Duplicate executable candidate identifier: \(identifier)"
        case .invalidExecutableName(let name):
            "Invalid executable name: \(name)"
        case .invalidArguments:
            "Language-server arguments exceed the supported count or size limits."
        case .invalidDiscoveryStrategy:
            "A language-server discovery strategy is invalid."
        case .invalidMinimumMajorVersion:
            "A minimum executable major version must be positive."
        case .invalidSelectedExecutablePath(let path):
            "A selected language-server executable must use an absolute local path: \(path)"
        case .unsafeCustomConfiguration:
            "Custom profiles cannot provide initialization payloads or built-in support presets."
        case .unsafeCustomDiscoveryStrategy:
            "Custom profiles cannot use Kod's built-in toolchain discovery tools."
        case .configurationTooLarge:
            "The language-server configuration is too large."
        }
    }
}

public extension LanguageProfile {
    /// Rewrites this profile as a user-owned custom profile, dropping
    /// every shipped-only capability (initialization payloads, workspace
    /// configuration, network access, support notes, and toolchain
    /// discovery strategies). Used when a profile that a previous
    /// version shipped is no longer a default: the user's associations
    /// and executable choice survive, the shipped capabilities do not.
    func sanitizedAsCustomProfile() -> LanguageProfile {
        var profile = self
        profile.origin = .custom
        if var configuration = profile.languageServer {
            configuration.initializationOptions = nil
            configuration.workspaceConfiguration = [:]
            configuration.networkAccess = .none
            configuration.supportNotes = []
            configuration.executableCandidates = configuration
                .executableCandidates
                .map { candidate in
                    var candidate = candidate
                    candidate.discoveryStrategies = candidate
                        .discoveryStrategies
                        .filter { strategy in
                            switch strategy {
                            case .path, .packageManagerLocations:
                                return true
                            case .xcrun, .rustup:
                                return false
                            }
                        }
                    if candidate.discoveryStrategies.isEmpty {
                        candidate.discoveryStrategies = [
                            .path,
                            .packageManagerLocations
                        ]
                    }
                    return candidate
                }
            profile.languageServer = configuration
        }
        return profile
    }

    func validated() throws -> LanguageProfile {
        var profile = self
        profile.identifier = try Self.normalizedIdentifier(
            identifier,
            error: .invalidProfileIdentifier(identifier)
        )
        profile.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profile.displayName.isEmpty,
              profile.displayName.utf8.count <= 100,
              !profile.displayName.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw LanguageProfileValidationError.invalidDisplayName
        }
        guard defaultRevision >= 1 else {
            throw LanguageProfileValidationError.invalidDefaultRevision
        }
        guard (1...64).contains(associations.count) else {
            throw LanguageProfileValidationError.tooManyAssociations
        }

        var associationIdentifiers = Set<String>()
        var claimedExtensions = Set<String>()
        var claimedFileNames = Set<String>()
        var claimedMatchers = Set<LanguageContentMatcher>()
        profile.associations = try associations.map { association in
            var association = association
            association.identifier = try Self.normalizedIdentifier(
                association.identifier,
                error: .invalidAssociationIdentifier(association.identifier)
            )
            guard associationIdentifiers.insert(association.identifier).inserted else {
                throw LanguageProfileValidationError
                    .duplicateAssociationIdentifier(association.identifier)
            }

            association.fileExtensions = try Self.normalizedExtensions(
                association.fileExtensions
            )
            for fileExtension in association.fileExtensions {
                guard claimedExtensions.insert(fileExtension).inserted else {
                    throw LanguageProfileValidationError
                        .duplicateFileExtension(fileExtension)
                }
            }

            association.exactFileNames = try Self.normalizedFileNames(
                association.exactFileNames
            )
            for fileName in association.exactFileNames {
                guard claimedFileNames.insert(fileName).inserted else {
                    throw LanguageProfileValidationError
                        .duplicateExactFileName(fileName)
                }
            }

            association.contentMatchers = Array(Set(association.contentMatchers))
                .sorted { $0.rawValue < $1.rawValue }
            for matcher in association.contentMatchers {
                guard claimedMatchers.insert(matcher).inserted else {
                    throw LanguageProfileValidationError
                        .duplicateContentMatcher(matcher)
                }
            }

            guard !association.fileExtensions.isEmpty
                    || !association.exactFileNames.isEmpty
                    || !association.contentMatchers.isEmpty else {
                throw LanguageProfileValidationError
                    .emptyAssociation(association.identifier)
            }
            if case .treeSitter(.markdownInline) = association.syntax {
                throw LanguageProfileValidationError
                    .unsupportedProfileSyntax(.markdownInline)
            }
            return association
        }

        if var configuration = languageServer {
            configuration.defaultLanguageID = try Self.normalizedLanguageID(
                configuration.defaultLanguageID
            )
            var normalizedOverrides: [String: String] = [:]
            for (associationIdentifier, languageID) in configuration.languageIDOverrides {
                let normalizedIdentifier = try Self.normalizedIdentifier(
                    associationIdentifier,
                    error: .unknownLanguageIDAssociation(associationIdentifier)
                )
                guard associationIdentifiers.contains(normalizedIdentifier) else {
                    throw LanguageProfileValidationError
                        .unknownLanguageIDAssociation(normalizedIdentifier)
                }
                normalizedOverrides[normalizedIdentifier] = try Self
                    .normalizedLanguageID(languageID)
            }
            configuration.languageIDOverrides = normalizedOverrides

            guard !configuration.executableCandidates.isEmpty
                    || configuration.selectedExecutable != nil else {
                throw LanguageProfileValidationError.missingExecutableCandidate
            }
            var candidateIdentifiers = Set<String>()
            configuration.executableCandidates = try configuration
                .executableCandidates
                .map { candidate in
                    var candidate = candidate
                    candidate.identifier = try Self.normalizedIdentifier(
                        candidate.identifier,
                        error: .invalidExecutableCandidateIdentifier(
                            candidate.identifier
                        )
                    )
                    guard candidateIdentifiers.insert(candidate.identifier).inserted else {
                        throw LanguageProfileValidationError
                            .duplicateExecutableCandidateIdentifier(
                                candidate.identifier
                            )
                    }
                    guard !candidate.executableNames.isEmpty,
                          candidate.executableNames.count <= 16 else {
                        throw LanguageProfileValidationError
                            .invalidExecutableName("")
                    }
                    candidate.executableNames = try Array(
                        Set(candidate.executableNames.map {
                            try Self.normalizedExecutableName($0)
                        })
                    ).sorted()
                    try Self.validateArguments(candidate.arguments)
                    if let versionArguments = candidate.versionArguments {
                        try Self.validateArguments(versionArguments)
                    }
                    guard !candidate.discoveryStrategies.isEmpty,
                          candidate.discoveryStrategies.count <= 8 else {
                        throw LanguageProfileValidationError
                            .invalidDiscoveryStrategy
                    }
                    for strategy in candidate.discoveryStrategies {
                        switch strategy {
                        case .path, .packageManagerLocations:
                            break
                        case .xcrun(let tool):
                            // `xcrun`/`rustup` launch a real toolchain
                            // tool and then launch whatever path it
                            // reports, so they stay shipped-only.
                            guard origin == .default else {
                                throw LanguageProfileValidationError
                                    .unsafeCustomDiscoveryStrategy
                            }
                            _ = try Self.normalizedExecutableName(tool)
                        case .rustup(let component):
                            guard origin == .default else {
                                throw LanguageProfileValidationError
                                    .unsafeCustomDiscoveryStrategy
                            }
                            _ = try Self.normalizedExecutableName(component)
                        }
                    }
                    if let minimumMajorVersion = candidate.minimumMajorVersion,
                       minimumMajorVersion < 1 {
                        throw LanguageProfileValidationError
                            .invalidMinimumMajorVersion
                    }
                    return candidate
                }

            if var selectedExecutable = configuration.selectedExecutable {
                let path = selectedExecutable.path
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !path.isEmpty,
                      (path as NSString).isAbsolutePath,
                      !path.unicodeScalars.contains(where: { $0.value == 0 }) else {
                    throw LanguageProfileValidationError
                        .invalidSelectedExecutablePath(path)
                }
                selectedExecutable.path = URL(fileURLWithPath: path)
                    .standardizedFileURL
                    .path
                try Self.validateArguments(selectedExecutable.arguments)
                configuration.selectedExecutable = selectedExecutable
            }

            configuration.semanticTokenTypes = try Self.normalizedStringList(
                configuration.semanticTokenTypes,
                maximumCount: 128,
                maximumLength: 128
            )
            configuration.semanticTokenModifiers = try Self.normalizedStringList(
                configuration.semanticTokenModifiers,
                maximumCount: 128,
                maximumLength: 128
            )

            if origin == .custom,
               configuration.initializationOptions != nil
                || !configuration.workspaceConfiguration.isEmpty
                || configuration.networkAccess != .none
                || !configuration.supportNotes.isEmpty {
                throw LanguageProfileValidationError.unsafeCustomConfiguration
            }
            let configurationSize = try? JSONEncoder().encode(configuration).count
            guard let configurationSize, configurationSize <= 256 * 1_024 else {
                throw LanguageProfileValidationError.configurationTooLarge
            }
            profile.languageServer = configuration
        }
        return profile
    }

    private static func normalizedIdentifier(
        _ value: String,
        error: LanguageProfileValidationError
    ) throws -> String {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty,
              normalized.utf8.count <= 80,
              normalized.first?.isLetter == true || normalized.first?.isNumber == true,
              normalized.allSatisfy({
                  $0.isLetter || $0.isNumber || $0 == "-" || $0 == "."
              }) else {
            throw error
        }
        return normalized
    }

    private static func normalizedExtensions(_ values: [String]) throws -> [String] {
        var normalized = Set<String>()
        for value in values {
            let extensionValue = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .drop(while: { $0 == "." })
                .lowercased()
            guard !extensionValue.isEmpty,
                  extensionValue.utf8.count <= 32,
                  extensionValue.allSatisfy({
                      $0.isLetter || $0.isNumber || $0 == "+" || $0 == "_"
                          || $0 == "-"
                  }) else {
                throw LanguageProfileValidationError.invalidFileExtension(value)
            }
            normalized.insert(extensionValue)
        }
        return normalized.sorted()
    }

    private static func normalizedFileNames(_ values: [String]) throws -> [String] {
        var normalized = Set<String>()
        for value in values {
            let fileName = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !fileName.isEmpty,
                  fileName.utf8.count <= 160,
                  fileName != ".",
                  fileName != "..",
                  !fileName.contains("/"),
                  !fileName.contains("\\"),
                  !fileName.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw LanguageProfileValidationError.invalidExactFileName(value)
            }
            normalized.insert(fileName)
        }
        return normalized.sorted()
    }

    private static func normalizedLanguageID(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= 128,
              !normalized.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0)
                      || CharacterSet.controlCharacters.contains($0)
              }) else {
            throw LanguageProfileValidationError.invalidLanguageID(value)
        }
        return normalized
    }

    private static func normalizedExecutableName(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= 160,
              normalized != ".",
              normalized != "..",
              !normalized.contains("/"),
              !normalized.contains("\\"),
              !normalized.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw LanguageProfileValidationError.invalidExecutableName(value)
        }
        return normalized
    }

    private static func validateArguments(_ arguments: [String]) throws {
        guard arguments.count <= 64,
              arguments.allSatisfy({
                  $0.utf8.count <= 4_096
                      && !$0.unicodeScalars.contains(where: { $0.value == 0 })
              }) else {
            throw LanguageProfileValidationError.invalidArguments
        }
    }

    private static func normalizedStringList(
        _ values: [String],
        maximumCount: Int,
        maximumLength: Int
    ) throws -> [String] {
        guard values.count <= maximumCount else {
            throw LanguageProfileValidationError.configurationTooLarge
        }
        var normalized = Set<String>()
        for value in values {
            guard !value.isEmpty,
                  value.utf8.count <= maximumLength,
                  !value.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw LanguageProfileValidationError.configurationTooLarge
            }
            normalized.insert(value)
        }
        return normalized.sorted()
    }
}
