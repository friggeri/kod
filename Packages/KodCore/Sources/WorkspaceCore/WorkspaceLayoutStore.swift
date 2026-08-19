import Foundation
import SettingsCore

/// Persists and restores a workspace window's split layout, tabs, selection,
/// navigation history, and word-wrap preference outside the opened
/// repository, keyed by the workspace's canonicalized identity through an
/// injected SettingsCore repository shared with other external metadata.
///
/// Corrupt layout metadata is quarantined and rebuilt (SPEC 15) rather than
/// silently falling back to "no saved layout" with no trace: see
/// `FontCore.FontSettingsStore`'s doc comment for the identical rationale.
/// "Corrupt" here covers both a blob that fails to decode at all *and* one
/// that decodes but fails `WorkspaceLayoutState.validate()` — e.g. a split
/// tree missing a group, or a selected tab ID with no matching tab — since
/// either case leaves the rest of `WorkspaceCore` unable to safely assume
/// its invariants hold.
@MainActor
public final class WorkspaceLayoutStore {
    private let keyPrefix = "workspace-layout."
    private let repository: CodableSettingsRepository

    public init(repository: CodableSettingsRepository) {
        self.repository = repository
    }

    public var quarantine: SettingsQuarantine {
        repository.quarantine
    }

    /// Absence and quarantined corruption remain distinct so restoration
    /// callers can report a reset instead of presenting it as first launch.
    public func load(
        for identity: WorkspaceIdentity
    ) throws(SettingsRepositoryError) -> SettingsLoadOutcome<WorkspaceLayoutState> {
        try repository.read(setting(for: identity))
    }

    /// Validates, encodes, and persists `state` for `identity`. Throws
    /// `WorkspaceLayoutValidationError` (from `WorkspaceLayoutState.validate()`)
    /// if `state` itself is semantically invalid, or a typed
    /// `SettingsRepositoryError` if encoding/storage fails — either way
    /// nothing is written, so callers cannot mistake a failed save for
    /// persistence. Validating before encoding means
    /// `WorkspaceLayoutStore` never persists a blob that `load(for:)` would
    /// later have to quarantine. Callers can handle validation and storage
    /// failures independently; neither is converted into apparent success.
    public func save(
        _ state: WorkspaceLayoutState,
        for identity: WorkspaceIdentity
    ) throws {
        try state.validate()
        try repository.write(state, to: setting(for: identity))
    }

    public func clear(
        for identity: WorkspaceIdentity
    ) throws(SettingsRepositoryError) {
        try repository.remove(setting(for: identity))
    }

    public func observeChanges(
        for identity: WorkspaceIdentity,
        _ observer: @escaping @Sendable (SettingsChange) -> Void
    ) -> SettingsObservation {
        repository.observe(setting(for: identity), observer)
    }

    private func setting(
        for identity: WorkspaceIdentity
    ) -> CodableSetting<WorkspaceLayoutState> {
        CodableSetting(
            key: keyPrefix + identity.persistenceKey,
            currentVersion: 3,
            migrations: [
                .versioned(from: 2, WorkspaceLayoutState.self) {
                    Self.migrateActivityRailState($0)
                },
                .versioned(from: 1, WorkspaceLayoutState.self) {
                    Self.migrateLegacyState($0)
                },
                .unversionedCodable(WorkspaceLayoutState.self) {
                    Self.migrateLegacyState($0)
                }
            ],
            validate: { state in
                do {
                    try state.validate()
                    return nil
                } catch let error {
                    return SettingsValidationFailure(
                        reason: String(describing: error)
                    )
                }
            }
        )
    }

    nonisolated private static func migrateLegacyState(
        _ legacyState: WorkspaceLayoutState
    ) -> WorkspaceLayoutState {
        var state = legacyState
        state.sidebarSurface = .explorer
        if var geometry = state.geometry, geometry.sidebarWidth > 0 {
            geometry.sidebarWidth = min(
                max(geometry.sidebarWidth, 180),
                420
            )
            state.geometry = geometry
        }
        return state
    }

    nonisolated private static func migrateActivityRailState(
        _ railState: WorkspaceLayoutState
    ) -> WorkspaceLayoutState {
        var state = railState
        if var geometry = state.geometry, geometry.sidebarWidth > 0 {
            geometry.sidebarWidth = min(
                max(geometry.sidebarWidth - 44, 180),
                420
            )
            state.geometry = geometry
        }
        return state
    }
}
