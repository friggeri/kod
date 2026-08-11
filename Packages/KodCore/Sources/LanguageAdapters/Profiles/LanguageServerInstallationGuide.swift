import Foundation

/// One concrete, copy-pasteable way to install a shipped default
/// profile's language server (e.g. "npm", "pnpm", "Homebrew"). Kod never
/// executes any of these commands; it only ever displays them as
/// selectable, monospaced text and copies the exact string to the
/// pasteboard on request (SPEC: Kod must not run package managers or
/// shell commands on the user's behalf).
///
/// `id` and `label` are stable, nonlocalized brand/tool names (matching
/// the tool's own branding, e.g. "npm", "pnpm", "Homebrew", "rustup") so
/// they read identically in every locale and can be used as stable
/// accessibility-identifier suffixes.
public struct LanguageServerInstallCommandOption: Sendable, Equatable {
    public let id: String
    public let label: String
    /// The exact, executable-compatible command lines to show and copy.
    /// Each entry is a single, nonempty, newline-free display line (a
    /// multi-step recipe is represented as multiple entries, never a
    /// single string containing embedded newlines).
    public let commandLines: [String]

    public init(id: String, label: String, commandLines: [String]) {
        self.id = id
        self.label = label
        self.commandLines = commandLines
    }
}

/// Curated, shipped-only installation guidance for one default language
/// profile: zero or more copyable command options (a profile like XML
/// may have none, only official documentation) plus a link to that
/// server's own official installation documentation.
public struct LanguageServerInstallationGuide: Sendable, Equatable {
    public let profileIdentifier: String
    public let commandOptions: [LanguageServerInstallCommandOption]
    public let documentationURL: URL

    public init(
        profileIdentifier: String,
        commandOptions: [LanguageServerInstallCommandOption],
        documentationURL: URL
    ) {
        self.profileIdentifier = profileIdentifier
        self.commandOptions = commandOptions
        self.documentationURL = documentationURL
    }
}

/// A curated, hardcoded, shipped-only catalog of installation guidance
/// for every default (non-custom) language profile that has an optional
/// language server. This is deliberately **not** part of the Codable
/// `LanguageProfile`/`LanguageServerConfiguration` model and is never
/// persisted, edited, or derived from user-editable state: it is public
/// static data compiled into the app, keyed by the stable default
/// profile identifier (e.g. `"swift"`, `"typescript"`).
///
/// Callers that surface this guidance in the UI must additionally
/// require `profile.origin == .default` before doing a catalog lookup
/// (see `LanguageServerInstallationGuide.guide(for:)`) so a custom
/// profile can never gain installation guidance by reusing or spoofing
/// a default profile's identifier/metadata.
public enum DefaultLanguageServerInstallationGuides {
    public static let all: [String: LanguageServerInstallationGuide] = {
        let guides: [LanguageServerInstallationGuide] = [
            swift,
            typeScript,
            html,
            css,
            json,
            python,
            rust,
            shellscript,
            markdown,
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
        return Dictionary(
            uniqueKeysWithValues: guides.map { ($0.profileIdentifier, $0) }
        )
    }()

    /// Returns the shipped guidance for `profile`, but only when it is a
    /// default (non-custom) profile. Custom profiles never resolve
    /// guidance here, even if their `identifier` happens to collide with
    /// a default profile's identifier or a caller reuses default
    /// metadata, because `origin` is checked explicitly rather than
    /// trusting `identifier` alone.
    public static func guide(
        for profile: LanguageProfile
    ) -> LanguageServerInstallationGuide? {
        guard profile.origin == .default else {
            return nil
        }
        return all[profile.identifier]
    }

    /// Builds an HTTPS-only `URL` from a hardcoded literal, without a
    /// force unwrap. Every entry in this catalog is compiled-in static
    /// data, but this still validates both that the string parses as a
    /// URL and that its scheme is `https`, `preconditionFailure`-ing at
    /// startup (loudly, in debug and release) rather than silently
    /// shipping a broken or non-HTTPS documentation link.
    private static func httpsURL(_ string: String) -> URL {
        guard let url = URL(string: string), url.scheme == "https" else {
            preconditionFailure(
                "Invalid HTTPS installation documentation URL: \(string)"
            )
        }
        return url
    }

    private static func npmAndPNPM(
        packages: [String]
    ) -> [LanguageServerInstallCommandOption] {
        let npmPackages = packages.joined(separator: " ")
        let pnpmPackages = packages.joined(separator: ",")
        return [
            LanguageServerInstallCommandOption(
                id: "npm",
                label: "npm",
                commandLines: ["npm install -g \(npmPackages)"]
            ),
            LanguageServerInstallCommandOption(
                id: "pnpm",
                label: "pnpm",
                commandLines: ["pnpm add -g \(pnpmPackages)"]
            )
        ]
    }

    // MARK: - Guides

    static let swift = LanguageServerInstallationGuide(
        profileIdentifier: "swift",
        commandOptions: [
            LanguageServerInstallCommandOption(
                id: "xcode-select",
                label: "Xcode Command Line Tools",
                commandLines: ["xcode-select --install"]
            )
        ],
        documentationURL: httpsURL(
            "https://github.com/swiftlang/sourcekit-lsp"
        )
    )

    static let typeScript = LanguageServerInstallationGuide(
        profileIdentifier: "typescript",
        commandOptions: npmAndPNPM(
            packages: ["typescript-language-server", "typescript"]
        ),
        documentationURL: httpsURL(
            "https://github.com/typescript-language-server/typescript-language-server"
        )
    )

    static let html = LanguageServerInstallationGuide(
        profileIdentifier: "html",
        commandOptions: npmAndPNPM(packages: ["vscode-langservers-extracted"]),
        documentationURL: httpsURL(
            "https://github.com/hrsh7th/vscode-langservers-extracted"
        )
    )

    static let css = LanguageServerInstallationGuide(
        profileIdentifier: "css",
        commandOptions: npmAndPNPM(packages: ["vscode-langservers-extracted"]),
        documentationURL: httpsURL(
            "https://github.com/hrsh7th/vscode-langservers-extracted"
        )
    )

    static let json = LanguageServerInstallationGuide(
        profileIdentifier: "json",
        commandOptions: npmAndPNPM(packages: ["vscode-langservers-extracted"]),
        documentationURL: httpsURL(
            "https://github.com/hrsh7th/vscode-langservers-extracted"
        )
    )

    static let python = LanguageServerInstallationGuide(
        profileIdentifier: "python",
        commandOptions: npmAndPNPM(packages: ["pyright"]),
        documentationURL: httpsURL(
            "https://microsoft.github.io/pyright/#/installation"
        )
    )

    static let rust = LanguageServerInstallationGuide(
        profileIdentifier: "rust",
        commandOptions: [
            LanguageServerInstallCommandOption(
                id: "rustup",
                label: "rustup",
                commandLines: ["rustup component add rust-analyzer"]
            )
        ],
        documentationURL: httpsURL(
            "https://rust-analyzer.github.io/book/installation.html"
        )
    )

    static let shellscript = LanguageServerInstallationGuide(
        profileIdentifier: "shellscript",
        commandOptions: npmAndPNPM(packages: ["bash-language-server"]),
        documentationURL: httpsURL(
            "https://github.com/bash-lsp/bash-language-server"
        )
    )

    static let markdown = LanguageServerInstallationGuide(
        profileIdentifier: "markdown",
        commandOptions: [
            LanguageServerInstallCommandOption(
                id: "homebrew",
                label: "Homebrew",
                commandLines: ["brew install marksman"]
            )
        ],
        documentationURL: httpsURL(
            "https://github.com/artempyanykh/marksman"
        )
    )

    static let yaml = LanguageServerInstallationGuide(
        profileIdentifier: "yaml",
        commandOptions: [
            LanguageServerInstallCommandOption(
                id: "npm",
                label: "npm",
                commandLines: ["npm install -g yaml-language-server"]
            ),
            LanguageServerInstallCommandOption(
                id: "pnpm",
                label: "pnpm",
                commandLines: [
                    "pnpm --config.node-linker=hoisted add -g yaml-language-server"
                ]
            )
        ],
        documentationURL: httpsURL(
            "https://github.com/redhat-developer/yaml-language-server"
        )
    )

    static let toml = LanguageServerInstallationGuide(
        profileIdentifier: "toml",
        commandOptions: [
            LanguageServerInstallCommandOption(
                id: "homebrew",
                label: "Homebrew",
                commandLines: ["brew install tombi"]
            )
        ],
        documentationURL: httpsURL("https://github.com/tombi-toml/tombi")
    )

    static let c = LanguageServerInstallationGuide(
        profileIdentifier: "c",
        commandOptions: [
            LanguageServerInstallCommandOption(
                id: "xcode-select",
                label: "Xcode Command Line Tools",
                commandLines: ["xcode-select --install"]
            )
        ],
        documentationURL: httpsURL("https://clangd.llvm.org/installation")
    )

    static let go = LanguageServerInstallationGuide(
        profileIdentifier: "go",
        commandOptions: [
            LanguageServerInstallCommandOption(
                id: "go-install",
                label: "go install",
                commandLines: [
                    "go install golang.org/x/tools/gopls@latest"
                ]
            )
        ],
        documentationURL: httpsURL(
            "https://github.com/golang/tools/blob/master/gopls/README.md"
        )
    )

    static let java = LanguageServerInstallationGuide(
        profileIdentifier: "java",
        commandOptions: [
            LanguageServerInstallCommandOption(
                id: "homebrew",
                label: "Homebrew",
                commandLines: ["brew install jdtls"]
            )
        ],
        documentationURL: httpsURL(
            "https://github.com/eclipse-jdtls/eclipse.jdt.ls"
        )
    )

    static let ruby = LanguageServerInstallationGuide(
        profileIdentifier: "ruby",
        commandOptions: [
            LanguageServerInstallCommandOption(
                id: "rubygems",
                label: "RubyGems",
                commandLines: ["gem install ruby-lsp"]
            )
        ],
        documentationURL: httpsURL("https://github.com/Shopify/ruby-lsp")
    )

    static let lua = LanguageServerInstallationGuide(
        profileIdentifier: "lua",
        commandOptions: [
            LanguageServerInstallCommandOption(
                id: "homebrew",
                label: "Homebrew",
                commandLines: ["brew install lua-language-server"]
            )
        ],
        documentationURL: httpsURL("https://luals.github.io/")
    )

    static let graphql = LanguageServerInstallationGuide(
        profileIdentifier: "graphql",
        commandOptions: npmAndPNPM(
            packages: ["graphql-language-service-cli"]
        ),
        documentationURL: httpsURL(
            "https://github.com/graphql/graphiql/tree/main/packages/graphql-language-service-cli"
        )
    )

    static let xml = LanguageServerInstallationGuide(
        profileIdentifier: "xml",
        commandOptions: [],
        documentationURL: httpsURL(
            "https://github.com/eclipse-lemminx/lemminx/releases"
        )
    )
}
