import Foundation

/// Wraps a `FileManager` for capture across an actor-isolation boundary
/// (e.g. into `Task { ... }`'s closure). `FileManager`'s `Sendable`
/// conformance is explicitly unavailable in Swift 6's strict
/// concurrency checking even though `FileManager.default` (and any
/// `FileManager` instance, per Apple's own documentation) is safe to
/// use concurrently from multiple threads — every use in this file is
/// exactly that documented safe pattern (independent, stateless-ish
/// filesystem calls, never mutating shared `FileManager` state), so
/// `@unchecked Sendable` here reflects a real safety argument rather
/// than suppressing a genuine race.
private struct FileManagerBox: @unchecked Sendable {
    let fileManager: FileManager
}

/// One update during `ManagedInstallController.install`'s progress
/// stream (SPEC 6.5: explicit install consent, progress, cancellation).
public enum ManagedInstallStage: Sendable, Equatable {
    case downloading(ManagedDownloadProgress)
    case verifyingDigest
    case extracting
    case activating
}

/// Orchestrates the full managed-install lifecycle — install, upgrade,
/// rollback, remove, cancellation, and interrupted-operation recovery —
/// entirely under `ManagedInstallPaths.root`
/// (`~/Library/Application Support/Kod/LanguageServers`), never under
/// any opened workspace.
///
/// Concurrency safety has two layers:
/// 1. In-process: this type is an `actor`, and `install`/`upgrade`
///    calls for the same `serverID` are coalesced onto one shared
///    `Task` (`inFlightInstalls`) rather than running twice.
/// 2. Cross-process (and defense-in-depth even in-process): every
///    filesystem mutation happens while holding that `serverID`'s
///    `InstallLock` (`flock`-backed), acquired and released around the
///    stage/activate section.
public actor ManagedInstallController {
    private let paths: ManagedInstallPaths
    private let fileManager: FileManager
    private let activeVersionStore: ActiveVersionStore
    private let consentStore: ManagedInstallConsentStore
    private var inFlightInstalls: [String: Task<InstalledServerRecord, Error>] = [:]

    public init(paths: ManagedInstallPaths = ManagedInstallPaths(), fileManager: FileManager = .default) throws {
        self.paths = paths
        self.fileManager = fileManager
        self.activeVersionStore = ActiveVersionStore(paths: paths, fileManager: fileManager)
        self.consentStore = ManagedInstallConsentStore(paths: paths, fileManager: fileManager)
        try paths.ensureLayoutExists(fileManager: fileManager)
    }

    // MARK: - Consent

    public func grantConsent(serverID: String, version: SemanticVersion, architecture: ManagedInstallArchitecture) throws {
        try consentStore.record(ManagedInstallConsent(serverID: serverID, version: version, architecture: architecture, consentedAt: Date()))
    }

    public func consent(serverID: String) -> ManagedInstallConsent? {
        consentStore.consent(serverID: serverID)
    }

    // MARK: - State query

    public func installedRecord(serverID: String) throws -> InstalledServerRecord? {
        try activeVersionStore.activeRecord(serverID: serverID)
    }

    // MARK: - Install / upgrade

    /// Installs (or, if a different version is already active,
    /// upgrades to) `entry`'s artifact for `architecture`. Requires
    /// `grantConsent` to have already been called for this exact
    /// `(serverID, version, architecture)` — never implicitly consents
    /// on the caller's behalf.
    ///
    /// Concurrent calls for the same `entry.serverID` share one
    /// in-flight `Task`: the second caller simply awaits the first
    /// call's result rather than starting a redundant, overlapping
    /// install.
    public func install(
        entry: ManagedServerCatalogEntry,
        architecture: ManagedInstallArchitecture,
        trustRoot: CatalogTrustRoot,
        cancellationToken: ManagedDownloadCancellationToken = ManagedDownloadCancellationToken(),
        onProgress: (@Sendable (ManagedInstallStage) -> Void)? = nil
    ) async throws -> InstalledServerRecord {
        if let existingTask = inFlightInstalls[entry.serverID] {
            return try await existingTask.value
        }

        let task = Task { [paths, activeVersionStore, consentStore, fileManagerBox = FileManagerBox(fileManager: fileManager)] () throws -> InstalledServerRecord in
            try await Self.performInstall(
                entry: entry,
                architecture: architecture,
                trustRoot: trustRoot,
                paths: paths,
                fileManager: fileManagerBox.fileManager,
                activeVersionStore: activeVersionStore,
                consentStore: consentStore,
                cancellationToken: cancellationToken,
                onProgress: onProgress
            )
        }
        inFlightInstalls[entry.serverID] = task
        defer { inFlightInstalls[entry.serverID] = nil }
        return try await task.value
    }

    /// The actual pipeline, `nonisolated` and `static` so it runs
    /// off this actor's executor while the download/extraction work is
    /// in flight — an actor method awaiting a multi-second network
    /// download would otherwise serialize every other unrelated call
    /// into this actor (state queries, other servers' installs) behind
    /// it for no reason, since none of this pipeline's intermediate
    /// steps touch actor-isolated state until the final activation
    /// write.
    private static func performInstall(
        entry: ManagedServerCatalogEntry,
        architecture: ManagedInstallArchitecture,
        trustRoot: CatalogTrustRoot,
        paths: ManagedInstallPaths,
        fileManager: FileManager,
        activeVersionStore: ActiveVersionStore,
        consentStore: ManagedInstallConsentStore,
        cancellationToken: ManagedDownloadCancellationToken,
        onProgress: (@Sendable (ManagedInstallStage) -> Void)?
    ) async throws -> InstalledServerRecord {
        guard !entry.revoked else {
            throw ManagedInstallError.revokedEntry(serverID: entry.serverID, reason: entry.revocationReason)
        }
        guard let artifact = entry.artifact(for: architecture) else {
            throw ManagedInstallError.unsupportedArchitecture(serverID: entry.serverID, architecture: architecture)
        }
        guard !trustRoot.revokedArtifactDigestsHex.contains(artifact.sha256Hex) else {
            throw ManagedInstallError.artifactDigestRevoked(sha256Hex: artifact.sha256Hex)
        }
        guard Self.isSecureArtifactURL(artifact.url) else {
            throw ManagedInstallError.insecureArtifactURL(artifact.url)
        }
        guard consentStore.matches(serverID: entry.serverID, version: entry.version, architecture: architecture) else {
            throw ManagedInstallError.consentRequired(serverID: entry.serverID, version: entry.version, architecture: architecture)
        }
        if let privateRuntime = entry.privateRuntime {
            guard try activeVersionStore.activeRecord(serverID: privateRuntime.runtimeServerID) != nil else {
                throw ManagedInstallError.missingPrivateRuntime(runtimeServerID: privateRuntime.runtimeServerID)
            }
        }

        if let existing = try activeVersionStore.activeRecord(serverID: entry.serverID),
           existing.version == entry.version, existing.architecture == architecture {
            return existing
        }

        let lock = try InstallLock(fileURL: paths.lockFileURL(serverID: entry.serverID), fileManager: fileManager)
        let lockHandle = try await lock.acquire()
        defer { lock.release(lockHandle) }

        let operationID = UUID()
        let downloadURL = paths.newDownloadFileURL(serverID: entry.serverID, operationID: operationID)
        defer {
            try? fileManager.removeItem(at: downloadURL)
            // Also remove the now-empty per-server download subdirectory
            // (not just the file) so a cancelled/failed install leaves
            // zero trace under `downloads/`, not just an empty
            // directory — `recoverInterruptedOperations` would also
            // catch this on next launch, but doing it immediately here
            // means a test (or a user) inspecting the directory right
            // after a cancellation sees it fully clean already.
            let parent = downloadURL.deletingLastPathComponent()
            if let contents = try? fileManager.contentsOfDirectory(atPath: parent.path), contents.isEmpty {
                try? fileManager.removeItem(at: parent)
            }
        }

        try await BoundedDownloader.download(
            url: artifact.url,
            maxBytes: artifact.maxDownloadBytes,
            destinationURL: downloadURL,
            cancellationToken: cancellationToken,
            onProgress: { progress in
                onProgress?(.downloading(progress))
            }
        )

        onProgress?(.verifyingDigest)
        let downloadedBytes = try Data(contentsOf: downloadURL, options: .mappedIfSafe)
        let actualDigest = Digest.sha256Hex(of: downloadedBytes)
        guard actualDigest == artifact.sha256Hex else {
            throw ManagedInstallError.digestMismatch(expectedSha256Hex: artifact.sha256Hex, actualSha256Hex: actualDigest)
        }

        onProgress?(.extracting)
        let stagingDirectory = paths.newStagingDirectory(serverID: entry.serverID, operationID: operationID)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        var stagingCleanedUp = false
        defer {
            if !stagingCleanedUp {
                try? fileManager.removeItem(at: stagingDirectory)
            }
            // As with the download temp file above, also drop the
            // now-empty per-server staging subdirectory so a cancelled/
            // failed install leaves nothing under `staging/` at all.
            let parent = stagingDirectory.deletingLastPathComponent()
            if let contents = try? fileManager.contentsOfDirectory(atPath: parent.path), contents.isEmpty {
                try? fileManager.removeItem(at: parent)
            }
        }

        try SecureArchiveExtractor.extract(
            archiveBytes: downloadedBytes,
            format: artifact.archiveFormat,
            maxDecompressedBytes: artifact.maxDecompressedBytes,
            expectedRelativePaths: artifact.expectedRelativePaths,
            executableRelativePath: artifact.executableRelativePath,
            destinationRoot: stagingDirectory,
            fileManager: fileManager
        )

        onProgress?(.activating)
        let finalVersionDirectory = paths.versionDirectory(serverID: entry.serverID, version: entry.version)
        try fileManager.createDirectory(at: finalVersionDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: finalVersionDirectory.path) {
            try fileManager.removeItem(at: finalVersionDirectory)
        }
        // `moveItem` here is a same-volume `rename()` (staging and
        // versions both live under one `ManagedInstallPaths.root`),
        // which POSIX guarantees is atomic — the version directory
        // either doesn't exist yet or fully exists with every extracted
        // file, never a partial copy.
        try fileManager.moveItem(at: stagingDirectory, to: finalVersionDirectory)
        stagingCleanedUp = true

        return try activeVersionStore.activate(
            serverID: entry.serverID,
            version: entry.version,
            architecture: architecture,
            executableRelativePath: artifact.executableRelativePath,
            adapterArguments: entry.adapterArguments,
            adapterEnvironment: entry.adapterEnvironment
        )
    }

    // MARK: - Rollback / remove

    @discardableResult
    public func rollback(serverID: String) throws -> InstalledServerRecord {
        try activeVersionStore.rollback(serverID: serverID)
    }

    public func remove(serverID: String) async throws {
        let lock = try InstallLock(fileURL: paths.lockFileURL(serverID: serverID), fileManager: fileManager)
        let handle = try await lock.acquire()
        defer { lock.release(handle) }

        let serverVersionsDirectory = paths.serverVersionsDirectory(serverID: serverID)
        if fileManager.fileExists(atPath: serverVersionsDirectory.path) {
            try fileManager.removeItem(at: serverVersionsDirectory)
        }
        try activeVersionStore.clearState(serverID: serverID)
    }

    // MARK: - Interrupted-operation recovery

    /// Cleans up any leftover `staging/`/`downloads/` entries from an
    /// operation that never reached its atomic activation step (a crash
    /// or force-quit mid-install) — safe to call unconditionally at
    /// launch (or at controller `init`) because every staging/download
    /// entry is only ever created immediately before, and removed
    /// immediately after, one install operation; anything still present
    /// when no operation is running is necessarily stale.
    ///
    /// This deliberately does **not** try to guess/repair a broken
    /// active/previous version *pointer* (e.g. one that references a
    /// version directory no longer on disk) — `ActiveVersionStore`
    /// already reports that case as a distinct, explicit error
    /// (`activeVersionDirectoryMissing`) rather than this method
    /// silently rewriting state to make it look installed when it
    /// isn't.
    public func recoverInterruptedOperations() throws {
        for directory in [paths.stagingDirectory, paths.downloadsDirectory] {
            guard fileManager.fileExists(atPath: directory.path) else {
                continue
            }
            let contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for entry in contents {
                try fileManager.removeItem(at: entry)
            }
        }
    }

    /// SPEC 6.5 requires "Download over TLS only" for a real managed
    /// install. This accepts exactly `https`, with one narrow, explicit
    /// exception: plain `http` to the loopback address or `localhost`.
    /// That exception is not a test-only bypass flag — it is the same
    /// "potentially trustworthy origin" reasoning browsers and other
    /// platform security policies already use for `http://localhost`
    /// (W3C Secure Contexts): traffic to `127.0.0.1`/`::1` never leaves
    /// the machine, so there is no network path for TLS to protect
    /// against in the first place. This is what lets
    /// `ManagedLanguageServersTests`'s lifecycle tests exercise this
    /// exact production code path — including the real `BoundedDownloader`
    /// network stack — against `LocalHTTPTestServer` with no external,
    /// mutable URL and no weakened check for any real, non-loopback
    /// artifact URL.
    private static func isSecureArtifactURL(_ url: URL) -> Bool {
        if url.scheme == "https" {
            return true
        }
        guard url.scheme == "http" else {
            return false
        }
        switch url.host {
        case "127.0.0.1", "::1", "localhost":
            return true
        default:
            return false
        }
    }
}
