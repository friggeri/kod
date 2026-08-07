import CryptoKit
import Foundation
import ManagedLanguageServers

/// Release/test tooling for Kod's managed-install catalog: generate an
/// Ed25519 key pair, sign a catalog JSON file into a distributable
/// signed envelope, or verify one against a trust root. This binary is
/// never shipped inside Kod.app; it exists purely so catalog signing is
/// a documented, reproducible, scriptable step
/// (`Scripts/managed-install-signing/README.md`) rather than an ad hoc
/// one-off, and never requires the private key to live anywhere inside
/// this repository or the app's own source.
///
/// Usage:
///   ManagedCatalogTool generate-key
///   ManagedCatalogTool sign --catalog <catalog.json> --key-seed-base64 <seed> --key-id <id> --output <signed.json>
///   ManagedCatalogTool verify --signed <signed.json> --public-key-base64 <key> --key-id <id>

enum ToolError: Error, CustomStringConvertible {
    case missingArgument(String)
    case invalidArgument(String)

    var description: String {
        switch self {
        case .missingArgument(let name):
            return "Missing required argument: \(name)"
        case .invalidArgument(let name):
            return "Invalid value for argument: \(name)"
        }
    }
}

func argumentValue(_ name: String, in arguments: [String]) throws -> String {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        throw ToolError.missingArgument(name)
    }
    return arguments[index + 1]
}

func runGenerateKey() {
    let privateKey = Curve25519.Signing.PrivateKey()
    print("seed-base64: \(privateKey.rawRepresentation.base64EncodedString())")
    print("public-key-base64: \(privateKey.publicKey.rawRepresentation.base64EncodedString())")
    print("")
    print("Store the seed offline (a hardware key/secrets manager, never in this repository).")
    print("Publish only the public key, pinned into CatalogTrustRoot with a chosen key ID and validity window.")
}

func runSign(arguments: [String]) throws {
    let catalogPath = try argumentValue("--catalog", in: arguments)
    let seedBase64 = try argumentValue("--key-seed-base64", in: arguments)
    let keyID = try argumentValue("--key-id", in: arguments)
    let outputPath = try argumentValue("--output", in: arguments)

    guard let seedData = Data(base64Encoded: seedBase64) else {
        throw ToolError.invalidArgument("--key-seed-base64")
    }
    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seedData)

    let catalogData = try Data(contentsOf: URL(fileURLWithPath: catalogPath))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let catalog = try decoder.decode(ManagedServerCatalog.self, from: catalogData)

    let signed = try CatalogSigner.sign(catalog, privateKey: privateKey, signingKeyID: keyID)
    let envelopeData = try signed.encodedEnvelope()
    try envelopeData.write(to: URL(fileURLWithPath: outputPath))
    print("Signed catalog written to \(outputPath)")
}

func runVerify(arguments: [String]) throws {
    let signedPath = try argumentValue("--signed", in: arguments)
    let publicKeyBase64 = try argumentValue("--public-key-base64", in: arguments)
    let keyID = try argumentValue("--key-id", in: arguments)

    let envelopeData = try Data(contentsOf: URL(fileURLWithPath: signedPath))
    let signed = try SignedCatalogDocument.decodeEnvelope(envelopeData)
    let trustRoot = CatalogTrustRoot(pinned: [
        TrustedSigningKey(id: keyID, publicKeyBase64: publicKeyBase64, validFrom: Date(timeIntervalSince1970: 0))
    ])
    let catalog = try CatalogVerifier.verify(signed, trustRoot: trustRoot)
    print("Signature valid. \(catalog.entries.count) entries:")
    for entry in catalog.entries {
        print("  - \(entry.serverID) \(entry.version) (language: \(entry.language ?? "n/a"), revoked: \(entry.revoked))")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print("Usage: ManagedCatalogTool <generate-key|sign|verify> [options]")
    exit(64)
}

do {
    switch command {
    case "generate-key":
        runGenerateKey()
    case "sign":
        try runSign(arguments: Array(arguments.dropFirst()))
    case "verify":
        try runVerify(arguments: Array(arguments.dropFirst()))
    default:
        print("Unknown command: \(command)")
        exit(64)
    }
} catch {
    print("Error: \(error)")
    exit(1)
}
