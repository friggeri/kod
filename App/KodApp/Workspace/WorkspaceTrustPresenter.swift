import AppKit

/// Owns workspace-trust presentation: the persistent status-bar control and
/// the confirmation alert that guards a trust change (SPEC 13.1).
///
/// It renders whatever trust state it is given and emits typed intents;
/// it never reads or mutates the trust store, starts or stops language
/// services, or writes diagnostics — that policy stays in the workspace
/// shell.
@MainActor
final class WorkspaceTrustPresenter: NSObject {
    enum Intent {
        case grantTrust
        case revokeTrust
    }

    var onIntent: ((Intent) -> Void)?
    /// Resolves the window a confirmation alert should be attached to.
    var presentingWindow: () -> NSWindow? = { nil }

    let statusButton = NSButton()

    private var isTrusted = false

    override init() {
        super.init()
        configureStatusButton()
    }

    // MARK: - Rendering

    /// Called on load and after every grant/revoke so the control cannot show
    /// stale state.
    func render(isTrusted: Bool) {
        self.isTrusted = isTrusted
        renderStatusButton()
    }

    private func configureStatusButton() {
        statusButton.identifier = NSUserInterfaceItemIdentifier("workspace.trustStatus")
        statusButton.bezelStyle = .inline
        statusButton.isBordered = false
        statusButton.imagePosition = .imageOnly
        statusButton.target = self
        statusButton.action = #selector(promptToToggleWorkspaceTrust(_:))
        statusButton.translatesAutoresizingMaskIntoConstraints = false
        renderStatusButton()
    }

    private func renderStatusButton() {
        let stateDescription: String
        let actionDescription: String
        let symbolName: String

        if isTrusted {
            stateDescription = Localized.string(
                "This workspace is trusted: language servers and repository tools are enabled.",
                comment: "Trust status description shown for a trusted workspace"
            )
            actionDescription = Localized.string(
                "Revoke trust for this workspace, disabling language servers",
                comment: "Accessibility help for the status-bar workspace trust control"
            )
            symbolName = "checkmark.shield.fill"
            statusButton.contentTintColor = .labelColor
        } else {
            stateDescription = Localized.string(
                "Restricted mode: language servers and repository tools are disabled.",
                comment: "Trust status description shown for an untrusted workspace"
            )
            actionDescription = Localized.string(
                "Trust this workspace, enabling language servers and repository tools",
                comment: "Accessibility help for the status-bar workspace trust control"
            )
            symbolName = "exclamationmark.shield.fill"
            statusButton.contentTintColor = .labelColor
        }

        statusButton.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: stateDescription
        )
        statusButton.toolTip = "\(stateDescription)\n\(actionDescription)"
        statusButton.setAccessibilityLabel(stateDescription)
        statusButton.setAccessibilityHelp(actionDescription)
    }

    /// The status-bar control is a *destructive-ish* toggle, so it always
    /// confirms before emitting a grant/revoke intent.
    @objc
    func promptToToggleWorkspaceTrust(_ sender: Any?) {
        guard let window = presentingWindow() else {
            return
        }

        let shouldTrust = !isTrusted
        let alert = NSAlert()
        alert.alertStyle = .warning
        if shouldTrust {
            alert.messageText = Localized.string(
                "Trust Workspace",
                comment: "Title of the confirmation alert for trusting a workspace"
            )
            alert.informativeText = Localized.string(
                "Trusting this workspace enables language servers and repository tools, which may execute code from this directory.",
                comment: "Explanation in the confirmation alert for trusting a workspace"
            )
            alert.addButton(
                withTitle: Localized.string(
                    "Trust Workspace",
                    comment: "Confirmation button title for trusting a workspace"
                )
            )
        } else {
            alert.messageText = Localized.string(
                "Revoke Trust",
                comment: "Title of the confirmation alert for revoking workspace trust"
            )
            alert.informativeText = Localized.string(
                "Revoking trust disables repository tools and stops running language servers for this workspace.",
                comment: "Explanation in the confirmation alert for revoking workspace trust"
            )
            alert.addButton(
                withTitle: Localized.string(
                    "Revoke Trust",
                    comment: "Confirmation button title for revoking workspace trust"
                )
            )
        }
        alert.addButton(
            withTitle: Localized.string(
                "Cancel",
                comment: "Button title canceling a workspace trust change"
            )
        )
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else {
                return
            }
            self.onIntent?(shouldTrust ? .grantTrust : .revokeTrust)
        }
    }
}
