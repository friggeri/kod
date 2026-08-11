import Foundation

/// Kod's advertised client capabilities. Deliberately omits every
/// capability that implies mutation: no `workspace.applyEdit`, no
/// `workspace.workspaceEdit`, no `textDocument.rename`,
/// `.codeAction`, `.formatting`, `.rangeFormatting`, `.onTypeFormatting`,
/// no `workspace.executeCommand`, no `workspace.fileOperations`. Dynamic
/// registration is not declared for anything Kod implements natively, and
/// `LanguageServerConnection` unconditionally rejects any
/// `client/registerCapability` a server sends anyway (SPEC 6.1/13.2).
public struct ClientCapabilities: Encodable, Sendable {
    public struct Workspace: Encodable, Sendable {
        public struct Symbol: Encodable, Sendable {
            public let dynamicRegistration = false
        }
        public let symbol = Symbol()
        public let configuration = true
        /// Explicitly `false`, never omitted: some servers treat a
        /// missing field as "assume default support," so Kod states its
        /// refusal rather than relying on omission.
        public let applyEdit = false
    }

    public struct TextDocument: Encodable, Sendable {
        public struct Hover: Encodable, Sendable {
            public let dynamicRegistration = false
            public let contentFormat = ["plaintext", "markdown"]
        }
        public struct Definition: Encodable, Sendable {
            public let dynamicRegistration = false
            public let linkSupport = true
        }
        public struct References: Encodable, Sendable {
            public let dynamicRegistration = false
        }
        public struct Declaration: Encodable, Sendable {
            public let dynamicRegistration = false
            public let linkSupport = true
        }
        public struct TypeDefinition: Encodable, Sendable {
            public let dynamicRegistration = false
            public let linkSupport = true
        }
        public struct Implementation: Encodable, Sendable {
            public let dynamicRegistration = false
            public let linkSupport = true
        }
        public struct DocumentHighlight: Encodable, Sendable {
            public let dynamicRegistration = false
        }
        public struct DocumentSymbol: Encodable, Sendable {
            public let dynamicRegistration = false
            public let hierarchicalDocumentSymbolSupport = true
        }
        public struct PublishDiagnostics: Encodable, Sendable {
            public let relatedInformation = true
        }
        public struct Diagnostic: Encodable, Sendable {
            public let dynamicRegistration = false
        }
        public struct SemanticTokensRequests: Encodable, Sendable {
            public let full = true
        }
        public struct SemanticTokens: Encodable, Sendable {
            public let dynamicRegistration = false
            public let requests = SemanticTokensRequests()
            public let tokenTypes: [String]
            public let tokenModifiers: [String]
            public let formats = ["relative"]

            public init(tokenTypes: [String], tokenModifiers: [String]) {
                self.tokenTypes = tokenTypes
                self.tokenModifiers = tokenModifiers
            }
        }
        public struct FoldingRange: Encodable, Sendable {
            public let dynamicRegistration = false
            public let lineFoldingOnly = false
        }
        public struct SelectionRange: Encodable, Sendable {
            public let dynamicRegistration = false
        }
        public struct DocumentLink: Encodable, Sendable {
            public let dynamicRegistration = false
            /// Explicitly `false`: Kod never issues `documentLink/resolve`
            /// and must not imply it wants resolvable links.
            public let tooltipSupport = true
        }
        /// Deliberately advertises no `resolveSupport` object: Kod never
        /// issues `inlayHint/resolve`.
        public struct InlayHint: Encodable, Sendable {
            public let dynamicRegistration = false
        }
        public struct SignatureHelpInformation: Encodable, Sendable {
            public let documentationFormat = ["markdown", "plaintext"]
        }
        public struct SignatureHelp: Encodable, Sendable {
            public let dynamicRegistration = false
            public let signatureInformation = SignatureHelpInformation()
        }
        public struct CallHierarchy: Encodable, Sendable {
            public let dynamicRegistration = false
        }
        public struct TypeHierarchy: Encodable, Sendable {
            public let dynamicRegistration = false
        }

        public let hover = Hover()
        public let definition = Definition()
        public let references = References()
        public let declaration = Declaration()
        public let typeDefinition = TypeDefinition()
        public let implementation = Implementation()
        public let documentHighlight = DocumentHighlight()
        public let documentSymbol = DocumentSymbol()
        public let publishDiagnostics = PublishDiagnostics()
        public let diagnostic = Diagnostic()
        public let semanticTokens: SemanticTokens
        public let foldingRange = FoldingRange()
        public let selectionRange = SelectionRange()
        public let documentLink = DocumentLink()
        public let inlayHint = InlayHint()
        public let signatureHelp = SignatureHelp()
        public let callHierarchy = CallHierarchy()
        public let typeHierarchy = TypeHierarchy()

        public init(semanticTokens: SemanticTokens) {
            self.semanticTokens = semanticTokens
        }
    }

    public struct Window: Encodable, Sendable {
        public let workDoneProgress = true
    }

    public struct General: Encodable, Sendable {
        /// Kod prefers UTF-8 positions (SPEC 6.3) but must correctly fall
        /// back to UTF-16 for any server that doesn't negotiate it.
        public let positionEncodings = ["utf-8", "utf-16"]
    }

    public let workspace = Workspace()
    public let textDocument: TextDocument
    public let window = Window()
    public let general = General()

    public init(textDocument: TextDocument) {
        self.textDocument = textDocument
    }
}

public struct WorkspaceFolder: Codable, Sendable {
    public let uri: DocumentURI
    public let name: String

    public init(uri: DocumentURI, name: String) {
        self.uri = uri
        self.name = name
    }
}

public struct InitializeParams: Encodable, Sendable {
    public let processId: Int?
    public let clientInfo: ClientInfo
    public let rootUri: DocumentURI?
    public let capabilities: ClientCapabilities
    public let workspaceFolders: [WorkspaceFolder]?
    public let initializationOptions: JSONValue?
    public let trace: String = "off"

    public struct ClientInfo: Encodable, Sendable {
        public let name: String
        public let version: String
    }

    public init(
        processId: Int?,
        clientInfo: ClientInfo,
        rootUri: DocumentURI?,
        capabilities: ClientCapabilities,
        workspaceFolders: [WorkspaceFolder]?,
        initializationOptions: JSONValue? = nil
    ) {
        self.processId = processId
        self.clientInfo = clientInfo
        self.rootUri = rootUri
        self.capabilities = capabilities
        self.workspaceFolders = workspaceFolders
        self.initializationOptions = initializationOptions
    }
}

/// The subset of `ServerCapabilities` Kod inspects to decide whether a
/// given read-only feature is actually available (SPEC: "If SourceKit
/// lacks a requested capability, capability-gate it"). Any capability
/// shape Kod doesn't model here is simply never looked at — Kod never
/// exercises a server capability it hasn't explicitly typed and
/// evaluated, so there is no risk of accidentally invoking a mutating
/// one that happens to be advertised.
public struct ServerCapabilities: Decodable, Sendable {
    public enum ProviderFlag: Decodable, Sendable {
        case bool(Bool)
        case options(JSONValue)

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else {
                self = .options(try container.decode(JSONValue.self))
            }
        }

        public var isEnabled: Bool {
            switch self {
            case .bool(let value):
                return value
            case .options:
                return true
            }
        }
    }

    public struct SemanticTokensOptions: Decodable, Sendable {
        public struct Legend: Decodable, Sendable {
            public let tokenTypes: [String]
            public let tokenModifiers: [String]
        }
        public let legend: Legend
        public let full: ProviderFlag?
        public let range: ProviderFlag?
    }

    public struct DiagnosticOptions: Decodable, Sendable {
        public let interFileDependencies: Bool
        public let workspaceDiagnostics: Bool
    }

    public let positionEncoding: String?
    public let hoverProvider: ProviderFlag?
    public let definitionProvider: ProviderFlag?
    public let referencesProvider: ProviderFlag?
    public let declarationProvider: ProviderFlag?
    public let typeDefinitionProvider: ProviderFlag?
    public let implementationProvider: ProviderFlag?
    public let documentHighlightProvider: ProviderFlag?
    public let documentSymbolProvider: ProviderFlag?
    public let workspaceSymbolProvider: ProviderFlag?
    public let semanticTokensProvider: SemanticTokensOptions?
    public let diagnosticProvider: DiagnosticOptions?
    public let foldingRangeProvider: ProviderFlag?
    public let selectionRangeProvider: ProviderFlag?
    public let documentLinkProvider: ProviderFlag?
    public let inlayHintProvider: ProviderFlag?
    public let signatureHelpProvider: ProviderFlag?
    public let callHierarchyProvider: ProviderFlag?
    public let typeHierarchyProvider: ProviderFlag?
}

public struct InitializeResult: Decodable, Sendable {
    public let capabilities: ServerCapabilities
}
