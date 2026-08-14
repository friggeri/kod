import LanguageClient
import SyntaxCore

/// The single, shipped source of Kod's default language configuration:
/// file associations, syntax mapping, LSP language IDs, executable
/// candidates and their discovery strategies, semantic token legends,
/// workspace configuration, network access, and support notes all live
/// here once. `LanguageProfileStore` persists these values, and every
/// runtime consumer (registry, discovery engine, service factory,
/// installation guides) reads them back rather than holding a second
/// static copy.
public enum DefaultLanguageProfiles {
    public static let all: [LanguageProfile] = [
        swift,
        typeScript,
        html,
        css,
        python,
        rust,
        shell,
        markdown,
        json,
        yaml,
        toml,
        c,
        go,
        java,
        ruby,
        lua,
        graphql,
        xml
    ]

    public static let swift = LanguageProfile(
        identifier: "swift",
        displayName: "Swift",
        origin: .default,
        defaultRevision: 1,
        associations: [
            LanguageFileAssociation(
                identifier: "swift",
                fileExtensions: ["swift"],
                syntax: .treeSitter(.swift)
            )
        ],
        languageServer: LanguageServerConfiguration(
            defaultLanguageID: "swift",
            executableCandidates: [
                LanguageServerExecutableCandidate(
                    identifier: "sourcekit-lsp",
                    executableNames: ["sourcekit-lsp"],
                    arguments: [],
                    versionArguments: nil,
                    discoveryStrategies: [
                        .xcrun(tool: "sourcekit-lsp"),
                        .path,
                        .packageManagerLocations
                    ]
                )
            ],
            semanticTokenTypes: SwiftWorkspaceLanguageService.semanticTokenTypes,
            semanticTokenModifiers: SwiftWorkspaceLanguageService.semanticTokenModifiers
        )
    )

    public static let typeScript = LanguageProfile(
        identifier: "typescript",
        displayName: "TypeScript/JavaScript",
        origin: .default,
        defaultRevision: 1,
        associations: [
            LanguageFileAssociation(
                identifier: "typescript",
                fileExtensions: ["ts", "mts", "cts"],
                syntax: .treeSitter(.typescript)
            ),
            LanguageFileAssociation(
                identifier: "typescriptreact",
                fileExtensions: ["tsx"],
                syntax: .treeSitter(.tsx)
            ),
            LanguageFileAssociation(
                identifier: "javascript",
                fileExtensions: ["js", "mjs", "cjs"],
                syntax: .treeSitter(.javascript)
            ),
            LanguageFileAssociation(
                identifier: "javascriptreact",
                fileExtensions: ["jsx"],
                syntax: .treeSitter(.javascript)
            )
        ],
        languageServer: standardServer(
            defaultLanguageID: "typescript",
            languageIDOverrides: [
                "typescriptreact": "typescriptreact",
                "javascript": "javascript",
                "javascriptreact": "javascriptreact"
            ],
            candidates: [
                LanguageServerExecutableCandidate(
                    identifier: "typescript-native",
                    executableNames: ["tsc"],
                    arguments: ["--lsp", "--stdio"],
                    minimumMajorVersion: 7
                ),
                LanguageServerExecutableCandidate(
                    identifier: "typescript-language-server",
                    executableNames: ["typescript-language-server"],
                    arguments: ["--stdio"]
                )
            ]
        )
    )

    public static let html = LanguageProfile(
        identifier: "html",
        displayName: "HTML",
        origin: .default,
        defaultRevision: 1,
        associations: [
            LanguageFileAssociation(
                identifier: "html",
                fileExtensions: ["html", "htm"],
                syntax: .treeSitter(.html)
            )
        ],
        languageServer: standardServer(
            defaultLanguageID: "html",
            candidates: [
                LanguageServerExecutableCandidate(
                    identifier: "vscode-html-language-server",
                    executableNames: ["vscode-html-language-server"],
                    arguments: ["--stdio"],
                    versionArguments: nil
                )
            ]
        )
    )

    public static let css = LanguageProfile(
        identifier: "css",
        displayName: "CSS",
        origin: .default,
        defaultRevision: 1,
        associations: [
            LanguageFileAssociation(
                identifier: "css",
                fileExtensions: ["css"],
                syntax: .treeSitter(.css)
            ),
            LanguageFileAssociation(
                identifier: "scss",
                fileExtensions: ["scss"],
                syntax: .plainText
            ),
            LanguageFileAssociation(
                identifier: "less",
                fileExtensions: ["less"],
                syntax: .plainText
            )
        ],
        languageServer: standardServer(
            defaultLanguageID: "css",
            languageIDOverrides: [
                "scss": "scss",
                "less": "less"
            ],
            candidates: [
                LanguageServerExecutableCandidate(
                    identifier: "vscode-css-language-server",
                    executableNames: ["vscode-css-language-server"],
                    arguments: ["--stdio"],
                    versionArguments: nil
                )
            ]
        )
    )

    public static let python = LanguageProfile(
        identifier: "python",
        displayName: "Python",
        origin: .default,
        defaultRevision: 1,
        associations: [
            LanguageFileAssociation(
                identifier: "python",
                fileExtensions: ["py", "pyi", "pyw"],
                syntax: .treeSitter(.python)
            )
        ],
        languageServer: standardServer(
            defaultLanguageID: "python",
            candidates: [
                LanguageServerExecutableCandidate(
                    identifier: "pyright",
                    executableNames: ["pyright-langserver"],
                    arguments: ["--stdio"],
                    versionArguments: nil
                )
            ]
        )
    )

    public static let rust = LanguageProfile(
        identifier: "rust",
        displayName: "Rust",
        origin: .default,
        defaultRevision: 1,
        associations: [
            LanguageFileAssociation(
                identifier: "rust",
                fileExtensions: ["rs"],
                syntax: .treeSitter(.rust)
            )
        ],
        languageServer: standardServer(
            defaultLanguageID: "rust",
            candidates: [
                LanguageServerExecutableCandidate(
                    identifier: "rust-analyzer",
                    executableNames: ["rust-analyzer"],
                    arguments: [],
                    discoveryStrategies: [
                        .rustup(component: "rust-analyzer"),
                        .path,
                        .packageManagerLocations
                    ]
                )
            ]
        )
    )

    public static let shell = LanguageProfile(
        identifier: "shellscript",
        displayName: "Shell",
        origin: .default,
        defaultRevision: 1,
        associations: [
            LanguageFileAssociation(
                identifier: "shellscript",
                fileExtensions: ["sh", "bash", "command"],
                exactFileNames: [
                    ".bashrc",
                    ".bash_profile",
                    ".bash_login",
                    ".profile"
                ],
                contentMatchers: [.shellShebang],
                syntax: .treeSitter(.shell)
            )
        ],
        languageServer: standardServer(
            defaultLanguageID: "shellscript",
            candidates: [
                LanguageServerExecutableCandidate(
                    identifier: "bash-language-server",
                    executableNames: ["bash-language-server"],
                    arguments: ["start"]
                )
            ],
            workspaceConfiguration: [
                "bashIde": .object([
                    // Filled in from the resolved absolute path at launch
                    // time by `ShellCheckSupport`; shfmt stays disabled.
                    "shellcheckPath": .string(""),
                    "shfmt": .object(["path": .string("")])
                ])
            ],
            supportNotes: [.shellCheckOptional]
        )
    )

    public static let markdown = LanguageProfile(
        identifier: "markdown",
        displayName: "Markdown",
        origin: .default,
        defaultRevision: 1,
        associations: [
            LanguageFileAssociation(
                identifier: "markdown",
                fileExtensions: ["md", "markdown", "mdown", "mkd", "mkdn"],
                syntax: .treeSitter(.markdown)
            )
        ],
        languageServer: standardServer(
            defaultLanguageID: "markdown",
            candidates: [
                LanguageServerExecutableCandidate(
                    identifier: "marksman",
                    executableNames: ["marksman"],
                    arguments: ["server"]
                )
            ]
        )
    )

    public static let json = LanguageProfile(
        identifier: "json",
        displayName: "JSON",
        origin: .default,
        defaultRevision: 1,
        associations: [
            LanguageFileAssociation(
                identifier: "json",
                fileExtensions: ["json"],
                syntax: .treeSitter(.json)
            )
        ],
        languageServer: standardServer(
            defaultLanguageID: "json",
            candidates: [
                LanguageServerExecutableCandidate(
                    identifier: "vscode-json-language-server",
                    executableNames: [
                        "vscode-json-language-server",
                        "vscode-json-languageserver"
                    ],
                    arguments: ["--stdio"],
                    versionArguments: nil
                )
            ],
            workspaceConfiguration: [
                "json": .object([
                    "validate": .object(["enable": .bool(true)])
                ])
            ],
            networkAccess: .remoteSchemasAfterWorkspaceTrust
        )
    )

    public static let yaml = LanguageProfile(
        identifier: "yaml",
        displayName: "YAML",
        origin: .default,
        defaultRevision: 1,
        associations: [
            LanguageFileAssociation(
                identifier: "yaml",
                fileExtensions: ["yaml", "yml"],
                syntax: .treeSitter(.yaml)
            )
        ],
        languageServer: standardServer(
            defaultLanguageID: "yaml",
            candidates: [
                LanguageServerExecutableCandidate(
                    identifier: "yaml-language-server",
                    executableNames: ["yaml-language-server"],
                    arguments: ["--stdio"],
                    versionArguments: nil
                )
            ],
            workspaceConfiguration: [
                "yaml": .object([
                    "validate": .bool(true),
                    "hover": .bool(true),
                    "schemaStore": .object(["enable": .bool(true)])
                ])
            ],
            networkAccess: .remoteSchemasAfterWorkspaceTrust
        )
    )

    public static let toml = LanguageProfile(
        identifier: "toml",
        displayName: "TOML",
        origin: .default,
        defaultRevision: 1,
        associations: [
            LanguageFileAssociation(
                identifier: "toml",
                fileExtensions: ["toml"],
                syntax: .treeSitter(.toml)
            )
        ],
        languageServer: standardServer(
            defaultLanguageID: "toml",
            candidates: [
                LanguageServerExecutableCandidate(
                    identifier: "tombi",
                    executableNames: ["tombi"],
                    arguments: ["lsp"]
                ),
                LanguageServerExecutableCandidate(
                    identifier: "taplo",
                    executableNames: ["taplo"],
                    arguments: ["lsp", "stdio"]
                )
            ],
            networkAccess: .remoteSchemasAfterWorkspaceTrust
        )
    )

    public static let c = LanguageProfile(
        identifier: "c",
        displayName: "C",
        origin: .default,
        defaultRevision: 1,
        associations: [
            LanguageFileAssociation(
                identifier: "c",
                fileExtensions: ["c", "h"],
                syntax: .treeSitter(.c)
            )
        ],
        languageServer: standardServer(
            defaultLanguageID: "c",
            candidates: [
                LanguageServerExecutableCandidate(
                    identifier: "clangd",
                    executableNames: ["clangd"],
                    arguments: []
                )
            ]
        )
    )

    public static let go = LanguageProfile(
        identifier: "go",
        displayName: "Go",
        origin: .default,
        defaultRevision: 1,
        associations: [
            LanguageFileAssociation(
                identifier: "go",
                fileExtensions: ["go"],
                syntax: .treeSitter(.go)
            )
        ],
        languageServer: standardServer(
            defaultLanguageID: "go",
            candidates: [
                LanguageServerExecutableCandidate(
                    identifier: "gopls",
                    executableNames: ["gopls"],
                    arguments: []
                )
            ]
        )
    )

    public static let java = LanguageProfile(
        identifier: "java",
        displayName: "Java",
        origin: .default,
        defaultRevision: 1,
        associations: [
            LanguageFileAssociation(
                identifier: "java",
                fileExtensions: ["java"],
                syntax: .treeSitter(.java)
            )
        ],
        languageServer: standardServer(
            defaultLanguageID: "java",
            candidates: [
                LanguageServerExecutableCandidate(
                    identifier: "jdtls",
                    executableNames: ["jdtls"],
                    arguments: []
                )
            ]
        )
    )

    public static let ruby = LanguageProfile(
        identifier: "ruby",
        displayName: "Ruby",
        origin: .default,
        defaultRevision: 1,
        associations: [
            LanguageFileAssociation(
                identifier: "ruby",
                fileExtensions: ["rb", "rake", "gemspec"],
                exactFileNames: [
                    "gemfile",
                    "rakefile",
                    "guardfile",
                    "config.ru"
                ],
                syntax: .treeSitter(.ruby)
            )
        ],
        languageServer: standardServer(
            defaultLanguageID: "ruby",
            candidates: [
                LanguageServerExecutableCandidate(
                    identifier: "ruby-lsp",
                    executableNames: ["ruby-lsp"],
                    arguments: []
                ),
                LanguageServerExecutableCandidate(
                    identifier: "solargraph",
                    executableNames: ["solargraph"],
                    arguments: ["stdio"]
                )
            ]
        )
    )

    public static let lua = LanguageProfile(
        identifier: "lua",
        displayName: "Lua",
        origin: .default,
        defaultRevision: 1,
        associations: [
            LanguageFileAssociation(
                identifier: "lua",
                fileExtensions: ["lua"],
                syntax: .treeSitter(.lua)
            )
        ],
        languageServer: standardServer(
            defaultLanguageID: "lua",
            candidates: [
                LanguageServerExecutableCandidate(
                    identifier: "lua-language-server",
                    executableNames: ["lua-language-server"],
                    arguments: []
                )
            ]
        )
    )

    public static let graphql = LanguageProfile(
        identifier: "graphql",
        displayName: "GraphQL",
        origin: .default,
        defaultRevision: 1,
        associations: [
            LanguageFileAssociation(
                identifier: "graphql",
                fileExtensions: ["graphql", "gql"],
                syntax: .treeSitter(.graphql)
            )
        ],
        languageServer: standardServer(
            defaultLanguageID: "graphql",
            candidates: [
                LanguageServerExecutableCandidate(
                    identifier: "graphql-lsp",
                    executableNames: ["graphql-lsp"],
                    arguments: ["server", "-m", "stream"]
                )
            ]
        )
    )

    public static let xml = LanguageProfile(
        identifier: "xml",
        displayName: "XML",
        origin: .default,
        defaultRevision: 1,
        associations: [
            LanguageFileAssociation(
                identifier: "xml",
                fileExtensions: [
                    "xml",
                    "svg",
                    "xsd",
                    "xsl",
                    "xslt",
                    "plist",
                    "csproj",
                    "fsproj",
                    "vbproj",
                    "props",
                    "targets"
                ],
                exactFileNames: [
                    "info.plist",
                    "contents.xml",
                    "androidmanifest.xml",
                    "web.config"
                ],
                syntax: .treeSitter(.xml)
            )
        ],
        languageServer: standardServer(
            defaultLanguageID: "xml",
            candidates: [
                LanguageServerExecutableCandidate(
                    identifier: "lemminx",
                    executableNames: ["lemminx"],
                    arguments: []
                )
            ]
        )
    )

    private static func standardServer(
        defaultLanguageID: String,
        languageIDOverrides: [String: String] = [:],
        candidates: [LanguageServerExecutableCandidate],
        workspaceConfiguration: [String: JSONValue] = [:],
        networkAccess: LanguageServerNetworkAccess = .none,
        supportNotes: [LanguageServerSupportNote] = []
    ) -> LanguageServerConfiguration {
        LanguageServerConfiguration(
            defaultLanguageID: defaultLanguageID,
            languageIDOverrides: languageIDOverrides,
            executableCandidates: candidates,
            semanticTokenTypes: StandardSemanticTokenLegend.tokenTypes,
            semanticTokenModifiers: StandardSemanticTokenLegend.tokenModifiers,
            workspaceConfiguration: workspaceConfiguration,
            networkAccess: networkAccess,
            supportNotes: supportNotes
        )
    }
}
