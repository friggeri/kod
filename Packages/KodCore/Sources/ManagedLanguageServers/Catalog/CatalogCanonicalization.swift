import Foundation

/// Produces and parses the exact canonical byte encoding of a
/// `ManagedServerCatalog` that gets Ed25519-signed. Both directions
/// share one `JSONEncoder`/`JSONDecoder` configuration (sorted keys,
/// fixed ISO-8601 date strategy) so re-encoding the same logical catalog
/// is deterministic — important for the reproducible-generation
/// requirement (SPEC 6.5, Phase 8 doc) even though *verification* never
/// re-encodes (it only ever hashes/decodes the exact bytes that were
/// signed, per `SignedCatalogDocument`'s doc comment).
public enum CatalogCanonicalization {
    public static func encode(_ catalog: ManagedServerCatalog) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(catalog)
    }

    public static func decode(_ data: Data) throws -> ManagedServerCatalog {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(ManagedServerCatalog.self, from: data)
        } catch {
            throw CatalogVerificationError.malformedCatalogDocument
        }
    }
}
