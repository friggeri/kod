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
        .library(name: "SourceModel", targets: ["SourceModel"]),
        .library(name: "CodeViewport", targets: ["CodeViewport"]),
        .library(name: "WorkspaceCore", targets: ["WorkspaceCore"]),
        .library(name: "SyntaxCore", targets: ["SyntaxCore"]),
        .library(name: "ThemeCore", targets: ["ThemeCore"]),
        .library(name: "FontCore", targets: ["FontCore"]),
        .library(name: "SearchCore", targets: ["SearchCore"]),
        .library(name: "LanguageClient", targets: ["LanguageClient"]),
        .library(name: "LanguageAdapters", targets: ["LanguageAdapters"]),
        .library(name: "ManagedLanguageServers", targets: ["ManagedLanguageServers"]),
        .library(name: "GitCore", targets: ["GitCore"]),
        .library(name: "PreviewCore", targets: ["PreviewCore"]),
        .library(name: "DiagnosticsCore", targets: ["DiagnosticsCore"]),
        .library(name: "UpdaterCore", targets: ["UpdaterCore"]),
        .executable(name: "KodFixtureGenerator", targets: ["KodFixtureGenerator"]),
        .executable(name: "FakeLanguageServer", targets: ["FakeLanguageServer"]),
        .executable(name: "ManagedCatalogTool", targets: ["ManagedCatalogTool"]),
        .executable(name: "GitProcessSpy", targets: ["GitProcessSpy"]),
        .executable(name: "UpdateFeedTool", targets: ["UpdateFeedTool"]),
        .executable(name: "KodMemoryBenchmark", targets: ["KodMemoryBenchmark"])
    ],
    targets: [
        .target(name: "KodCore"),
        .target(name: "SourceModel"),
        .target(
            name: "CodeViewport",
            dependencies: ["SourceModel", "SyntaxCore", "ThemeCore", "FontCore"]
        ),
        .target(name: "WorkspaceCore", dependencies: ["SourceModel", "DiagnosticsCore"]),
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
            name: "SyntaxCore",
            dependencies: [
                "SourceModel",
                "ThemeCore",
                "CTreeSitter",
                "CTreeSitterSwift",
                "CTreeSitterTypeScript",
                "CTreeSitterTSX",
                "CTreeSitterJavaScript",
                "CTreeSitterHTML",
                "CTreeSitterCSS",
                "CTreeSitterPython",
                "CTreeSitterRust"
            ],
            resources: [
                .copy("Resources/Queries")
            ]
        ),

        .target(name: "ThemeCore", dependencies: ["DiagnosticsCore"]),
        .target(name: "FontCore", dependencies: ["DiagnosticsCore"]),

        .target(
            name: "LanguageClient",
            dependencies: ["SourceModel", "SyntaxCore", "ThemeCore", "WorkspaceCore"]
        ),
        .target(
            name: "LanguageAdapters",
            dependencies: ["LanguageClient", "SourceModel", "WorkspaceCore", "ManagedLanguageServers"]
        ),
        .target(
            name: "ManagedLanguageServers",
            dependencies: ["WorkspaceCore"]
        ),
        .executableTarget(
            name: "FakeLanguageServer",
            dependencies: ["LanguageClient"]
        ),
        .executableTarget(
            name: "ManagedCatalogTool",
            dependencies: ["ManagedLanguageServers"]
        ),
        .target(
            name: "GitCore",
            dependencies: ["SourceModel", "WorkspaceCore", "SyntaxCore", "ThemeCore"]
        ),
        .executableTarget(
            name: "GitProcessSpy"
        ),
        .target(
            name: "PreviewCore",
            dependencies: ["SourceModel", "SyntaxCore", "ThemeCore"]
        ),
        .target(
            name: "DiagnosticsCore"
        ),
        .target(
            name: "UpdaterCore",
            dependencies: ["ManagedLanguageServers"]
        ),
        .executableTarget(
            name: "UpdateFeedTool",
            dependencies: ["UpdaterCore"]
        ),
        .executableTarget(
            name: "KodMemoryBenchmark",
            dependencies: ["WorkspaceCore", "SourceModel", "SyntaxCore"]
        ),

        .testTarget(
            name: "KodCoreTests",
            dependencies: ["KodCore"]
        ),
        .testTarget(
            name: "SourceModelTests",
            dependencies: ["SourceModel", "FuzzSupport"]
        ),
        .testTarget(
            name: "CodeViewportTests",
            dependencies: ["CodeViewport", "SourceModel", "SyntaxCore", "ThemeCore", "FontCore", "FuzzSupport"]
        ),
        .testTarget(
            name: "WorkspaceCoreTests",
            dependencies: ["WorkspaceCore", "SourceModel", "KodFixtureSupport", "DiagnosticsCore", "FuzzSupport"]
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
            name: "ThemeCoreTests",
            dependencies: ["ThemeCore", "DiagnosticsCore", "FuzzSupport"],
            resources: [
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "FontCoreTests",
            dependencies: ["FontCore", "DiagnosticsCore"]
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
            dependencies: ["LanguageClient", "SourceModel", "SyntaxCore", "ThemeCore", "WorkspaceCore", "FakeLanguageServer", "FuzzSupport"],
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "LanguageAdaptersTests",
            dependencies: ["LanguageAdapters", "LanguageClient", "SourceModel", "WorkspaceCore", "ManagedLanguageServers", "FakeLanguageServer"],
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "ManagedLanguageServersTests",
            dependencies: ["ManagedLanguageServers", "WorkspaceCore", "LanguageClient", "FakeLanguageServer", "FuzzSupport"],
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "GitCoreTests",
            dependencies: ["GitCore", "SourceModel", "WorkspaceCore", "SyntaxCore", "ThemeCore", "GitProcessSpy", "FuzzSupport"]
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
            dependencies: ["DiagnosticsCore", "FuzzSupport"]
        ),
        .testTarget(
            name: "UpdaterCoreTests",
            dependencies: ["UpdaterCore", "ManagedLanguageServers"]
        ),
        .testTarget(
            name: "PerformanceSuiteTests",
            dependencies: [
                "SourceModel",
                "CodeViewport",
                "SyntaxCore",
                "ThemeCore",
                "FontCore",
                "WorkspaceCore",
                "GitCore",
                "SearchCore",
                "DiagnosticsCore",
                "KodFixtureSupport"
            ]
        )
    ]
)
