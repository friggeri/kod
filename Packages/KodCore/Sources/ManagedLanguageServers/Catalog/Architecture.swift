import Foundation

/// The two CPU architectures Kod ships managed-install artifacts for
/// (SPEC "Architecture priority: Apple silicon first; Intel
/// best-effort" / SPEC 6.5 "Keep Apple-silicon and Intel artifacts
/// separate and identify unsupported combinations clearly"). A managed
/// server's catalog entry may simply omit one of these two keys, which
/// `ManagedInstallController` reports as a clearly-identified
/// unsupported combination rather than attempting a mismatched
/// download.
public enum ManagedInstallArchitecture: String, Codable, Sendable, CaseIterable, Equatable {
    case arm64
    case x86_64

    /// The running Mac's architecture, from `uname`'s machine field —
    /// never inferred from a repository-provided value.
    public static var current: ManagedInstallArchitecture {
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
            // Every current Intel Mac reports "x86_64"; treat any other
            // unrecognized machine string as x86_64's best-effort tier
            // rather than crashing, since this is only ever used to
            // pick a download, never for a security decision (the
            // downloaded artifact's own digest is still verified).
            return .x86_64
        }
    }
}
