import Foundation

/// The CPU architectures for which Kod publishes release artifacts.
public enum ReleaseArchitecture: String, Codable, Sendable, CaseIterable, Equatable {
    case arm64 = "arm64"
    case x86_64 = "x86_64"

    /// The running Mac's architecture, from `uname`'s machine field.
    public static var current: ReleaseArchitecture {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { rawBuffer -> String in
            guard let baseAddress = rawBuffer.baseAddress else {
                return ""
            }
            let pointer = baseAddress.assumingMemoryBound(to: CChar.self)
            return String(cString: pointer)
        }
        switch machine {
        case "arm64":
            return .arm64
        default:
            return .x86_64
        }
    }
}
