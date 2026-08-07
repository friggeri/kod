import Foundation
import ManagedLanguageServers

/// Bridges an installed, active `ManagedInstallController` record into a
/// `DiscoveredExecutable`, the final (tier 6) SPEC 6.5 discovery step.
/// Every adapter that supports a managed install (TypeScript/JavaScript,
/// HTML, CSS, Python, Rust — never Swift, which SPEC 6.5 keeps to guided
/// Xcode/toolchain install only) passes a closure built from this into
/// `LanguageServerDiscoveryEngine.resolve`'s `managedInstallProbe`.
///
/// `ManagedInstallController` is an `actor`, but `LanguageAdapter.discover`
/// is a synchronous, blocking call (mirroring every other discovery tier,
/// and Phase 6's `SourceKitLSPDiscovery`) run on a background thread — so
/// this bridges the one `async` call it needs
/// (`ManagedInstallController.installedRecord`) with a semaphore, exactly
/// the same "block this one background discovery thread, never any
/// shared/cooperative pool" pattern `LanguageServerDiscoveryEngine`'s own
/// `detectVersion` already uses for a subprocess `waitUntilExit()`.
public enum ManagedInstallDiscoverySource {
    /// One process-wide controller so every adapter's managed-install
    /// tier reads the same on-disk state under
    /// `~/Library/Application Support/Kod/LanguageServers` (SPEC 6.5's
    /// fixed path) rather than each constructing an independent
    /// instance. `nil` only if `ManagedInstallPaths.ensureLayoutExists`
    /// itself failed (e.g. an unwritable Application Support directory)
    /// — in which case every adapter's managed-install tier simply
    /// reports nothing, falling through to `.notFound` like any other
    /// unavailable tier, never a crash.
    public static let shared: ManagedInstallController? = try? ManagedInstallController()

    /// Looks up `serverID`'s currently active managed install and, if
    /// present and its executable is genuinely present and executable on
    /// disk, returns a `DiscoveredExecutable` for it. Returns `nil` (not
    /// an error) for "no managed install yet" — that is exactly the
    /// normal, expected state for a user who hasn't opted into a
    /// managed install, and discovery must fall through to
    /// `.notFound` cleanly in that case.
    public static func discover(
        serverID: String,
        controller: ManagedInstallController?,
        paths: ManagedInstallPaths = ManagedInstallPaths()
    ) -> DiscoveredExecutable? {
        guard let controller else {
            return nil
        }
        guard let record = blockingInstalledRecord(serverID: serverID, controller: controller) else {
            return nil
        }
        let versionDirectory = paths.versionDirectory(serverID: serverID, version: record.version)
        let executableURL = versionDirectory.appendingPathComponent(record.executableRelativePath)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return nil
        }
        return DiscoveredExecutable(
            url: executableURL,
            arguments: record.adapterArguments,
            version: "\(record.version) (\(record.architecture.rawValue), Kod-managed)",
            source: .managedInstall
        )
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: InstalledServerRecord?

        func set(_ newValue: InstalledServerRecord?) {
            lock.lock()
            value = newValue
            lock.unlock()
        }

        func get() -> InstalledServerRecord? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private static func blockingInstalledRecord(serverID: String, controller: ManagedInstallController) -> InstalledServerRecord? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        Task {
            let record = try? await controller.installedRecord(serverID: serverID)
            box.set(record)
            semaphore.signal()
        }
        semaphore.wait()
        return box.get()
    }
}
