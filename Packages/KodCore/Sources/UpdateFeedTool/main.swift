import CryptoKit
import Foundation
import ManagedLanguageServers
import UpdaterCore

/// Release/test tooling for Kod's signed update feed: generate an
/// Ed25519 key pair, sign a feed JSON file into a distributable signed
/// envelope, or verify one against a trust root. This binary is never
/// shipped inside Kod.app; it exists purely so update-feed signing is a
/// documented, reproducible, scriptable step (`Scripts/release/README.md`)
/// rather than an ad hoc one-off, and never requires the private key to
/// live anywhere inside this repository or the app's own source. This
/// mirrors `ManagedCatalogTool`'s own three subcommands exactly.
///
/// Usage:
///   UpdateFeedTool generate-key
///   UpdateFeedTool sign --feed <feed.json> --key-seed-base64 <seed> --key-id <id> --output <signed.json>
///   UpdateFeedTool verify --signed <signed.json> --public-key-base64 <key> --key-id <id>

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
    print("Publish only the public key, pinned into UpdateFeedTrustRoot with a chosen key ID and validity window.")
}

func runSign(arguments: [String]) throws {
    let feedPath = try argumentValue("--feed", in: arguments)
    let seedBase64 = try argumentValue("--key-seed-base64", in: arguments)
    let keyID = try argumentValue("--key-id", in: arguments)
    let outputPath = try argumentValue("--output", in: arguments)

    guard let seedData = Data(base64Encoded: seedBase64) else {
        throw ToolError.invalidArgument("--key-seed-base64")
    }
    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seedData)

    let feedData = try Data(contentsOf: URL(fileURLWithPath: feedPath))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let feed = try decoder.decode(UpdateFeed.self, from: feedData)

    let signed = try UpdateFeedSigner.sign(feed, privateKey: privateKey, signingKeyID: keyID)
    let envelopeData = try signed.encodedEnvelope()
    try envelopeData.write(to: URL(fileURLWithPath: outputPath))
    print("Signed update feed written to \(outputPath)")
}

func runVerify(arguments: [String]) throws {
    let signedPath = try argumentValue("--signed", in: arguments)
    let publicKeyBase64 = try argumentValue("--public-key-base64", in: arguments)
    let keyID = try argumentValue("--key-id", in: arguments)

    let envelopeData = try Data(contentsOf: URL(fileURLWithPath: signedPath))
    let signed = try SignedUpdateFeedDocument.decodeEnvelope(envelopeData)
    let trustRoot = UpdateFeedTrustRoot(pinned: [
        TrustedUpdateSigningKey(id: keyID, publicKeyBase64: publicKeyBase64, validFrom: Date(timeIntervalSince1970: 0))
    ])
    let feed = try UpdateFeedVerifier.verify(signed, trustRoot: trustRoot)
    print("Signature valid. \(feed.entries.count) entries:")
    for entry in feed.entries {
        let architectureLabel = entry.architecture.map(\.rawValue) ?? "universal"
        print("  - \(entry.version) (\(architectureLabel), rollbackTarget: \(entry.isRollbackTarget), critical: \(entry.isCriticalSecurityUpdate))")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print("Usage: UpdateFeedTool <generate-key|sign|verify> [options]")
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
