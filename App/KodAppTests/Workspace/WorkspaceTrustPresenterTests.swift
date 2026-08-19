import AppKit
import XCTest
@testable import Kod

/// Headless coverage for `WorkspaceTrustPresenter`: it renders whatever
/// trust state it is handed and emits typed intents, without owning any
/// trust policy. No workspace session or trust store is involved.
@MainActor
final class WorkspaceTrustPresenterTests: XCTestCase {
    private func findButton(
        identifier: String,
        in view: NSView
    ) -> NSButton? {
        if view.identifier?.rawValue == identifier {
            return view as? NSButton
        }
        for subview in view.subviews {
            if let match = findButton(identifier: identifier, in: subview) {
                return match
            }
        }
        return nil
    }

    func testUntrustedStateRendersRestrictedModeOnBothSurfaces() throws {
        let presenter = WorkspaceTrustPresenter(isBannerEligible: true)
        presenter.render(isTrusted: false)

        let action = try XCTUnwrap(
            findButton(identifier: "workspace.trust", in: presenter.bannerView)
        )
        XCTAssertEqual(action.title, "Trust Workspace")
        XCTAssertEqual(
            presenter.statusButton.accessibilityLabel(),
            "Restricted mode: language servers and repository tools are disabled."
        )
        XCTAssertEqual(presenter.statusButton.contentTintColor, .labelColor)
    }

    func testTrustedStateRendersRevokeAffordances() throws {
        let presenter = WorkspaceTrustPresenter(isBannerEligible: true)
        presenter.render(isTrusted: true)

        let action = try XCTUnwrap(
            findButton(identifier: "workspace.trust", in: presenter.bannerView)
        )
        XCTAssertEqual(action.title, "Revoke Trust")
        XCTAssertEqual(
            presenter.statusButton.accessibilityLabel(),
            "This workspace is trusted: language servers and repository tools are enabled."
        )
        XCTAssertEqual(presenter.statusButton.contentTintColor, .labelColor)
    }

    func testBannerActionEmitsTheMatchingIntentForTheRenderedState() throws {
        let presenter = WorkspaceTrustPresenter(isBannerEligible: true)
        var intents: [WorkspaceTrustPresenter.Intent] = []
        presenter.onIntent = { intents.append($0) }

        presenter.render(isTrusted: false)
        let action = try XCTUnwrap(
            findButton(identifier: "workspace.trust", in: presenter.bannerView)
        )
        action.sendAction(action.action, to: action.target)
        presenter.render(isTrusted: true)
        action.sendAction(action.action, to: action.target)

        XCTAssertEqual(intents, [.grantTrust, .revokeTrust])
    }

    func testDismissHidesTheBannerAndReportsVisibilityOnce() throws {
        let presenter = WorkspaceTrustPresenter(isBannerEligible: true)
        var intents: [WorkspaceTrustPresenter.Intent] = []
        var visibilityChanges = 0
        presenter.onIntent = { intents.append($0) }
        presenter.onBannerVisibilityChanged = { visibilityChanges += 1 }
        XCTAssertFalse(presenter.isBannerHidden)

        let dismiss = try XCTUnwrap(
            findButton(identifier: "workspace.trustDismiss", in: presenter.bannerView)
        )
        dismiss.sendAction(dismiss.action, to: dismiss.target)

        XCTAssertTrue(presenter.isBannerHidden)
        XCTAssertEqual(intents, [.dismissBanner])
        XCTAssertEqual(visibilityChanges, 1)
    }

    /// A re-opened workspace never wins the one-time banner claim, so the
    /// banner stays hidden no matter what state is rendered into it.
    func testIneligibleBannerStaysHiddenAcrossRenders() {
        let presenter = WorkspaceTrustPresenter(isBannerEligible: false)
        XCTAssertTrue(presenter.isBannerHidden)

        presenter.render(isTrusted: true)
        XCTAssertTrue(presenter.isBannerHidden)

        presenter.render(isTrusted: false)
        XCTAssertTrue(presenter.isBannerHidden)
    }

    func testStatusControlKeepsItsIdentifierAndConfirmingAction() {
        let presenter = WorkspaceTrustPresenter(isBannerEligible: false)

        XCTAssertEqual(
            presenter.statusButton.identifier?.rawValue,
            "workspace.trustStatus"
        )
        XCTAssertEqual(
            presenter.statusButton.action,
            NSSelectorFromString("promptToToggleWorkspaceTrust:")
        )
        XCTAssertTrue(presenter.statusButton.target === presenter)
    }

    func testConfirmationIsRequiredBeforeAnyStatusControlIntent() throws {
        let presenter = WorkspaceTrustPresenter(isBannerEligible: false)
        var intents: [WorkspaceTrustPresenter.Intent] = []
        presenter.onIntent = { intents.append($0) }
        presenter.render(isTrusted: false)

        // Without a window there is nowhere to attach the confirmation
        // sheet, so nothing may be granted implicitly.
        presenter.promptToToggleWorkspaceTrust(nil)
        XCTAssertTrue(intents.isEmpty)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        presenter.presentingWindow = { window }
        presenter.promptToToggleWorkspaceTrust(nil)

        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertTrue(intents.isEmpty, "The intent must wait for confirmation")
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
    }

    func testBannerKeepsItsAccessibilityIdentifiersAndDismissIsLast() throws {
        let presenter = WorkspaceTrustPresenter(isBannerEligible: true)

        XCTAssertEqual(
            presenter.bannerView.identifier?.rawValue,
            "workspace.trustBanner"
        )
        let dismiss = try XCTUnwrap(
            findButton(identifier: "workspace.trustDismiss", in: presenter.bannerView)
        )
        XCTAssertTrue(presenter.bannerView.arrangedSubviews.last === dismiss)
        XCTAssertEqual(
            dismiss.accessibilityLabel(),
            "Dismiss Workspace Trust Banner"
        )
    }
}
