import Foundation

/// Produces and parses the exact canonical byte encoding of an
/// `UpdateFeed` that gets Ed25519-signed — the update-feed analog of
/// `ManagedLanguageServers.CatalogCanonicalization`. Both directions
/// share one `JSONEncoder`/`JSONDecoder` configuration (sorted keys,
/// fixed ISO-8601 date strategy, unescaped slashes) so re-encoding the
/// same logical feed is byte-for-byte deterministic; verification never
/// re-encodes, only hashes/decodes the exact bytes that were signed.
public enum UpdateFeedCanonicalization {
    public static func encode(_ feed: UpdateFeed) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(feed)
    }

    public static func decode(_ data: Data) throws -> UpdateFeed {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(UpdateFeed.self, from: data)
        } catch {
            throw UpdateFeedVerificationError.malformedFeedDocument
        }
    }
}
