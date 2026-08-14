import Foundation
import LanguageClient
import WorkspaceCore

// The trust boundary between the app's workspace model and the
// platform-neutral language client. `LanguageClient` deliberately knows
// nothing about `WorkspaceIdentity`/`WorkspaceTrustStore` (or
// `UserDefaults`); it only asks whether a launch is authorized and where
// the workspace root is. This file is the single place that answers
// those questions with Kod's real trust store.

extension WorkspaceTrustStore: WorkspaceTrustAuthorizing {
    /// The confinement root for a workspace: its already-canonicalized
    /// identity root. Non-isolated because path confinement is a pure
    /// value question, unrelated to the main-actor trust decision.
    public nonisolated func workspaceRoot(of workspace: WorkspaceIdentity) -> URL {
        workspace.root
    }
}

extension WorkspaceLaunchAuthorization {
    /// The trust-before-launch gate for one workspace, evaluated against
    /// the live trust store on every launch attempt so a revocation takes
    /// effect immediately.
    public static func workspaceTrust(
        _ trustStore: WorkspaceTrustStore,
        identity: WorkspaceIdentity
    ) -> WorkspaceLaunchAuthorization {
        .trustStore(trustStore, workspace: identity)
    }
}
