import Foundation

public struct KodBuildInfo: Equatable, Sendable {
    public let version: String
    public let build: String
    public let architecture: String

    public init(version: String, build: String, architecture: String) {
        self.version = version
        self.build = build
        self.architecture = architecture
    }

    public static func current(bundle: Bundle = .main) -> KodBuildInfo {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        return KodBuildInfo(
            version: version ?? "0.0.0",
            build: build ?? "0",
            architecture: currentArchitecture
        )
    }

    public var displayDescription: String {
        "Version \(version) (\(build)) - \(architecture)"
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        "Apple silicon"
        #elseif arch(x86_64)
        "Intel"
        #else
        "Unknown architecture"
        #endif
    }
}

