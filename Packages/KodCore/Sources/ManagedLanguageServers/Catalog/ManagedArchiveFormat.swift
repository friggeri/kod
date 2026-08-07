import Foundation

/// Archive container formats a catalog artifact may declare. Only
/// `.tarGz` is currently implemented by `SecureArchiveExtractor` — real
/// managed servers (a pinned private Node runtime, standalone
/// `rust-analyzer` releases) both ship as gzip-compressed tar archives
/// upstream, so this covers every server Phase 8 actually manages.
/// `.zip` is declared so the catalog schema can describe a future
/// artifact without a breaking format change, but
/// `SecureArchiveExtractor` rejects it explicitly (`unsupportedFormat`)
/// rather than silently attempting an unimplemented path.
public enum ManagedArchiveFormat: String, Codable, Sendable, Equatable {
    case tarGz = "tar.gz"
    case zip
}
