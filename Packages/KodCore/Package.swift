// swift-tools-version: 6.0

import PackageDescription

let grammarCSettings: [CSetting] = [
    .headerSearchPath(".")
]

let package = Package(
    name: "KodCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "KodCore", targets: ["KodCore"]),
        .library(name: "SettingsCore", targets: ["SettingsCore"]),
        .library(name: "SourceModel", targets: ["SourceModel"]),
        .library(name: "SourceIO", targets: ["SourceIO"]),
        .library(name: "CodeViewport", targets: ["CodeViewport"]),
        .library(name: "WorkspaceCore", targets: ["WorkspaceCore"]),
        .library(name: "SyntaxCore", targets: ["SyntaxCore"]),
        .library(name: "ThemeCore", targets: ["ThemeCore"]),
        .library(name: "TextDecorationModel", targets: ["TextDecorationModel"]),
        .library(name: "FontCore", targets: ["FontCore"]),
        .library(name: "SearchCore", targets: ["SearchCore"]),
        .library(name: "LanguageClient", targets: ["LanguageClient"]),
        .library(name: "LanguageAdapters", targets: ["LanguageAdapters"]),
        .library(name: "GitCore", targets: ["GitCore"]),
        .library(name: "PreviewCore", targets: ["PreviewCore"]),
        .library(name: "DiagnosticsCore", targets: ["DiagnosticsCore"]),
        .executable(name: "KodFixtureGenerator", targets: ["KodFixtureGenerator"]),
        .executable(name: "FakeLanguageServer", targets: ["FakeLanguageServer"]),
        .executable(name: "GitProcessSpy", targets: ["GitProcessSpy"]),
        .executable(name: "KodMemoryBenchmark", targets: ["KodMemoryBenchmark"])
    ],
    targets: [
        .target(
            name: "KodCore",
            dependencies: [
                "SettingsCore",
                "SourceModel",
                "SourceIO",
                "CodeViewport",
                "WorkspaceCore",
                "SyntaxCore",
                "ThemeCore",
                "TextDecorationModel",
                "FontCore",
                "SearchCore",
                "LanguageClient",
                "LanguageAdapters",
                "GitCore",
                "PreviewCore",
                "DiagnosticsCore"
            ]
        ),
        .target(name: "SettingsCore"),
        .target(name: "SourceModel"),
        .target(name: "SourceIO", dependencies: ["SourceModel"]),
        .target(
            name: "CodeViewport",
            dependencies: [
                "SourceModel",
                "SourceIO",
                "SyntaxCore",
                "ThemeCore",
                "TextDecorationModel",
                "LanguageClient",
                "FontCore"
            ]
        ),
        .target(name: "WorkspaceCore", dependencies: ["SourceModel", "SettingsCore"]),
        .target(
            name: "SearchCore",
            resources: [
                .copy("Resources/ripgrep")
            ]
        ),
        .target(name: "KodFixtureSupport"),
        .target(name: "FuzzSupport"),
        .executableTarget(
            name: "KodFixtureGenerator",
            dependencies: ["KodFixtureSupport"]
        ),

        // MARK: - cmark-gfm (vendored, pinned to 0.29.0.gfm.13).
        .target(
            name: "CCMarkGFM",
            path: "Sources/CCMarkGFM",
            exclude: ["LICENSE-cmark-gfm.txt"],
            sources: [
                "arena.c", "blocks.c", "buffer.c", "cmark.c", "cmark_ctype.c",
                "commonmark.c", "footnotes.c", "houdini_href_e.c",
                "houdini_html_e.c", "houdini_html_u.c", "html.c", "inlines.c",
                "iterator.c", "latex.c", "linked_list.c", "man.c", "map.c",
                "node.c", "plaintext.c", "plugin.c", "references.c", "registry.c",
                "render.c", "scanners.c", "syntax_extension.c", "utf8.c", "xml.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .define("CMARK_GFM_STATIC_DEFINE")
            ]
        ),
        .target(
            name: "CCMarkGFMExtensions",
            dependencies: ["CCMarkGFM"],
            path: "Sources/CCMarkGFMExtensions",
            sources: [
                "autolink.c", "core-extensions.c", "ext_scanners.c",
                "kod-cmark-gfm.c", "strikethrough.c", "table.c", "tagfilter.c",
                "tasklist.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .define("CMARK_GFM_STATIC_DEFINE"),
                .define("CMARK_GFM_EXTENSIONS_STATIC_DEFINE")
            ]
        ),

        // MARK: - Tree-sitter runtime (vendored, pinned to tree-sitter v0.26.11).
        .target(
            name: "CTreeSitter",
            path: "Sources/CTreeSitter",
            exclude: [
                "LICENSE-tree-sitter.txt",
                "unicode/LICENSE"
            ],
            sources: ["lib.c"],
            publicHeadersPath: "include"
        ),

        // MARK: - Pinned Tree-sitter grammars (compiled in; no runtime grammar loading).
        .target(
            name: "CTreeSitterSwift",
            dependencies: ["CTreeSitter"],
            path: "Sources/CTreeSitterSwift",
            exclude: ["LICENSE-upstream.txt"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: grammarCSettings
        ),
        .target(
            name: "CTreeSitterTypeScript",
            dependencies: ["CTreeSitter"],
            path: "Sources/CTreeSitterTypeScript",
            exclude: ["LICENSE-upstream.txt"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: grammarCSettings
        ),
        .target(
            name: "CTreeSitterTSX",
            dependencies: ["CTreeSitter"],
            path: "Sources/CTreeSitterTSX",
            exclude: ["LICENSE-upstream.txt"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: grammarCSettings
        ),
        .target(
            name: "CTreeSitterJavaScript",
            dependencies: ["CTreeSitter"],
            path: "Sources/CTreeSitterJavaScript",
            exclude: ["LICENSE-upstream.txt"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: grammarCSettings
        ),
        .target(
            name: "CTreeSitterHTML",
            dependencies: ["CTreeSitter"],
            path: "Sources/CTreeSitterHTML",
            exclude: ["LICENSE-upstream.txt"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: grammarCSettings
        ),
        .target(
            name: "CTreeSitterCSS",
            dependencies: ["CTreeSitter"],
            path: "Sources/CTreeSitterCSS",
            exclude: ["LICENSE-upstream.txt"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: grammarCSettings
        ),
        .target(
            name: "CTreeSitterPython",
            dependencies: ["CTreeSitter"],
            path: "Sources/CTreeSitterPython",
            exclude: ["LICENSE-upstream.txt"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: grammarCSettings
        ),
        .target(
            name: "CTreeSitterRust",
            dependencies: ["CTreeSitter"],
            path: "Sources/CTreeSitterRust",
            exclude: ["LICENSE-upstream.txt"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: grammarCSettings
        ),
        .target(
            name: "CTreeSitterBash",
            dependencies: ["CTreeSitter"],
            path: "Sources/CTreeSitterBash",
            exclude: ["LICENSE-upstream.txt"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: grammarCSettings
        ),
        .target(
            name: "CTreeSitterJSON",
            dependencies: ["CTreeSitter"],
            path: "Sources/CTreeSitterJSON",
            exclude: ["LICENSE-upstream.txt"],
            sources: ["parser.c"],
            publicHeadersPath: "include",
            cSettings: grammarCSettings
        ),
        .target(
            name: "CTreeSitterYAML",
            dependencies: ["CTreeSitter"],
            path: "Sources/CTreeSitterYAML",
            exclude: [
                "LICENSE-upstream.txt",
                "schema.core.c",
                "schema.json.c",
                "schema.legacy.c"
            ],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: grammarCSettings
        ),
        .target(
            name: "CTreeSitterTOML",
            dependencies: ["CTreeSitter"],
            path: "Sources/CTreeSitterTOML",
            exclude: ["LICENSE-upstream.txt"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: grammarCSettings
        ),
        .target(
            name: "CTreeSitterMarkdown",
            dependencies: ["CTreeSitter"],
            path: "Sources/CTreeSitterMarkdown",
            exclude: ["LICENSE-upstream.txt"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: grammarCSettings
        ),
        .target(
            name: "CTreeSitterMarkdownInline",
            dependencies: ["CTreeSitter"],
            path: "Sources/CTreeSitterMarkdownInline",
            exclude: ["LICENSE-upstream.txt"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: grammarCSettings
        ),
        .target(
            name: "CTreeSitterC",
            dependencies: ["CTreeSitter"],
            path: "Sources/CTreeSitterC",
            exclude: ["LICENSE-upstream.txt"],
            sources: ["parser.c"],
            publicHeadersPath: "include",
            cSettings: grammarCSettings
        ),
        .target(
            name: "CTreeSitterGo",
            dependencies: ["CTreeSitter"],
            path: "Sources/CTreeSitterGo",
            exclude: ["LICENSE-upstream.txt"],
            sources: ["parser.c"],
            publicHeadersPath: "include",
            cSettings: grammarCSettings
        ),
        .target(
            name: "CTreeSitterJava",
            dependencies: ["CTreeSitter"],
            path: "Sources/CTreeSitterJava",
            exclude: ["LICENSE-upstream.txt"],
            sources: ["parser.c"],
            publicHeadersPath: "include",
            cSettings: grammarCSettings
        ),
        .target(
            name: "CTreeSitterRuby",
            dependencies: ["CTreeSitter"],
            path: "Sources/CTreeSitterRuby",
            exclude: ["LICENSE-upstream.txt"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: grammarCSettings
        ),
        .target(
            name: "CTreeSitterLua",
            dependencies: ["CTreeSitter"],
            path: "Sources/CTreeSitterLua",
            exclude: ["LICENSE-upstream.txt"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: grammarCSettings
        ),
        .target(
            name: "CTreeSitterGraphQL",
            dependencies: ["CTreeSitter"],
            path: "Sources/CTreeSitterGraphQL",
            exclude: ["LICENSE-upstream.txt"],
            sources: ["parser.c"],
            publicHeadersPath: "include",
            cSettings: grammarCSettings
        ),
        .target(
            name: "CTreeSitterXML",
            dependencies: ["CTreeSitter"],
            path: "Sources/CTreeSitterXML",
            exclude: ["LICENSE-upstream.txt"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: grammarCSettings
        ),

        .target(
            name: "SyntaxCore",
            dependencies: [
                "SourceModel",
                "CTreeSitter",
                "CTreeSitterSwift",
                "CTreeSitterTypeScript",
                "CTreeSitterTSX",
                "CTreeSitterJavaScript",
                "CTreeSitterHTML",
                "CTreeSitterCSS",
                "CTreeSitterPython",
                "CTreeSitterRust",
                "CTreeSitterBash",
                "CTreeSitterJSON",
                "CTreeSitterYAML",
                "CTreeSitterTOML",
                "CTreeSitterMarkdown",
                "CTreeSitterMarkdownInline",
                "CTreeSitterC",
                "CTreeSitterGo",
                "CTreeSitterJava",
                "CTreeSitterRuby",
                "CTreeSitterLua",
                "CTreeSitterGraphQL",
                "CTreeSitterXML"
            ],
            resources: [
                .copy("Resources/Queries")
            ]
        ),

        // Dependency-light, platform-neutral decoration value model: portable
        // colors plus the versioned layer/run types every producer of
        // decorations speaks. No AppKit, no theme schema, no parser, no LSP.
        .target(name: "TextDecorationModel"),

        .target(name: "ThemeCore", dependencies: ["SettingsCore", "TextDecorationModel"]),
        .target(name: "FontCore", dependencies: ["SettingsCore"]),

        // Platform-neutral LSP client: workspace trust and identity enter
        // through injected capabilities (`WorkspaceLaunchAuthorization`,
        // an explicit root URL), never through WorkspaceCore.
        .target(
            name: "LanguageClient",
            dependencies: ["SourceModel"]
        ),
        .target(
            name: "LanguageAdapters",
            dependencies: [
                "DiagnosticsCore",
                "LanguageClient",
                "SettingsCore",
                "SourceModel",
                "SyntaxCore",
                "WorkspaceCore"
            ]
        ),
        .executableTarget(
            name: "FakeLanguageServer",
            dependencies: ["LanguageClient"]
        ),
        .target(name: "GitCore"),
        .executableTarget(
            name: "GitProcessSpy"
        ),
        .target(
            name: "PreviewCore",
            dependencies: [
                "SourceModel",
                "SourceIO",
                "SyntaxCore",
                "ThemeCore",
                "TextDecorationModel",
                "CCMarkGFMExtensions"
            ]
        ),
        .target(name: "DiagnosticsCore", dependencies: ["SettingsCore"]),
        .executableTarget(
            name: "KodMemoryBenchmark",
            dependencies: ["WorkspaceCore", "SourceModel", "SyntaxCore"]
        ),

        .testTarget(
            name: "KodCoreTests",
            dependencies: ["KodCore"]
        ),
        .testTarget(
            name: "SettingsCoreTests",
            dependencies: ["SettingsCore"]
        ),
        .testTarget(
            name: "SourceModelTests",
            dependencies: ["SourceModel", "FuzzSupport"]
        ),
        .testTarget(
            name: "SourceIOTests",
            dependencies: ["SourceIO", "SourceModel"]
        ),
        .testTarget(
            name: "CodeViewportTests",
            dependencies: [
                "CodeViewport",
                "SourceModel",
                "SourceIO",
                "SyntaxCore",
                "ThemeCore",
                "TextDecorationModel",
                "LanguageClient",
                "FontCore",
                "FuzzSupport"
            ]
        ),
        .testTarget(
            name: "WorkspaceCoreTests",
            dependencies: ["WorkspaceCore", "SourceModel", "KodFixtureSupport", "SettingsCore", "FuzzSupport"]
        ),
        .testTarget(
            name: "KodFixtureSupportTests",
            dependencies: ["KodFixtureSupport"]
        ),
        .testTarget(
            name: "SyntaxCoreTests",
            dependencies: ["SyntaxCore", "SourceModel", "KodFixtureSupport"],
            resources: [
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "TextDecorationModelTests",
            dependencies: ["TextDecorationModel"]
        ),
        .testTarget(
            name: "ThemeCoreTests",
            dependencies: ["ThemeCore", "TextDecorationModel", "SettingsCore", "FuzzSupport"],
            resources: [
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "FontCoreTests",
            dependencies: ["FontCore", "SettingsCore"]
        ),
        .testTarget(
            name: "SearchCoreTests",
            dependencies: ["SearchCore", "KodFixtureSupport"],
            resources: [
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "LanguageClientTests",
            dependencies: ["LanguageClient", "SourceModel", "SourceIO", "FakeLanguageServer", "FuzzSupport"],
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "LanguageAdaptersTests",
            dependencies: ["LanguageAdapters", "LanguageClient", "SettingsCore", "SourceModel", "SourceIO", "WorkspaceCore", "FakeLanguageServer"],
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "GitCoreTests",
            dependencies: ["GitCore", "SourceModel", "SyntaxCore", "ThemeCore", "GitProcessSpy", "FuzzSupport"]
        ),
        .testTarget(
            name: "PreviewCoreTests",
            dependencies: ["PreviewCore", "SourceModel", "SyntaxCore", "ThemeCore", "FuzzSupport"],
            resources: [
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "DiagnosticsCoreTests",
            dependencies: ["DiagnosticsCore", "SettingsCore", "FuzzSupport"]
        ),
        .testTarget(
            name: "PerformanceSuiteTests",
            dependencies: [
                "SourceModel",
                "CodeViewport",
                "SyntaxCore",
                "ThemeCore",
                "TextDecorationModel",
                "FontCore",
                "WorkspaceCore",
                "GitCore",
                "SearchCore",
                "SettingsCore",
                "DiagnosticsCore",
                "KodFixtureSupport"
            ]
        )
    ]
)
