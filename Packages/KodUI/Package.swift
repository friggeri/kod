// swift-tools-version: 6.0

import PackageDescription

// `KodUI` is the presentation half of Kod's package split: reusable
// AppKit building blocks plus the stable search, preview, Git, and
// editor feature surfaces. `KodCore` stays free of presentation code;
// this package is the only place allowed to depend on both a portable
// `KodCore` value type and AppKit.
let package = Package(
    name: "KodUI",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "KodUIComponents", targets: ["KodUIComponents"]),
        .library(name: "SearchUI", targets: ["SearchUI"]),
        .library(name: "PreviewUI", targets: ["PreviewUI"]),
        .library(name: "GitUI", targets: ["GitUI"]),
        .library(name: "EditorUI", targets: ["EditorUI"])
    ],
    dependencies: [
        .package(path: "../KodCore")
    ],
    targets: [
        // `TextDecorationModel` owns the portable `ThemeColor` value the
        // AppKit bridge converts. `AppearanceCenter` additionally observes
        // the injected ThemeCore/FontCore SettingsCore stores; ownership
        // remains with AppEnvironment rather than any static setting.
        .target(
            name: "KodUIComponents",
            dependencies: [
                .product(name: "FontCore", package: "KodCore"),
                .product(name: "SettingsCore", package: "KodCore"),
                .product(name: "ThemeCore", package: "KodCore"),
                .product(name: "TextDecorationModel", package: "KodCore")
            ],
            resources: [
                // `.copy` keeps `MaterialIcons/icons/<asset>.svg` intact:
                // the manifest addresses every asset by that exact
                // relative path, so the directory structure must survive
                // into the bundle rather than being flattened.
                .copy("MaterialIcons"),
                // `.process` lets SwiftPM compile this target's localized
                // resources; each feature target below owns its own
                // String Catalog in the same way.
                .process("Resources")
            ]
        ),
        .target(
            name: "SearchUI",
            dependencies: [
                "KodUIComponents",
                .product(name: "DiagnosticsCore", package: "KodCore"),
                .product(name: "SearchCore", package: "KodCore")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "PreviewUI",
            dependencies: [
                "KodUIComponents",
                .product(name: "DiagnosticsCore", package: "KodCore"),
                .product(name: "FontCore", package: "KodCore"),
                .product(name: "PreviewCore", package: "KodCore"),
                .product(name: "ThemeCore", package: "KodCore")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "GitUI",
            dependencies: [
                "KodUIComponents",
                .product(name: "CodeViewport", package: "KodCore"),
                .product(name: "GitCore", package: "KodCore"),
                .product(name: "SettingsCore", package: "KodCore"),
                .product(name: "SourceModel", package: "KodCore"),
                .product(name: "ThemeCore", package: "KodCore")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "EditorUI",
            dependencies: [
                "KodUIComponents",
                "PreviewUI",
                "GitUI",
                .product(name: "CodeViewport", package: "KodCore"),
                .product(name: "FontCore", package: "KodCore"),
                .product(name: "GitCore", package: "KodCore"),
                .product(name: "LanguageClient", package: "KodCore"),
                .product(name: "PreviewCore", package: "KodCore"),
                .product(name: "SettingsCore", package: "KodCore"),
                .product(name: "SourceModel", package: "KodCore"),
                .product(name: "SyntaxCore", package: "KodCore"),
                .product(name: "ThemeCore", package: "KodCore"),
                .product(name: "WorkspaceCore", package: "KodCore")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "KodUIComponentsTests",
            dependencies: [
                "KodUIComponents",
                .product(name: "FontCore", package: "KodCore"),
                .product(name: "SettingsCore", package: "KodCore"),
                .product(name: "ThemeCore", package: "KodCore"),
                .product(name: "TextDecorationModel", package: "KodCore")
            ]
        ),
        .testTarget(
            name: "SearchUITests",
            dependencies: [
                "SearchUI",
                "KodUIComponents"
            ]
        ),
        .testTarget(
            name: "PreviewUITests",
            dependencies: [
                "PreviewUI",
                "KodUIComponents",
                .product(name: "FontCore", package: "KodCore"),
                .product(name: "PreviewCore", package: "KodCore"),
                .product(name: "ThemeCore", package: "KodCore")
            ]
        ),
        .testTarget(
            name: "GitUITests",
            dependencies: [
                "GitUI",
                "KodUIComponents",
                .product(name: "CodeViewport", package: "KodCore"),
                .product(name: "FontCore", package: "KodCore"),
                .product(name: "GitCore", package: "KodCore"),
                .product(name: "SourceModel", package: "KodCore"),
                .product(name: "ThemeCore", package: "KodCore")
            ]
        ),
        .testTarget(
            name: "EditorUITests",
            dependencies: [
                "EditorUI",
                "GitUI",
                "PreviewUI",
                "KodUIComponents",
                .product(name: "CodeViewport", package: "KodCore"),
                .product(name: "FontCore", package: "KodCore"),
                .product(name: "GitCore", package: "KodCore"),
                .product(name: "LanguageClient", package: "KodCore"),
                .product(name: "PreviewCore", package: "KodCore"),
                .product(name: "SourceIO", package: "KodCore"),
                .product(name: "SourceModel", package: "KodCore"),
                .product(name: "ThemeCore", package: "KodCore"),
                .product(name: "WorkspaceCore", package: "KodCore")
            ]
        )
    ]
)
