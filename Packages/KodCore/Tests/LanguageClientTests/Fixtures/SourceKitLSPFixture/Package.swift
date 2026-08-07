// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SourceKitLSPFixture",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SourceKitLSPFixture")
    ]
)
