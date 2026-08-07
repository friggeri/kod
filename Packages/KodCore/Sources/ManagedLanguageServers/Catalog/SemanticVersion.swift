import Foundation

/// A simple `major.minor.patch` version, used both for a catalog
/// entry's `minimumKodVersion` gate and for a managed server's own
/// `version` (so upgrade/rollback can order versions correctly rather
/// than comparing opaque strings).
public struct SemanticVersion: Codable, Sendable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(parsing string: String) {
        let components = string.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = Int(components[2]) else {
            return nil
        }
        self.init(major: major, minor: minor, patch: patch)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let parsed = SemanticVersion(parsing: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a \"major.minor.patch\" version, got \"\(raw)\""
            )
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
