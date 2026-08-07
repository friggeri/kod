import Foundation

/// A catalog exactly as distributed: the canonical JSON bytes that were
/// signed, plus the detached Ed25519 signature and which pinned key
/// produced it. `CatalogVerifier` never decodes `canonicalBytes` into a
/// `ManagedServerCatalog` until the signature over those exact bytes has
/// already been checked — so a tampered byte can never even reach the
/// JSON decoder.
public struct SignedCatalogDocument: Codable, Sendable, Equatable {
    public let canonicalBytes: Data
    public let signature: Data
    public let signingKeyID: String

    public init(canonicalBytes: Data, signature: Data, signingKeyID: String) {
        self.canonicalBytes = canonicalBytes
        self.signature = signature
        self.signingKeyID = signingKeyID
    }

    /// The on-disk envelope format: `canonicalBytes` embedded as a
    /// base64 string alongside the signature/key ID, so the whole
    /// document is itself one JSON file
    /// (`ManagedInstallPaths.catalogEnvelopeURL`). Kept as an explicit,
    /// separate `Envelope` type (rather than deriving `Codable`
    /// directly on `SignedCatalogDocument`) so the wire format is
    /// documented as its own stable shape independent of Swift's
    /// default `Data`-as-base64 encoding, which is an implementation
    /// detail this envelope pins on purpose.
    public struct Envelope: Codable, Sendable, Equatable {
        public let canonicalBytesBase64: String
        public let signatureBase64: String
        public let signingKeyID: String

        public init(canonicalBytesBase64: String, signatureBase64: String, signingKeyID: String) {
            self.canonicalBytesBase64 = canonicalBytesBase64
            self.signatureBase64 = signatureBase64
            self.signingKeyID = signingKeyID
        }
    }

    public var envelope: Envelope {
        Envelope(
            canonicalBytesBase64: canonicalBytes.base64EncodedString(),
            signatureBase64: signature.base64EncodedString(),
            signingKeyID: signingKeyID
        )
    }

    public init(envelope: Envelope) throws {
        guard let canonicalBytes = Data(base64Encoded: envelope.canonicalBytesBase64),
              let signature = Data(base64Encoded: envelope.signatureBase64) else {
            throw CatalogVerificationError.malformedCatalogDocument
        }
        self.canonicalBytes = canonicalBytes
        self.signature = signature
        self.signingKeyID = envelope.signingKeyID
    }

    public func encodedEnvelope() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    public static func decodeEnvelope(_ data: Data) throws -> SignedCatalogDocument {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        return try SignedCatalogDocument(envelope: envelope)
    }
}
