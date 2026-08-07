import CryptoKit
import Foundation

/// SHA-256 digest helpers for verifying a downloaded artifact against
/// its catalog-declared `sha256Hex` before extraction ever begins
/// (SPEC 6.5: "Verify an expected cryptographic digest before
/// extraction").
public enum Digest {
    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(ofFileAt url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return sha256Hex(of: data)
    }
}
