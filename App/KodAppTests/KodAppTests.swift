import AppKit
import KodCore
import WorkspaceCore
import XCTest
@testable import Kod

final class KodAppTests: XCTestCase {
    func testBuildInformationHasStablePresentation() {
        let info = KodBuildInfo(
            version: "0.1.0",
            build: "1",
            architecture: "Test"
        )

        XCTAssertEqual(info.displayDescription, "Version 0.1.0 (1) - Test")
    }
}

@MainActor
final class CommandPaletteControllerTests: XCTestCase {
    func testPanelKeepsReadableSizeAfterSheetPresentation() async throws {
        let controller = CommandPaletteController(
            commands: [
                PaletteCommand(id: "command.first", title: "First Command") {}
            ]
        )
        let window = try XCTUnwrap(controller.window)
        let parent = makeWorkspaceWindow()

        controller.show(asSheetFor: parent)
        try await Task.sleep(for: .milliseconds(500))

        let fittingSize = try XCTUnwrap(window.contentView?.fittingSize)
        XCTAssertEqual(fittingSize.width, 480, accuracy: 0.5)
        XCTAssertEqual(fittingSize.height, 320, accuracy: 0.5)
        XCTAssertEqual(window.contentLayoutRect.width, 480, accuracy: 0.5)
        XCTAssertEqual(window.contentLayoutRect.height, 320, accuracy: 0.5)
        parent.endSheet(window)
    }

    func testSelectedCommandCanPresentAnotherSheetAfterPaletteDismissal() async throws {
        let parent = makeWindow()
        let replacement = makeWindow()
        let actionRan = expectation(description: "Command action ran")
        let controller = CommandPaletteController(
            commands: [
                PaletteCommand(id: "command.replacement", title: "Open Replacement") {
                    XCTAssertNil(parent.attachedSheet)
                    parent.beginSheet(replacement)
                    actionRan.fulfill()
                }
            ]
        )

        controller.show(asSheetFor: parent)
        let searchField = try XCTUnwrap(
            findView(identifier: "commandPalette.search", in: controller.window?.contentView) as? NSSearchField
        )

        XCTAssertTrue(
            controller.control(
                searchField,
                textView: NSTextView(),
                doCommandBy: #selector(NSResponder.insertNewline(_:))
            )
        )
        await fulfillment(of: [actionRan], timeout: 1)

        XCTAssertEqual(parent.attachedSheet, replacement)
        parent.endSheet(replacement)
    }

    func testResultCellKeepsReuseIdentifierAndExposesCommandIdentifierToAccessibility() throws {
        let command = PaletteCommand(id: "command.first", title: "First Command") {}
        let controller = CommandPaletteController(commands: [command])
        let parent = makeWindow()

        controller.show(asSheetFor: parent)
        let tableView = try XCTUnwrap(
            findView(identifier: "commandPalette.results", in: controller.window?.contentView) as? NSTableView
        )
        let cell = try XCTUnwrap(
            controller.tableView(tableView, viewFor: tableView.tableColumns.first, row: 0) as? NSTableCellView
        )

        XCTAssertEqual(cell.identifier?.rawValue, "commandPalette.result")
        XCTAssertEqual(cell.accessibilityIdentifier(), command.id)
        if let sheet = parent.attachedSheet {
            parent.endSheet(sheet)
        }
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
    }

    private func makeWorkspaceWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "workspace.toolbar")
        window.layoutIfNeeded()
        return window
    }

    private func findView(identifier: String, in view: NSView?) -> NSView? {
        guard let view else {
            return nil
        }
        if view.identifier?.rawValue == identifier {
            return view
        }
        return view.subviews.lazy.compactMap {
            self.findView(identifier: identifier, in: $0)
        }.first
    }
}

@MainActor
final class QuickOpenPanelControllerTests: XCTestCase {
    func testPanelKeepsReadableSizeAfterSheetPresentation() async throws {
        let controller = QuickOpenPanelController(
            filenameIndex: FilenameIndex(),
            onSelect: { _ in }
        )
        let window = try XCTUnwrap(controller.window)
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        parent.titleVisibility = .hidden
        parent.titlebarAppearsTransparent = true
        parent.toolbarStyle = .unified
        parent.toolbar = NSToolbar(identifier: "workspace.toolbar")

        controller.show(asSheetFor: parent)
        try await Task.sleep(for: .milliseconds(500))

        let fittingSize = try XCTUnwrap(window.contentView?.fittingSize)
        XCTAssertEqual(fittingSize.width, 620, accuracy: 0.5)
        XCTAssertEqual(fittingSize.height, 360, accuracy: 0.5)
        XCTAssertEqual(window.contentLayoutRect.width, 620, accuracy: 0.5)
        XCTAssertEqual(window.contentLayoutRect.height, 360, accuracy: 0.5)
        parent.endSheet(window)
    }
}
