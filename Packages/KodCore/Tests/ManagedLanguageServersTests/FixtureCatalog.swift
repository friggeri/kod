import Foundation
@testable import ManagedLanguageServers

/// Builds a signed, offline fixture catalog plus its tar.gz artifact
/// bytes for `ManagedLanguageServersTests`'s lifecycle tests: a single
/// `serverID` ("fixture-language-server") with two versions so
/// upgrade/rollback have something real to move between. The archived
/// "server" is the actual `FakeLanguageServer` executable this
/// repository already builds and uses elsewhere for real stdio-LSP
/// integration tests (`LanguageClientTests`) — so "install → launch"
/// here launches a genuinely real, LSP-speaking child process, not a
/// stub.
enum FixtureCatalog {
    static let serverID = "fixture-language-server"
    static let executableRelativePath = "bin/fake-language-server"

    struct Built {
        let catalog: ManagedServerCatalog
        let signedDocument: SignedCatalogDocument
        /// version -> tar.gz archive bytes for that version's artifact.
        let archives: [SemanticVersion: Data]
    }

    static func build(
        architecture: ManagedInstallArchitecture = .current,
        urlForVersion: (SemanticVersion) -> URL
    ) throws -> Built {
        let executableURL = try ManagedFakeLanguageServerLocator.executableURL()
        let executableBytes = try Data(contentsOf: executableURL)

        let v1 = SemanticVersion(major: 1, minor: 0, patch: 0)
        let v2 = SemanticVersion(major: 1, minor: 1, patch: 0)

        // Two distinct archives (rather than the identical bytes twice)
        // so a test can tell which version actually got extracted by
        // reading back a marker file unique to each, not just by
        // trusting the reported version number.
        let archive1 = try makeArchive(executableBytes: executableBytes, marker: "fixture-v1.0.0")
        let archive2 = try makeArchive(executableBytes: executableBytes, marker: "fixture-v1.1.0")

        func artifact(version: SemanticVersion, archive: Data) -> ManagedServerArtifact {
            ManagedServerArtifact(
                architecture: architecture,
                url: urlForVersion(version),
                sha256Hex: Digest.sha256Hex(of: archive),
                maxDownloadBytes: archive.count + 4096,
                maxDecompressedBytes: executableBytes.count + 65536,
                archiveFormat: .tarGz,
                expectedRelativePaths: [executableRelativePath, "MARKER.txt"],
                executableRelativePath: executableRelativePath
            )
        }

        let entry1 = ManagedServerCatalogEntry(
            serverID: serverID,
            language: "fixture",
            version: v1,
            minimumKodVersion: SemanticVersion(major: 1, minor: 0, patch: 0),
            artifacts: [artifact(version: v1, archive: archive1)],
            adapterArguments: ["normal"]
        )
        let entry2 = ManagedServerCatalogEntry(
            serverID: serverID,
            language: "fixture",
            version: v2,
            minimumKodVersion: SemanticVersion(major: 1, minor: 0, patch: 0),
            artifacts: [artifact(version: v2, archive: archive2)],
            adapterArguments: ["normal"]
        )

        let catalog = ManagedServerCatalog(generatedAt: Date(timeIntervalSince1970: 1_700_000_000), entries: [entry1, entry2])
        let signedDocument = try CatalogSigner.sign(catalog, privateKey: FixtureSigningKey.privateKey, signingKeyID: FixtureSigningKey.keyID)

        return Built(catalog: catalog, signedDocument: signedDocument, archives: [v1: archive1, v2: archive2])
    }

    private static func makeArchive(executableBytes: Data, marker: String) throws -> Data {
        let tar = TarWriter.write([
            .init(name: "bin/", type: .directory, mode: 0o755),
            .init(name: executableRelativePath, type: .regularFile, mode: 0o755, body: executableBytes),
            .init(name: "MARKER.txt", type: .regularFile, mode: 0o644, body: Data(marker.utf8))
        ])
        return try GzipCodec.compress(tar)
    }
}
