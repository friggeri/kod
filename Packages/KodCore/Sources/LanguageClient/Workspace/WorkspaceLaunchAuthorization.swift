import Foundation

// The trust-before-launch gate (SPEC 6/13), expressed as an injected
// capability rather than a concrete trust store. `LanguageClient` knows
// only that *something* must authorize a launch; it deliberately knows
// nothing about how the host records that decision (a `UserDefaults`-
// backed workspace trust store in the app, an explicit allow in a unit
// test, a policy check somewhere else). That keeps this module free of
// any platform/persistence dependency while leaving the rule itself —
// no server process is ever spawned for an unauthorized workspace —
// enforced in exactly one place.

/// The gate consulted immediately before a language server process is
/// launched. Evaluated on every `start()`, never cached, so revoking
/// authorization takes effect on the very next launch attempt.
public struct WorkspaceLaunchAuthorization: Sendable {
    private let evaluate: @Sendable () async -> Bool

    /// Builds an authorization from an async, `Sendable` predicate.
    public init(_ evaluate: @escaping @Sendable () async -> Bool) {
        self.evaluate = evaluate
    }

    /// Builds an authorization from a main-actor-isolated predicate,
    /// which is the shape a UI-owned trust store has.
    public static func mainActor(
        _ isAuthorized: @escaping @MainActor @Sendable () -> Bool
    ) -> WorkspaceLaunchAuthorization {
        WorkspaceLaunchAuthorization {
            await MainActor.run(body: isAuthorized)
        }
    }

    /// Always authorized: for workspaces whose trust decision the caller
    /// has already made, and for tests not exercising the gate itself.
    public static let authorized = WorkspaceLaunchAuthorization { true }

    /// Never authorized.
    public static let denied = WorkspaceLaunchAuthorization { false }

    public func isAuthorized() async -> Bool {
        await evaluate()
    }
}

/// A host trust store, described by the only two things a language
/// service needs from it: whether a workspace may launch a server, and
/// where that workspace's root is. Exists so a host that already models
/// workspace identity (the app's `WorkspaceCore.WorkspaceIdentity` /
/// `WorkspaceTrustStore` pair) can be adapted at the boundary without
/// `LanguageClient` depending on that model.
public protocol WorkspaceTrustAuthorizing: Sendable {
    /// The host's own workspace identity value.
    associatedtype Workspace: Sendable

    @MainActor func isTrusted(_ workspace: Workspace) -> Bool
    nonisolated func workspaceRoot(of workspace: Workspace) -> URL
}

extension WorkspaceLaunchAuthorization {
    /// Adapts a host trust store plus one workspace identity into the
    /// injected capability.
    public static func trustStore<Trust: WorkspaceTrustAuthorizing>(
        _ trustStore: Trust,
        workspace: Trust.Workspace
    ) -> WorkspaceLaunchAuthorization {
        .mainActor { trustStore.isTrusted(workspace) }
    }
}
