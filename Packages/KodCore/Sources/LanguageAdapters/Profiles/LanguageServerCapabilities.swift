/// Whether a shipped default profile's server may reach the network at
/// all, and only after the workspace has been explicitly trusted. This
/// is shipped-only capability metadata: `LanguageProfile.validated()`
/// rejects any custom profile that declares anything but `.none`, so a
/// user-authored profile can never grant its server network access.
public enum LanguageServerNetworkAccess: String, Codable, Sendable, Equatable {
    case none
    case remoteSchemasAfterWorkspaceTrust
}

/// A shipped-only marker for one narrowly-scoped specialization a
/// default profile's server needs at launch time, resolved by a
/// dedicated helper that reads the profile's own configuration (see
/// `ShellCheckSupport`). Like `LanguageServerNetworkAccess`, custom
/// profiles may never declare one.
public enum LanguageServerSupportNote: String, Codable, Sendable, Hashable {
    case shellCheckOptional
}
