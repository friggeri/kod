import AppKit

/// Owns every piece of workspace-trust *presentation*: the one-time trust
/// banner, the persistent status-bar trust control, and the confirmation
/// alert that guards a trust change (SPEC 13.1).
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
        case dismissBanner
    }

    var onIntent: ((Intent) -> Void)?
    /// Fired whenever the banner's visibility changes so the workspace can
    /// re-evaluate its shared banner stack.
    var onBannerVisibilityChanged: (() -> Void)?
    /// Resolves the window a confirmation alert should be attached to.
    var presentingWindow: () -> NSWindow? = { nil }

    let bannerView = NSStackView()
    let statusButton = NSButton()

    private let bannerLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private let dismissButton = NSButton(
        image: NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: Localized.string(
                "Dismiss Workspace Trust Banner",
                comment: "Accessibility description for the button that dismisses the workspace trust banner"
            )
        ) ?? NSImage(),
        target: nil,
        action: nil
    )

    /// Whether this workspace won the one-time "show the banner on first
    /// open" claim; a re-opened workspace never shows it again.
    private let isBannerEligible: Bool
    private var isBannerDismissed = false
    private var isTrusted = false

    init(isBannerEligible: Bool) {
        self.isBannerEligible = isBannerEligible
        super.init()
        configureBanner()
        configureStatusButton()
    }

    // MARK: - Rendering

    /// Renders `isTrusted` into both surfaces. Called on load and after
    /// every grant/revoke so neither control can show stale state.
    func render(isTrusted: Bool) {
        self.isTrusted = isTrusted
        renderBanner()
        renderStatusButton()
    }

    var isBannerHidden: Bool {
        bannerView.isHidden
    }

    /// The banner's height is driven by its action button plus padding —
    /// exposed so the workspace can pin the constraint it already owns.
    var bannerHeightReferenceView: NSView {
        actionButton
    }

    private func configureBanner() {
        bannerView.identifier = NSUserInterfaceItemIdentifier("workspace.trustBanner")
        bannerView.orientation = .horizontal
        bannerView.alignment = .centerY
        bannerView.spacing = 8
        bannerView.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 6)
        bannerView.wantsLayer = true
        bannerView.layer?.cornerRadius = 6
        bannerView.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor

        let icon = NSImageView(
            image: NSImage(
                systemSymbolName: "lock.shield",
                accessibilityDescription: Localized.string("Restricted mode", comment: "Accessibility description for the lock icon shown when a workspace is untrusted")
            ) ?? NSImage()
        )

        bannerLabel.lineBreakMode = .byTruncatingTail
        bannerLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bannerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        actionButton.identifier = NSUserInterfaceItemIdentifier("workspace.trust")
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        dismissButton.identifier = NSUserInterfaceItemIdentifier("workspace.trustDismiss")
        dismissButton.bezelStyle = .inline
        dismissButton.isBordered = false
        dismissButton.target = self
        dismissButton.action = #selector(dismissBanner(_:))
        dismissButton.setAccessibilityLabel(
            Localized.string(
                "Dismiss Workspace Trust Banner",
                comment: "Accessibility label for the button that dismisses the workspace trust banner"
            )
        )
        dismissButton.setContentHuggingPriority(.required, for: .horizontal)

        bannerView.addArrangedSubview(icon)
        bannerView.addArrangedSubview(bannerLabel)
        bannerView.addArrangedSubview(actionButton)
        bannerView.addArrangedSubview(dismissButton)
        renderBanner()
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

    private func renderBanner() {
        if isTrusted {
            bannerLabel.stringValue = Localized.string(
                "This workspace is trusted: language servers and repository tools are enabled.",
                comment: "Trust banner message shown when the current workspace is trusted"
            )
            bannerLabel.textColor = .secondaryLabelColor
            actionButton.title = Localized.string("Revoke Trust", comment: "Trust banner button title to revoke trust for the current workspace")
            actionButton.target = self
            actionButton.action = #selector(requestRevokeTrust(_:))
            actionButton.setAccessibilityLabel(
                Localized.string("Revoke trust for this workspace, disabling language servers", comment: "Accessibility label for the trust banner's revoke-trust button")
            )
        } else {
            bannerLabel.stringValue = Localized.string(
                "Restricted mode: language servers and repository tools are disabled.",
                comment: "Trust banner message shown when the current workspace is untrusted"
            )
            bannerLabel.textColor = .secondaryLabelColor
            actionButton.title = Localized.string("Trust Workspace", comment: "Trust banner button title to trust the current workspace")
            actionButton.target = self
            actionButton.action = #selector(requestGrantTrust(_:))
            actionButton.setAccessibilityLabel(
                Localized.string("Trust this workspace, enabling language servers and repository tools", comment: "Accessibility label for the trust banner's trust-workspace button")
            )
        }
        updateBannerVisibility()
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
        statusButton.toolTip = stateDescription
        statusButton.setAccessibilityLabel(stateDescription)
        statusButton.setAccessibilityHelp(actionDescription)
    }

    private func updateBannerVisibility() {
        bannerView.isHidden = !(isBannerEligible && !isBannerDismissed)
        onBannerVisibilityChanged?()
    }

    // MARK: - Intents

    @objc
    private func requestGrantTrust(_ sender: Any?) {
        onIntent?(.grantTrust)
    }

    @objc
    private func requestRevokeTrust(_ sender: Any?) {
        onIntent?(.revokeTrust)
    }

    @objc
    private func dismissBanner(_ sender: Any?) {
        isBannerDismissed = true
        updateBannerVisibility()
        onIntent?(.dismissBanner)
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
