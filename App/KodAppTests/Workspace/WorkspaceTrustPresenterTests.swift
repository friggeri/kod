import AppKit
import XCTest
@testable import Kod

@MainActor
final class WorkspaceTrustPresenterTests: XCTestCase {
    func testUntrustedStateRendersStatusAndActionInTooltip() {
        let presenter = WorkspaceTrustPresenter()

        presenter.render(isTrusted: false)

        XCTAssertEqual(
            presenter.statusButton.accessibilityLabel(),
            "Restricted mode: language servers and repository tools are disabled."
        )
        XCTAssertTrue(
            presenter.statusButton.toolTip?.contains(
                "Trust this workspace, enabling language servers and repository tools"
            ) == true
        )
        XCTAssertEqual(presenter.statusButton.contentTintColor, .labelColor)
    }

    func testTrustedStateRendersStatusAndActionInTooltip() {
        let presenter = WorkspaceTrustPresenter()

        presenter.render(isTrusted: true)

        XCTAssertEqual(
            presenter.statusButton.accessibilityLabel(),
            "This workspace is trusted: language servers and repository tools are enabled."
        )
        XCTAssertTrue(
            presenter.statusButton.toolTip?.contains(
                "Revoke trust for this workspace, disabling language servers"
            ) == true
        )
        XCTAssertEqual(presenter.statusButton.contentTintColor, .labelColor)
    }

    func testStatusControlKeepsItsIdentifierAndConfirmingAction() {
        let presenter = WorkspaceTrustPresenter()

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
        let presenter = WorkspaceTrustPresenter()
        var intents: [WorkspaceTrustPresenter.Intent] = []
        presenter.onIntent = { intents.append($0) }
        presenter.render(isTrusted: false)

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
        XCTAssertTrue(intents.isEmpty)
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
    }
}
